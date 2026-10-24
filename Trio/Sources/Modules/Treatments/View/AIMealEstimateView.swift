import Foundation
import PhotosUI
import Security
import SwiftUI
import UIKit

// MARK: - Result model

/// Nutrition estimate returned by the selected AI provider for a meal photo or description.
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

// MARK: - Provider configuration

enum AIMealProvider: String, CaseIterable, Identifiable {
    case anthropic
    case openAI = "openai"
    case openAICompatible = "openai-compatible"
    case appleIntelligence = "apple-intelligence"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic (Claude)"
        case .openAI: return "OpenAI"
        case .openAICompatible: return "OpenAI-kompatibel"
        case .appleIntelligence: return "Apple Intelligence (offline)"
        }
    }
}

struct AIMealConfiguration: Equatable {
    let provider: AIMealProvider
    let model: String
    let baseURL: String

    func endpoint() throws -> URL {
        switch provider {
        case .appleIntelligence: throw AIMealError.onDeviceProvider
        case .anthropic: return URL(string: "https://api.anthropic.com/v1/messages")!
        case .openAI: return URL(string: "https://api.openai.com/v1/responses")!
        case .openAICompatible:
            return try Self.normalizedBaseURL(baseURL).appendingPathComponent("chat/completions")
        }
    }

    static func normalizedBaseURL(_ value: String) throws -> URL {
        guard var parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1 ... 65535).contains($0) }) ?? true
        else { throw AIMealError.invalidURL }
        let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        guard scheme == "https" || (scheme == "http" && loopback) else { throw AIMealError.invalidURL }
        parts.scheme = scheme
        parts.host = host
        if (scheme == "https" && parts.port == 443) || (scheme == "http" && parts.port == 80) { parts.port = nil }
        while parts.percentEncodedPath.hasSuffix("/") { parts.percentEncodedPath.removeLast() }
        guard let url = parts.url else { throw AIMealError.invalidURL }
        return url
    }
}

// MARK: - Settings and endpoint-bound Keychain credentials

enum AIMealSettingsStore {
    static let legacyDefaultModel = "claude-sonnet-4-5"

    static var provider: AIMealProvider {
        get { provider(defaults: .standard) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "ai.meal.provider") }
    }

    static func provider(defaults: UserDefaults) -> AIMealProvider {
        AIMealProvider(rawValue: defaults.string(forKey: "ai.meal.provider") ?? "") ?? .anthropic
    }

    static var customBaseURL: String {
        get { UserDefaults.standard.string(forKey: "ai.meal.customBaseURL") ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "ai.meal.customBaseURL") }
    }

    static func modelDefaultsKey(for provider: AIMealProvider) -> String {
        provider == .anthropic ? "claude.meal.model" : "ai.meal.\(provider.rawValue).model"
    }

    static func model(for provider: AIMealProvider, defaults: UserDefaults = .standard) -> String {
        guard provider != .appleIntelligence else { return "" }
        let value = defaults.string(forKey: modelDefaultsKey(for: provider))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty && provider == .anthropic ? legacyDefaultModel : value
    }

    static func setModel(_ value: String, for provider: AIMealProvider) {
        guard provider != .appleIntelligence else { return }
        UserDefaults.standard.set(value.trimmingCharacters(in: .whitespacesAndNewlines), forKey: modelDefaultsKey(for: provider))
    }

    static var currentConfiguration: AIMealConfiguration {
        let selected = provider
        return AIMealConfiguration(provider: selected, model: model(for: selected), baseURL: selected == .appleIntelligence ? "" : customBaseURL)
    }

    /// Anthropic keeps its original identity; compatible credentials belong to one complete endpoint.
    static func credentialIdentity(for provider: AIMealProvider, baseURL: String = "") throws -> (service: String, account: String) {
        switch provider {
        case .appleIntelligence: throw AIMealError.onDeviceProvider
        case .anthropic: return ("org.nightscout.trio.claude", "anthropic_api_key")
        case .openAI: return ("org.nightscout.trio.ai.meal", "openai_api_key")
        case .openAICompatible:
            let endpoint = try AIMealConfiguration.normalizedBaseURL(baseURL).appendingPathComponent("chat/completions")
            return ("org.nightscout.trio.ai.meal", "compatible:\(endpoint.absoluteString)")
        }
    }

    static func apiKey(for provider: AIMealProvider, baseURL: String = "") -> String? {
        guard let identity = try? credentialIdentity(for: provider, baseURL: baseURL) else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: identity.service,
            kSecAttrAccount as String: identity.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty
        else { return nil }
        return key
    }

    @discardableResult static func setAPIKey(_ key: String?, for provider: AIMealProvider, baseURL: String = "") -> Bool {
        guard let identity = try? credentialIdentity(for: provider, baseURL: baseURL) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: identity.service,
            kSecAttrAccount as String: identity.account
        ]
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var add = query.merging(attributes) { _, new in new }
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

