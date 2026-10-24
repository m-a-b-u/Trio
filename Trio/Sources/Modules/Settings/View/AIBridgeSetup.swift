import Darwin
import Foundation
import SwiftUI

struct AIBridgeSetup: Equatable {
    let server: URL
    let token: String

    static func parse(_ raw: String) throws -> AIBridgeSetup {
        guard raw.utf8.count <= 8192, raw.utf8.allSatisfy({ (33 ... 126).contains($0) && $0 != 92 }),
              raw.range(of: #"^trio://ai-bridge-setup/?\?"#, options: [.regularExpression, .caseInsensitive]) != nil,
              let parts = URLComponents(string: raw), parts.scheme?.lowercased() == "trio",
              parts.host?.lowercased() == "ai-bridge-setup", parts.user == nil, parts.password == nil,
              parts.port == nil, parts.fragment == nil, ["", "/"].contains(parts.percentEncodedPath),
              let items = parts.queryItems, items.count == 3,
              Set(items.map(\.name)) == ["version", "server", "token"],
              items.first(where: { $0.name == "version" })?.value == "1",
              let server = items.first(where: { $0.name == "server" })?.value,
              let token = items.first(where: { $0.name == "token" })?.value,
              (32 ... 512).contains(token.utf8.count),
              token.utf8.allSatisfy({ (65 ... 90).contains($0) || (97 ... 122).contains($0) ||
                  (48 ... 57).contains($0) || $0 == 45 || $0 == 95 })
        else { throw AIBridgeSetupError.invalidLink }
        return try AIBridgeSetup(server: validatedServer(server), token: token)
    }

    static func validatedServer(_ raw: String) throws -> URL {
        guard !raw.isEmpty, raw.utf8.count <= 2048,
              raw.utf8.allSatisfy({ (33 ... 126).contains($0) && $0 != 92 }) else { throw AIBridgeSetupError.invalidLink }
        // URLComponents.port can be nil for an overflowing explicit port, so inspect it before parsing.
        if let range = raw.range(of: #":[0-9]+/?$"#, options: .regularExpression) {
            let digits = raw[range].dropFirst().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let port = Int(digits), (1 ... 65535).contains(port) else { throw AIBridgeSetupError.invalidLink }
        }
        guard raw.range(of: #"^https?://(\[[0-9a-f:.]+\]|[a-z0-9.-]+)(?::[0-9]+)?/?$"#,
                        options: [.regularExpression, .caseInsensitive]) != nil,
              var parts = URLComponents(string: raw), let scheme = parts.scheme?.lowercased(),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              ["", "/"].contains(parts.percentEncodedPath),
              parts.port.map({ (1 ... 65535).contains($0) }) ?? true
        else { throw AIBridgeSetupError.invalidLink }
        let ipv4 = canonicalIPv4(host)
        let ipv6Host = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        var address = in6_addr()
        let ipv6 = ipv6Host.withCString { inet_pton(AF_INET6, $0, &address) == 1 }
        var legacyAddress = in_addr()
        let legacyIPv4 = host.withCString { inet_aton($0, &legacyAddress) == 1 }
        guard ipv4 != nil || !legacyIPv4 else { throw AIBridgeSetupError.invalidLink }
        guard validHostname(host) || ipv4 != nil || ipv6 else { throw AIBridgeSetupError.invalidLink }
        let privateIPv4 = ipv4.map { bytes in
            bytes[0] == 10 || bytes[0] == 127 || (bytes[0] == 172 && (16 ... 31).contains(bytes[1])) ||
                (bytes[0] == 192 && bytes[1] == 168) || (bytes[0] == 169 && bytes[1] == 254)
        } ?? false
        guard scheme == "https" || (scheme == "http" &&
            (host == "localhost" || host.hasSuffix(".local") || privateIPv4))
        else { throw AIBridgeSetupError.invalidLink }
        parts.scheme = scheme
        parts.host = host
        parts.path = ""
        if (scheme == "https" && parts.port == 443) || (scheme == "http" && parts.port == 80) { parts.port = nil }
        guard let url = parts.url else { throw AIBridgeSetupError.invalidLink }
        return url
    }

    private static func canonicalIPv4(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let bytes = parts.compactMap { part -> UInt8? in
            guard part.allSatisfy({ $0.isASCII && $0.isNumber }), let byte = UInt8(part), String(byte) == part else { return nil }
            return byte
        }
        return bytes.count == 4 ? bytes : nil
    }

    private static func validHostname(_ host: String) -> Bool {
        guard host.utf8.count <= 253,
              host.utf8.contains(where: { !(48 ... 57).contains($0) && $0 != 46 }) else { return false }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
                label.utf8.allSatisfy { (97 ... 122).contains($0) || (48 ... 57).contains($0) || $0 == 45 }
        }
    }

