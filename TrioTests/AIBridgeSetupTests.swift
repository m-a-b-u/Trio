import Foundation
import Testing
@testable import Trio

@Suite("Private AI bridge setup") struct AIBridgeSetupTests {
    private let token = "synthetic_token_12345678901234567890"

    private func link(server: String = "http://Odin.local:8765/", token: String? = nil) -> String {
        var parts = URLComponents()
        parts.scheme = "Trio"
        parts.host = "ai-bridge-setup"
        parts.queryItems = [URLQueryItem(name: "version", value: "1"), URLQueryItem(name: "server", value: server),
                            URLQueryItem(name: "token", value: token ?? self.token)]
        return parts.string!
    }

    @Test("Valid private setup normalizes the server and keeps the opaque token") func validLink() throws {
        let setup = try AIBridgeSetup.parse(link())
        #expect(setup.server.absoluteString == "http://odin.local:8765")
        #expect(setup.token == token)
        let uppercase = try AIBridgeSetup.parse(link().replacingOccurrences(of: "Trio://", with: "TRIO://"))
        #expect(uppercase == setup)
        let rootPath = try AIBridgeSetup.parse(link().replacingOccurrences(of: "setup?", with: "setup/?"))
        #expect(rootPath == setup)
    }

    @Test("Link envelope rejects duplicates, missing fields, unsupported versions and other destinations") func invalidEnvelope() {
        let valid = link()
        for invalid in [
            valid + "&version=1", valid + "&token=" + token, valid + "&other=value", valid + "#fragment",
            valid.replacingOccurrences(of: "version=1", with: "version=2"),
            valid.replacingOccurrences(of: "version=1&", with: ""),
            valid.replacingOccurrences(of: "token=", with: "wrong="),
            valid.replacingOccurrences(of: "Trio://", with: "https://"),
            valid.replacingOccurrences(of: "ai-bridge-setup", with: "other-host"),
            valid.replacingOccurrences(of: "ai-bridge-setup?", with: "ai-bridge-setup/path?"),
            valid.replacingOccurrences(of: "ai-bridge-setup?", with: "ai-bridge-setup:8765?"),
            valid.replacingOccurrences(of: "ai-bridge-setup?", with: "ai-bridge-setup:999999999999999999999?"),
            valid.replacingOccurrences(of: "Trio://", with: "Trio://user@"),
            valid + String(repeating: "a", count: 8193), "not a URL"
        ] {
            #expect(throws: (any Error).self) { try AIBridgeSetup.parse(invalid) }
        }
    }

    @Test("Tokens have a bounded base64url form and cannot inject headers") func tokenValidation() throws {
        for accepted in [String(repeating: "a", count: 32), String(repeating: "_", count: 512)] {
            let setup = try AIBridgeSetup.parse(link(token: accepted))
            #expect(setup.token == accepted)
        }
        for invalid in ["", "short", String(repeating: "a", count: 513), token + "\r\nInjected: yes",
                        token + " ", token + "+", token + "/", token + "=", token + "ä"]
        {
            #expect(throws: (any Error).self) { try AIBridgeSetup.parse(link(token: invalid)) }
        }
    }

    @Test("HTTP is limited to agreed local hosts and canonical private IPv4") func allowedServers() throws {
        for server in [
            "http://localhost:8765", "http://Odin.local:8765/", "http://127.0.0.1:8765", "http://10.0.0.1",
            "http://172.16.0.1", "http://172.31.255.254", "http://192.168.1.20", "http://169.254.1.20",
            "https://example.com", "https://8.8.8.8", "https://[2001:db8::1]:8765"
        ] {
            _ = try AIBridgeSetup.parse(link(server: server))
        }
        let normalized = try AIBridgeSetup.validatedServer("HTTPS://EXAMPLE.COM:443/")
        #expect(normalized.absoluteString == "https://example.com")
    }

    @Test("Server validation rejects public HTTP, unsafe components and malformed hosts") func rejectedServers() {
        for server in [
            "http://example.com", "http://odin", "http://192.169.1.20", "http://172.32.0.1", "http://169.255.1.20", "http://0.0.0.0",
            "http://[::1]", "ftp://odin.local", "http://user:secret@odin.local", "http://odin.local/app",
            "http://odin.local/./", "http://odin.local/%2f", "http://odin.local?token=secret", "http://odin.local#fragment",
            "http://odin.local:0", "http://odin.local:65536", "http://odin.local:999999999999999999999",
            "http://odin.local:", "http://bad-.local",
            "http://.local", "http://odin.local.", "http://odin.local\\@evil.example", "http://odin.local\n",
            "https://[notipv6]", "https://%65xample.com", "https://ex ample.com", "https://" + String(repeating: "a", count: 2048)
        ] {
            #expect(throws: (any Error).self) { try AIBridgeSetup.parse(link(server: server)) }
        }
    }

    @Test("Alternate numeric addresses cannot bypass host validation") func numericHosts() {
        for host in ["127.1", "2130706433", "0x7f000001", "0x7f.0.0.1", "0177.0.0.1", "127.0.0.01", "192.168.1"] {
            for scheme in ["http", "https"] {
                #expect(throws: (any Error).self) { try AIBridgeSetup.validatedServer("\(scheme)://\(host)") }
            }
        }
    }

    @Test("Health check only sends an authenticated GET with no payload or query") func healthRequest() throws {
        let request = try AIBridgeSetup.parse(link()).healthRequest()
        #expect(request.url?.absoluteString == "http://odin.local:8765/api/health")
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
        #expect(request.timeoutInterval == 15)
    }

    @Test("Only the exact successful health response is accepted") func healthResponse() throws {
        let valid = Data(#"{"ok":true,"service":"trio-mcp"}"#.utf8)
        try AIBridgeSetup.validateHealth(valid, status: 200)
        for status in [0, 201, 204, 301, 302, 307, 401, 403, 500] {
            #expect(throws: (any Error).self) { try AIBridgeSetup.validateHealth(valid, status: status) }
        }
        for invalid in [#"{"ok":false,"service":"trio-mcp"}"#, #"{"ok":1,"service":"trio-mcp"}"#,
                        #"{"ok":true,"service":"other"}"#, "{}", "not JSON", String(repeating: "a", count: 8193)]
        {
            #expect(throws: (any Error).self) { try AIBridgeSetup.validateHealth(Data(invalid.utf8), status: 200) }
        }
    }
}