/// Retains existing Anthropic settings and credentials for users upgrading from the Claude-only version.
enum ClaudeSettingsStore {
    static let defaultModel = AIMealSettingsStore.legacyDefaultModel
    static var model: String {
        get { AIMealSettingsStore.model(for: .anthropic) }
        set { AIMealSettingsStore.setModel(newValue, for: .anthropic) }
    }
    static var apiKey: String? { AIMealSettingsStore.apiKey(for: .anthropic) }
    @discardableResult static func setAPIKey(_ key: String?) -> Bool {
        AIMealSettingsStore.setAPIKey(key, for: .anthropic)
    }
}

// MARK: - Provider API client

enum AIMealError: LocalizedError {
    case onDeviceProvider
    case missingAPIKey
    case missingModel
    case invalidURL
    case keychain
    case imageEncoding
    case http(Int)
    case emptyResponse
    case incompleteResponse
    case unparsable

    var errorDescription: String? {
        switch self {
        case .onDeviceProvider: return "Apple Intelligence arbeitet lokal und verwendet keine HTTP-Schnittstelle oder API-Keys."
        case .missingAPIKey: return "Für diesen Anbieter und Endpunkt ist kein API-Key hinterlegt."
        case .missingModel: return "Bitte eine Modell-ID mit Bildverständnis eintragen."
        case .invalidURL: return "Bitte eine gültige HTTPS-Basis-URL ohne Zugangsdaten, Query oder Fragment eintragen. HTTP ist nur für localhost erlaubt."
        case .keychain: return "Der API-Key konnte nicht im Schlüsselbund gespeichert werden."
        case .imageEncoding: return "Das Foto konnte nicht verarbeitet werden."
        case let .http(code): return "KI-API Fehler \(code)."
        case .emptyResponse: return "Der KI-Anbieter hat keine auswertbare Antwort geliefert."
        case .incompleteResponse: return "Die KI-Antwort wurde nicht vollständig abgeschlossen. Bitte erneut versuchen."
        case .unparsable: return "Die KI-Antwort enthält keine gültige Nährwertschätzung."
        }
    }
}

enum AIMealService {
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