    func healthRequest() -> URLRequest {
        var request = URLRequest(url: server.appendingPathComponent("api/health"))
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func validateHealth(_ data: Data, status: Int) throws {
        struct Health: Decodable { let ok: Bool; let service: String }
        guard status == 200, data.count <= 8192,
              let health = try? JSONDecoder().decode(Health.self, from: data), health.ok, health.service == "trio-mcp"
        else { throw AIBridgeSetupError.healthCheck }
    }

    func checkHealth() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration, delegate: AIBridgeSetupRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: healthRequest())
        try Self.validateHealth(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

enum AIBridgeSetupError: LocalizedError {
    case invalidLink, healthCheck, configChanged, syncing, keychain

    var errorDescription: String? {
        switch self {
        case .invalidLink: return "Der Einrichtungslink ist ungültig oder wird nicht unterstützt."
        case .healthCheck: return "Die KI-Bridge konnte nicht authentifiziert werden. Prüfe Server, Netzwerk und Einrichtungslink."
        case .configChanged: return "Die Verbindung wurde inzwischen geändert. Schließe den Dialog und öffne den Einrichtungslink erneut."
        case .syncing: return "Die Bridge synchronisiert gerade. Warte kurz und versuche es erneut."
        case .keychain: return "Der Token konnte nicht sicher gespeichert werden. Die vorhandene Konfiguration bleibt erhalten."
        }
    }
}

private final class AIBridgeSetupRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
                    newRequest _: URLRequest, completionHandler: @escaping (URLRequest?) -> Void)
    {
        completionHandler(nil)
    }
}

struct AIBridgeSetupPresentation {
    let setup: AIBridgeSetup?

    init(url: URL) { setup = try? AIBridgeSetup.parse(url.absoluteString) }
}

/// Present above an existing Settings sheet; defer while a system or therapy alert is visible.
@MainActor enum AIBridgeSetupPresenter {
    private static var presentationTask: Task<Void, Never>?

    static func present(_ presentation: AIBridgeSetupPresentation) {
        presentationTask?.cancel()
        presentationTask = Task {
            while !Task.isCancelled {
                if let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
                   var top = scene.windows.first(where: \.isKeyWindow)?.rootViewController
                {
                    while let next = top.presentedViewController { top = next }
                    if !(top is UIAlertController), !(top is UIHostingController<AIBridgeSetupView>),
                       !top.isBeingPresented, !top.isBeingDismissed, top.viewIfLoaded?.window != nil
                    {
                        let controller = UIHostingController(rootView: AIBridgeSetupView(presentation: presentation))
                        controller.modalPresentationStyle = .pageSheet
                        top.present(controller, animated: true)
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }
}

@MainActor private struct AIBridgeSetupView: View {
    let presentation: AIBridgeSetupPresentation
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var saved = false
    @State private var message: String?
    @State private var requestTask: Task<Void, Never>?
    @State private var previousURL = ClaudeBridgeConfig.baseURL
    @State private var previousToken = ClaudeBridgeConfig.token
    @State private var previousEnabled = ClaudeBridgeConfig.enabled

    var body: some View {
        NavigationStack {
            Form {
                if let setup = presentation.setup {
                    Section("Server") { Text(setup.server.absoluteString).textSelection(.enabled) }
                    if saved {
                        Section {
                            Text("Verbindung geprüft und gespeichert. Die KI-Bridge ist ausgeschaltet. Du kannst sie unter Einstellungen → KI-Bridge aktivieren.")
                        }
                    } else {
                        Section {
                            Text("Trio prüft nur die Anmeldung am Server. Dabei werden keine Einstellungen und keine Verlaufsdaten hochgeladen. Der Token wird im Schlüsselbund gespeichert und nicht angezeigt.")
                            if !previousURL.isEmpty || previousToken != nil {
                                Text("Die vorhandene Bridge-Verbindung wird nach erfolgreicher Prüfung ersetzt und ausgeschaltet.").bold()
                            }
                            Button(working ? "Verbindung wird geprüft …" : "Prüfen und ausgeschaltet speichern") {
                                requestTask = Task { await save(setup) }
                            }.disabled(working)
                            if working { ProgressView() }
                        }
                    }
                    if let message { Text(message).foregroundStyle(.red) }
                } else {
                    Text(AIBridgeSetupError.invalidLink.localizedDescription)
                }
            }
            .navigationTitle("KI-Bridge einrichten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(saved ? "Fertig" : "Abbrechen") { requestTask?.cancel(); dismiss() }
                }
            }
        }
        .interactiveDismissDisabled(working)
        .onDisappear { requestTask?.cancel() }
    }

    @MainActor private func save(_ setup: AIBridgeSetup) async {
        working = true
        message = nil
        defer { working = false }
        do {
            guard !ClaudeBridgeService.shared.isSyncing else { throw AIBridgeSetupError.syncing }
            try await setup.checkHealth()
            try Task.checkCancellation()
            guard previousURL == ClaudeBridgeConfig.baseURL, previousToken == ClaudeBridgeConfig.token,
                  previousEnabled == ClaudeBridgeConfig.enabled else { throw AIBridgeSetupError.configChanged }
            guard !ClaudeBridgeService.shared.isSyncing else { throw AIBridgeSetupError.syncing }
            guard ClaudeBridgeConfig.setToken(setup.token) else { throw AIBridgeSetupError.keychain }
            ClaudeBridgeConfig.enabled = false
            ClaudeBridgeConfig.baseURL = setup.server.absoluteString
            ClaudeBridgeService.shared.resetConnectionState()
            Foundation.NotificationCenter.default.post(name: .aiBridgeConfigurationChanged, object: nil)
            saved = true
        } catch is CancellationError {
            return
        } catch {
            message = (error as? AIBridgeSetupError ?? .healthCheck).localizedDescription
        }
    }
}

extension Notification.Name {
    static let aiBridgeConfigurationChanged = Notification.Name("aiBridgeConfigurationChanged")
}
