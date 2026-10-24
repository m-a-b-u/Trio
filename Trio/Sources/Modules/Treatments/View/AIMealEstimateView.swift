import PhotosUI
import Security
import SwiftUI
import UIKit

// MARK: - Result model

/// Nutrition estimate returned by Claude for a meal photo.
/// The values are ONLY used to pre-fill the carb entry form. Nothing is logged
/// or dosed until the user reviews the values and confirms in Trio as usual.
struct AIMealEstimate: Decodable, Equatable {
    struct Item: Decodable, Equatable, Identifiable {
        var id: String { name + "\(grams ?? 0)" }
        let name: String
        let grams: Double?
        let carbs: Double
        let fat: Double?
        let protein: Double?
    }

    let items: [Item]
    let carbs: Double
    let fat: Double
    let protein: Double
    let confidence: String
    let notes: String?
    let shortNote: String?

    enum CodingKeys: String, CodingKey {
        case items, carbs, fat, protein, confidence, notes
        case shortNote = "short_note"
    }
}

// MARK: - API key / settings storage (Keychain)

enum ClaudeSettingsStore {
    private static let service = "org.nightscout.trio.claude"
    private static let keyAccount = "anthropic_api_key"
    private static let modelDefaultsKey = "claude.meal.model"
    static let defaultModel = "claude-sonnet-4-5"

    static var model: String {
        get {
            let stored = UserDefaults.standard.string(forKey: modelDefaultsKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (stored?.isEmpty == false) ? stored! : defaultModel
        }
        set { UserDefaults.standard.set(newValue, forKey: modelDefaultsKey) }
    }

    static var apiKey: String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keyAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }

    @discardableResult static func setAPIKey(_ key: String?) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keyAccount
        ]
        SecItemDelete(base as CFDictionary)
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

// MARK: - Claude API client

enum ClaudeMealError: LocalizedError {
    case missingAPIKey
    case imageEncoding
    case http(Int, String)
    case emptyResponse
    case unparsable(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Kein Anthropic API-Key hinterlegt."
        case .imageEncoding: return "Das Foto konnte nicht verarbeitet werden."
        case let .http(code, body): return "Claude-API Fehler \(code): \(body.prefix(300))"
        case .emptyResponse: return "Claude hat keine Antwort geliefert."
        case let .unparsable(text): return "Antwort nicht lesbar: \(text.prefix(300))"
        }
    }
}

enum ClaudeMealService {
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    private static let systemPrompt = """
    You are a nutrition estimation assistant for a person with type 1 diabetes. \
    Estimate the macronutrients of the meal in the photo as accurately as possible. \
    Identify each food item, estimate its portion weight in grams (use plate, cutlery and \
    hand sizes as scale references), and estimate carbohydrates, fat and protein in grams. \
    Count only digestible carbohydrates (exclude fiber). Be conservative and do NOT round up. \
    If the image does not show food or the portion is impossible to judge, return zeros and \
    confidence "low" and explain why in notes. \
    Respond with ONLY a JSON object, no markdown, using exactly this schema: \
    {"items":[{"name":string,"grams":number,"carbs":number,"fat":number,"protein":number}],\
    "carbs":number,"fat":number,"protein":number,"confidence":"low"|"medium"|"high",\
    "notes":string,"short_note":string}. \
    "notes" is a short explanation in German (max 3 sentences) including the main uncertainty. \
    "short_note" is a max 20 character German label for the meal, may start with one emoji.
    """

    static func estimate(image: UIImage, userHint: String) async throws -> AIMealEstimate {
        guard let apiKey = ClaudeSettingsStore.apiKey else { throw ClaudeMealError.missingAPIKey }
        guard let jpeg = downscaled(image, maxDimension: 1280).jpegData(compressionQuality: 0.8)
        else { throw ClaudeMealError.imageEncoding }

        var text = "Schätze die Nährwerte dieser Mahlzeit."
        let hint = userHint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hint.isEmpty { text += " Zusätzliche Info vom Nutzer: \(hint)" }

        let body: [String: Any] = [
            "model": ClaudeSettingsStore.model,
            "max_tokens": 1024,
            "system": systemPrompt,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image", "source": [
                        "type": "base64",
                        "media_type": "image/jpeg",
                        "data": jpeg.base64EncodedString()
                    ]],
                    ["type": "text", "text": text]
                ]
            ]]
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            throw ClaudeMealError.http(status, String(data: data, encoding: .utf8) ?? "")
        }

        struct APIResponse: Decodable {
            struct Block: Decodable { let type: String; let text: String? }
            let content: [Block]
        }
        let decoded = try JSONDecoder().decode(APIResponse.self, from: data)
        let answer = decoded.content.compactMap(\.text).joined()
        guard !answer.isEmpty else { throw ClaudeMealError.emptyResponse }
        return try parse(answer)
    }

    static func parse(_ answer: String) throws -> AIMealEstimate {
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"), start < end,
              let json = String(answer[start ... end]).data(using: .utf8)
        else { throw ClaudeMealError.unparsable(answer) }
        do {
            let estimate = try JSONDecoder().decode(AIMealEstimate.self, from: json)
            // Sanity: reject negative / absurd values
            guard [estimate.carbs, estimate.fat, estimate.protein].allSatisfy({ $0 >= 0 && $0 < 1000 })
            else { throw ClaudeMealError.unparsable(answer) }
            return estimate
        } catch {
            throw ClaudeMealError.unparsable(answer)
        }
    }

    private static func downscaled(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let scale = min(1, maxDimension / max(size.width, size.height))
        guard scale < 1 else { return image }
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

// MARK: - Camera wrapper

struct CameraPicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_: UIImagePickerController, context _: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(
            _: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            parent.image = info[.originalImage] as? UIImage
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_: UIImagePickerController) { parent.dismiss() }
    }
}