    static func makeRequest(configuration: AIMealConfiguration, apiKey: String?, jpeg: Data, userHint: String) throws -> URLRequest {
        let endpoint = try configuration.endpoint()
        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw AIMealError.missingModel }
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard configuration.provider == .openAICompatible || !key.isEmpty else {
            throw AIMealError.missingAPIKey
        }
        guard !jpeg.isEmpty else { throw AIMealError.imageEncoding }
        var prompt = "Schätze die Nährwerte dieser Mahlzeit."
        let hint = userHint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hint.isEmpty { prompt += " Zusätzliche Info vom Nutzer: \(hint)" }
        let image = jpeg.base64EncodedString()
        var body: [String: Any]
        switch configuration.provider {
        case .appleIntelligence: throw AIMealError.onDeviceProvider
        case .anthropic:
            body = [
                "model": model, "max_tokens": 1024, "system": systemPrompt,
                "messages": [["role": "user", "content": [
                    ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": image]],
                    ["type": "text", "text": prompt]
                ]]]
            ]
        case .openAI:
            body = [
                "model": model, "instructions": systemPrompt, "store": false, "max_output_tokens": 4096,
                "input": [["role": "user", "content": [
                    ["type": "input_text", "text": prompt],
                    ["type": "input_image", "image_url": "data:image/jpeg;base64,\(image)"]
                ]]]
            ]
        case .openAICompatible:
            body = [
                "model": model, "max_tokens": 1024,
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": [
                        ["type": "text", "text": prompt],
                        ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(image)"]]
                    ]]
                ]
            ]
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if configuration.provider == .anthropic {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func parseResponse(_ data: Data, status: Int, provider: AIMealProvider) throws -> AIMealEstimate {
        guard provider != .appleIntelligence else { throw AIMealError.onDeviceProvider }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200 ..< 300).contains(status) else {
            throw AIMealError.http(status)
        }
        guard let object else { throw AIMealError.unparsable }
        let answer: String
        switch provider {
        case .appleIntelligence: throw AIMealError.onDeviceProvider
        case .anthropic:
            if object["stop_reason"] as? String == "max_tokens" { throw AIMealError.incompleteResponse }
            let blocks = object["content"] as? [[String: Any]] ?? []
            answer = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        case .openAI:
            guard object["status"] as? String == "completed" else { throw AIMealError.incompleteResponse }
            let output = object["output"] as? [[String: Any]] ?? []
            answer = output.filter { $0["type"] as? String == "message" }
                .flatMap { $0["content"] as? [[String: Any]] ?? [] }
                .filter { $0["type"] as? String == "output_text" }
                .compactMap { $0["text"] as? String }.joined()
        case .openAICompatible:
            let choice = (object["choices"] as? [[String: Any]])?.first
            if choice?["finish_reason"] as? String == "length" { throw AIMealError.incompleteResponse }
            answer = (choice?["message"] as? [String: Any])?["content"] as? String ?? ""
        }
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIMealError.emptyResponse }
        return try parse(answer)
    }

    static func parse(_ answer: String) throws -> AIMealEstimate {
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"), start < end,
              let json = String(answer[start ... end]).data(using: .utf8),
              let estimate = try? JSONDecoder().decode(AIMealEstimate.self, from: json)
        else { throw AIMealError.unparsable }
        return try validated(estimate)
    }

    static func validated(_ estimate: AIMealEstimate) throws -> AIMealEstimate {
        func valid(_ value: Double, limit: Double = 1000) -> Bool { value.isFinite && value >= 0 && value < limit }
        guard [estimate.carbs, estimate.fat, estimate.protein].allSatisfy({ valid($0) }),
              estimate.items.allSatisfy({ item in
                  valid(item.carbs) && (item.fat.map { valid($0) } ?? true)
                      && (item.protein.map { valid($0) } ?? true)
                      && (item.grams.map { valid($0, limit: 10000) } ?? true)
              })
        else { throw AIMealError.unparsable }
        return estimate
    }

    static func estimate(
        image: UIImage?, userHint: String,
        configuration: AIMealConfiguration = AIMealSettingsStore.currentConfiguration
    ) async throws -> AIMealEstimate {
        if configuration.provider == .appleIntelligence {
            return try await AppleIntelligenceMealService.estimate(description: userHint)
        }
        guard let image else { throw AIMealError.imageEncoding }
        guard let jpeg = downscaled(image, maxDimension: 1280).jpegData(compressionQuality: 0.8)
        else { throw AIMealError.imageEncoding }
        let request = try makeRequest(
            configuration: configuration,
            apiKey: AIMealSettingsStore.apiKey(for: configuration.provider, baseURL: configuration.baseURL),
            jpeg: jpeg,
            userHint: userHint
        )
        let session = URLSession(configuration: .ephemeral, delegate: AIMealRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        return try parseResponse(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0, provider: configuration.provider)
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

/// Credentials and meal photos must stay at the configured endpoint, including on HTTP redirects.
private final class AIMealRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

// MARK: - Reusable meal-provider settings

struct AIMealSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var provider = AIMealSettingsStore.provider
    @State private var modelInput = AIMealSettingsStore.model(for: AIMealSettingsStore.provider)
    @State private var baseURLInput = AIMealSettingsStore.customBaseURL
    @State private var apiKeyInput = ""
    @State private var hasKey = false
    @State private var message: String?
    @State private var saveFailed = false
    @State private var appleAvailability = AppleIntelligenceMealService.availability

    var body: some View {
        Form {
            Section {
                Picker("Anbieter", selection: $provider) {
                    ForEach(AIMealProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .onChange(of: provider) { _, value in
                    modelInput = AIMealSettingsStore.model(for: value)
                    apiKeyInput = ""
                    message = nil
                    refreshKeyStatus()
                    appleAvailability = AppleIntelligenceMealService.availability
                }
                if provider == .openAICompatible {
                    TextField("Basis-URL, z.B. https://anbieter.example/v1", text: $baseURLInput)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: baseURLInput) { _, _ in
                            apiKeyInput = ""
                            message = nil
                            refreshKeyStatus()
                        }
                }
                if provider == .appleIntelligence {
                    Label(appleAvailability.message, systemImage: appleAvailability.available ? "checkmark.circle" : "info.circle")
                        .foregroundColor(appleAvailability.available ? .secondary : .orange)
                    Text("Mahlzeit und Menge als Text beschreiben. Fotos werden mit dieser lokalen Integration nicht ausgewertet.")
                        .font(.footnote)
                } else {
                    TextField("Modell-ID mit Bildverständnis", text: $modelInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(
                        hasKey ? "API-Key gespeichert – neu eingeben zum Ändern"
                            : (provider == .openAICompatible ? "API-Key (optional)" : "API-Key"),
                        text: $apiKeyInput
                    )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Button("Speichern") { save() }
                if hasKey {
                    Button("API-Key für diesen Anbieter löschen", role: .destructive) {
                        if AIMealSettingsStore.setAPIKey(nil, for: provider, baseURL: baseURLInput) {
                            apiKeyInput = ""
                            refreshKeyStatus()
                            message = "API-Key gelöscht."
                            saveFailed = false
                        } else {
                            message = AIMealError.keychain.localizedDescription
                            saveFailed = true
                        }
                    }
                }
                if let message {
                    Text(message).font(.footnote).foregroundStyle(saveFailed ? .red : .secondary)
                }
            } header: {
                Text("KI-Mahlzeiten")
            } footer: {
                Text(provider == .appleIntelligence
                    ? "Die Beschreibung wird auf diesem iPhone verarbeitet. Kein API-Key, kein Mac und keine Cloud-Anfrage. Apple Intelligence muss aktiviert und das Systemmodell bereits geladen sein. Bei Nichtverfügbarkeit wird kein anderer Anbieter verwendet."
                    : "Der API-Key bleibt im Schlüsselbund dieses iPhones. Beim Schätzen werden Foto und Hinweis an den gewählten Anbieter gesendet. Für OpenAI-kompatible Dienste muss das Modell Bilder unterstützen; der Key ist an die eingetragene Basis-URL gebunden.")
            }
        }
        .navigationTitle("KI-Mahlzeiten")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            refreshKeyStatus()
            appleAvailability = AppleIntelligenceMealService.availability
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { appleAvailability = AppleIntelligenceMealService.availability }
        }
    }

    private func refreshKeyStatus() {
        hasKey = AIMealSettingsStore.apiKey(for: provider, baseURL: baseURLInput) != nil
    }

    private func save() {
        do {
            if provider == .appleIntelligence {
                AIMealSettingsStore.provider = provider
                apiKeyInput = ""
                refreshKeyStatus()
                appleAvailability = AppleIntelligenceMealService.availability
                message = "Gespeichert."
                saveFailed = false
                return
            }
            let model = modelInput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty else { throw AIMealError.missingModel }
            let configuration = AIMealConfiguration(provider: provider, model: model, baseURL: baseURLInput)
            _ = try configuration.endpoint()
            if !apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard AIMealSettingsStore.setAPIKey(apiKeyInput, for: provider, baseURL: baseURLInput) else {
                    throw AIMealError.keychain
                }
            }
            AIMealSettingsStore.setModel(model, for: provider)
            if provider == .openAICompatible {
                AIMealSettingsStore.customBaseURL = try AIMealConfiguration.normalizedBaseURL(baseURLInput).absoluteString
            }
            AIMealSettingsStore.provider = provider
            apiKeyInput = ""
            refreshKeyStatus()
            message = hasKey || provider == .openAICompatible
                ? "Gespeichert." : "Gespeichert. Bitte noch einen API-Key für diesen Anbieter hinterlegen."
            saveFailed = false
        } catch {
            message = error.localizedDescription
            saveFailed = true
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

/// Photo or local text -> editable estimate -> "Übernehmen" pre-fills Trio's carb form.
struct AIMealEstimateView: View {
    /// Called with (carbs, fat, protein, note) when the user taps "Übernehmen".
    let onApply: (Decimal, Decimal, Decimal, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var image: UIImage?
    @State private var photoItem: PhotosPickerItem?
    @State private var isLoadingPhoto = false
    @State private var photoLoadTask: Task<Void, Never>?
    @State private var showCamera = false
    @State private var hint = ""
    @State private var isLoading = false
    @State private var analysisTask: Task<Void, Never>?
    @State private var errorText: String?
    @State private var estimate: AIMealEstimate?

    @State private var carbs: Double = 0
    @State private var fat: Double = 0
    @State private var protein: Double = 0
    @State private var note = ""

    @State private var configuration = AIMealSettingsStore.currentConfiguration
    @State private var hasKey = AIMealSettingsStore.apiKey(
        for: AIMealSettingsStore.provider, baseURL: AIMealSettingsStore.customBaseURL
    ) != nil
    @State private var showSettings = false
    @State private var appleAvailability = AppleIntelligenceMealService.availability

    private var usesAppleIntelligence: Bool { configuration.provider == .appleIntelligence }

    private var isConfigured: Bool {
        if usesAppleIntelligence { return appleAvailability.available }
        return (hasKey || configuration.provider == .openAICompatible)
            && !configuration.model.isEmpty && (try? configuration.endpoint()) != nil
    }

    private var hasInput: Bool {
        usesAppleIntelligence ? !hint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : image != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Anbieter", value: configuration.provider.displayName)
                    if usesAppleIntelligence {
                        Text(appleAvailability.message).font(.footnote)
                            .foregroundColor(appleAvailability.available ? .secondary : .orange)
                    }
                    if !isConfigured {
                        Button("KI-Anbieter einrichten") { showSettings = true }
                    }
                }

                Section {
                    if !usesAppleIntelligence, let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    if !usesAppleIntelligence {
                        HStack {
                            Button { showCamera = true } label: {
                                Label("Foto aufnehmen", systemImage: "camera")
                            }.buttonStyle(.borderless)
                            Spacer()
                            PhotosPicker(selection: $photoItem, matching: .images) {
                                Label("Mediathek", systemImage: "photo")
                            }.buttonStyle(.borderless)
                        }
                    }
                    TextField(usesAppleIntelligence
                        ? "Mahlzeit und Menge, z.B. 150 g gekochte Nudeln mit 50 g Tomatensauce"
                        : "Hinweis (optional, z.B. „ca. 300 g Nudeln“)", text: $hint, axis: .vertical)
                    if usesAppleIntelligence {
                        Text("\(hint.count)/2000 Zeichen").font(.caption).foregroundStyle(.secondary)
                    }
                } header: { Text("Mahlzeit") } footer: {
                    if usesAppleIntelligence {
                        Text("Offline auf diesem iPhone. Beschreibe Lebensmittel, Zubereitung und verzehrte Menge. Fotos werden nicht analysiert. Die Schätzung wird anschließend zur Prüfung angezeigt.")
                    }
                }
                .disabled(isLoading || isLoadingPhoto)

                Section {
                    Button {
                        analysisTask = Task { await analyze() }
                    } label: {
                        HStack {
                            if isLoading || isLoadingPhoto { ProgressView().padding(.trailing, 6) }
                            Text(isLoadingPhoto ? "Foto wird geladen …" : (isLoading ? "KI analysiert …" : "Mit KI schätzen"))
                        }
                    }
                    .disabled(!hasInput || isLoading || isLoadingPhoto || !isConfigured || (usesAppleIntelligence && hint.count > 2000))
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
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .disabled(isLoading)
                }
            }
            .sheet(isPresented: $showCamera) {
                CameraPicker(image: $image).ignoresSafeArea()
            }
            .sheet(isPresented: $showSettings, onDismiss: {
                let selected = AIMealSettingsStore.currentConfiguration
                if selected != configuration {
                    photoLoadTask?.cancel()
                    isLoadingPhoto = false
                    estimate = nil
                    errorText = nil
                    image = nil
                    photoItem = nil
                }
                configuration = selected
                hasKey = AIMealSettingsStore.apiKey(for: configuration.provider, baseURL: configuration.baseURL) != nil
                appleAvailability = AppleIntelligenceMealService.availability
            }) {
                NavigationStack {
                    AIMealSettingsView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Fertig") { showSettings = false }
                            }
                        }
                }
            }
            .onChange(of: photoItem) { _, item in
                photoLoadTask?.cancel()
                image = nil
                estimate = nil
                errorText = nil
                isLoadingPhoto = item != nil
                guard let item else { return }
                photoLoadTask = Task { @MainActor in
                    let data = try? await item.loadTransferable(type: Data.self)
                    guard !Task.isCancelled, photoItem == item, !usesAppleIntelligence else { return }
                    image = data.flatMap { UIImage(data: $0) }
                    isLoadingPhoto = false
                    if image == nil { errorText = "Das ausgewählte Foto konnte nicht geladen werden." }
                }
            }
            .onChange(of: image) { _, _ in
                estimate = nil
                errorText = nil
            }
            .onChange(of: hint) { _, _ in
                estimate = nil
                errorText = nil
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { appleAvailability = AppleIntelligenceMealService.availability }
            }
            .onDisappear {
                analysisTask?.cancel()
                photoLoadTask?.cancel()
                if isLoadingPhoto {
                    isLoadingPhoto = false
                    photoItem = nil
                }
            }
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
        guard hasInput, !isLoadingPhoto else { return }
        let requestedConfiguration = configuration
        let requestedImage = image
        let requestedHint = hint
        isLoading = true
        errorText = nil
        estimate = nil
        defer { isLoading = false }
        do {
            let result = try await AIMealService.estimate(image: requestedImage, userHint: requestedHint, configuration: requestedConfiguration)
            try Task.checkCancellation()
            guard configuration == requestedConfiguration, image == requestedImage, hint == requestedHint else { return }
            estimate = result
            carbs = result.carbs.rounded()
            fat = result.fat.rounded()
            protein = result.protein.rounded()
            note = result.shortNote ?? "🤖 KI"
        } catch is CancellationError {
            // Dismissing the sheet must not publish a late result.
        } catch {
            errorText = error.localizedDescription
        }
    }
}