// MARK: - Sheet

/// Photo -> Claude -> editable estimate -> "Übernehmen" pre-fills Trio's carb form.
struct AIMealEstimateView: View {
    /// Called with (carbs, fat, protein, note) when the user taps "Übernehmen".
    let onApply: (Decimal, Decimal, Decimal, String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var image: UIImage?
    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var hint = ""
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var estimate: AIMealEstimate?

    @State private var carbs: Double = 0
    @State private var fat: Double = 0
    @State private var protein: Double = 0
    @State private var note = ""

    @State private var apiKeyInput = ""
    @State private var modelInput = ClaudeSettingsStore.model
    @State private var hasKey = ClaudeSettingsStore.apiKey != nil
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            Form {
                if !hasKey || showSettings {
                    settingsSection
                }

                Section {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    HStack {
                        Button { showCamera = true } label: {
                            Label("Foto aufnehmen", systemImage: "camera")
                        }.buttonStyle(.borderless)
                        Spacer()
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            Label("Mediathek", systemImage: "photo")
                        }.buttonStyle(.borderless)
                    }
                    TextField("Hinweis (optional, z.B. „ca. 300 g Nudeln“)", text: $hint, axis: .vertical)
                } header: { Text("Mahlzeit") }

                Section {
                    Button {
                        Task { await analyze() }
                    } label: {
                        HStack {
                            if isLoading { ProgressView().padding(.trailing, 6) }
                            Text(isLoading ? "Claude analysiert …" : "Mit Claude schätzen")
                        }
                    }
                    .disabled(image == nil || isLoading || !hasKey)
                    if let errorText {
                        Text(errorText).font(.footnote).foregroundStyle(.red)
                    }
                }

                if let estimate {
                    resultSection(estimate)
                }
            }
            .navigationTitle("KI-Mahlzeit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if hasKey {
                        Button { showSettings.toggle() } label: { Image(systemName: "gearshape") }
                    }
                }
            }
            .sheet(isPresented: $showCamera) {
                CameraPicker(image: $image).ignoresSafeArea()
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let picked = UIImage(data: data)
                    {
                        await MainActor.run { image = picked }
                    }
                }
            }
            .onChange(of: image) { _, _ in
                estimate = nil
                errorText = nil
            }
        }
    }

    private var settingsSection: some View {
        Section {
            SecureField(hasKey ? "Neuen API-Key eingeben" : "Anthropic API-Key (sk-ant-…)", text: $apiKeyInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Modell", text: $modelInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Speichern") {
                if !apiKeyInput.isEmpty { ClaudeSettingsStore.setAPIKey(apiKeyInput) }
                ClaudeSettingsStore.model = modelInput
                apiKeyInput = ""
                hasKey = ClaudeSettingsStore.apiKey != nil
                showSettings = false
            }
            if hasKey {
                Button("API-Key löschen", role: .destructive) {
                    ClaudeSettingsStore.setAPIKey(nil)
                    hasKey = false
                }
            }
        } header: {
            Text("Claude-Verbindung")
        } footer: {
            Text("Der Key wird nur in der Schlüsselbund dieses iPhones gespeichert. Fotos werden zur Analyse an die Anthropic-API gesendet.")
        }
    }

    @ViewBuilder private func resultSection(_ estimate: AIMealEstimate) -> some View {
        Section {
            ForEach(estimate.items) { item in
                HStack {
                    VStack(alignment: .leading) {
                        Text(item.name)
                        if let grams = item.grams {
                            Text("≈ \(Int(grams.rounded())) g").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text("\(Int(item.carbs.rounded())) g KH").foregroundStyle(.secondary)
                }
            }
            if let notes = estimate.notes, !notes.isEmpty {
                Text(notes).font(.footnote).foregroundStyle(.secondary)
            }
            HStack {
                Text("Sicherheit")
                Spacer()
                Text(confidenceLabel(estimate.confidence))
                    .foregroundStyle(estimate.confidence == "high" ? .green : (estimate.confidence == "medium" ? .orange : .red))
            }
        } header: { Text("Erkannt") }

        Section {
            Stepper(value: $carbs, in: 0 ... 300, step: 1) {
                HStack { Text("Kohlenhydrate"); Spacer(); Text("\(Int(carbs)) g").bold() }
            }
            Stepper(value: $fat, in: 0 ... 300, step: 1) {
                HStack { Text("Fett"); Spacer(); Text("\(Int(fat)) g") }
            }
            Stepper(value: $protein, in: 0 ... 300, step: 1) {
                HStack { Text("Protein"); Spacer(); Text("\(Int(protein)) g") }
            }
            TextField("Notiz", text: $note)
            Button {
                onApply(Decimal(Int(carbs)), Decimal(Int(fat)), Decimal(Int(protein)), String(note.prefix(25)))
                dismiss()
            } label: {
                Text("In Eingabe übernehmen").frame(maxWidth: .infinity).bold()
            }
        } header: {
            Text("Prüfen & anpassen")
        } footer: {
            Text("KI-Schätzungen können deutlich danebenliegen. Werte prüfen – geloggt und dosiert wird erst nach deiner Bestätigung in Trio.")
        }
    }

    private func confidenceLabel(_ value: String) -> String {
        switch value {
        case "high": return "hoch"
        case "medium": return "mittel"
        default: return "niedrig"
        }
    }

    @MainActor private func analyze() async {
        guard let image else { return }
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            let result = try await ClaudeMealService.estimate(image: image, userHint: hint)
            estimate = result
            carbs = result.carbs.rounded()
            fat = result.fat.rounded()
            protein = result.protein.rounded()
            note = result.shortNote ?? "🤖 KI"
        } catch {
            errorText = error.localizedDescription
        }
    }
}
