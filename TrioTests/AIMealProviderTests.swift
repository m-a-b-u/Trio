import Foundation
import Testing
@testable import Trio

@Suite("AI Meal Providers") struct AIMealProviderTests {
    private let estimateJSON = """
    {"items":[{"name":"Testmahlzeit","grams":100,"carbs":20,"fat":5,"protein":8}],"carbs":20,"fat":5,"protein":8,"confidence":"medium","notes":"Synthetischer Test","short_note":"Test"}
    """

    private func configuration(_ provider: AIMealProvider) -> AIMealConfiguration {
        AIMealConfiguration(provider: provider, model: "test-vision-model", baseURL: "https://vision.example/v1/")
    }

    private func fails(_ operation: () throws -> Void) -> Bool {
        do { try operation(); return false } catch { return true }
    }

    @Test("Each provider receives its own endpoint, auth and image schema", arguments: AIMealProvider.allCases)
    func requestFormat(_ provider: AIMealProvider) throws {
        let request = try AIMealService.makeRequest(
            configuration: configuration(provider), apiKey: "synthetic-key", jpeg: Data([1, 2, 3]), userHint: "Testportion"
        )
        let body = try #require(JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: Any])
        #expect(request.httpMethod == "POST")
        #expect(body["model"] as? String == "test-vision-model")
        switch provider {
        case .anthropic:
            #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == "synthetic-key")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            let messages = try #require(body["messages"] as? [[String: Any]])
            let content = try #require(messages.first?["content"] as? [[String: Any]])
            #expect((content.first?["source"] as? [String: Any])?["data"] as? String == "AQID")
        case .openAI:
            #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-key")
            #expect(body["store"] as? Bool == false)
            #expect(body["messages"] == nil)
            let input = try #require(body["input"] as? [[String: Any]])
            let content = try #require(input.first?["content"] as? [[String: Any]])
            #expect(content.last?["type"] as? String == "input_image")
            #expect(content.last?["image_url"] as? String == "data:image/jpeg;base64,AQID")
        case .openAICompatible:
            #expect(request.url?.absoluteString == "https://vision.example/v1/chat/completions")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-key")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
            let messages = try #require(body["messages"] as? [[String: Any]])
            let content = try #require(messages.last?["content"] as? [[String: Any]])
            #expect(content.last?["type"] as? String == "image_url")
            #expect((content.last?["image_url"] as? [String: Any])?["url"] as? String == "data:image/jpeg;base64,AQID")
        }
    }

    @Test("Each provider response yields the same editable estimate", arguments: AIMealProvider.allCases)
    func responseFormat(_ provider: AIMealProvider) throws {
        let response: [String: Any]
        switch provider {
        case .anthropic:
            response = ["content": [["type": "text", "text": estimateJSON]], "stop_reason": "end_turn"]
        case .openAI:
            response = ["status": "completed", "output": [
                ["type": "reasoning", "summary": []],
                ["type": "message", "content": [["type": "output_text", "text": estimateJSON]]]
            ]]
        case .openAICompatible:
            response = ["choices": [["finish_reason": "stop", "message": ["content": estimateJSON]]]]
        }
        let data = try JSONSerialization.data(withJSONObject: response)
        let estimate = try AIMealService.parseResponse(data, status: 200, provider: provider)
        #expect(estimate.carbs == 20)
        #expect(estimate.fat == 5)
        #expect(estimate.protein == 8)
        #expect(estimate.items.first?.grams == 100)
    }

    @Test("HTTP errors and empty responses fail for every provider", arguments: AIMealProvider.allCases)
    func providerErrors(_ provider: AIMealProvider) {
        let data = Data("{\"error\":{\"message\":\"Synthetic failure\"}}".utf8)
        do {
            _ = try AIMealService.parseResponse(data, status: 429, provider: provider)
            #expect(false)
        } catch {
            #expect(error.localizedDescription == "KI-API Fehler 429.")
        }
        #expect(fails { _ = try AIMealService.parseResponse(Data("{}".utf8), status: 200, provider: provider) })
    }

    @Test("Compatible local services can omit API credentials") func compatibleWithoutKey() throws {
        let local = AIMealConfiguration(provider: .openAICompatible, model: "local-vision", baseURL: "http://localhost:8080/v1")
        let request = try AIMealService.makeRequest(configuration: local, apiKey: nil, jpeg: Data([1]), userHint: "")
        #expect(request.url?.absoluteString == "http://localhost:8080/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
    }

    @Test("Partial output is not accepted as a completed estimate") func incompleteResponse() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "status": "incomplete", "output": [["type": "message", "content": [["type": "output_text", "text": estimateJSON]]]]
        ])
        #expect(fails { _ = try AIMealService.parseResponse(data, status: 200, provider: .openAI) })
    }

    @Test("Invalid model, missing key and empty images cannot form a request") func requiredConfiguration() {
        let emptyModel = AIMealConfiguration(provider: .openAI, model: " ", baseURL: "")
        #expect(fails { _ = try AIMealService.makeRequest(configuration: emptyModel, apiKey: "test", jpeg: Data([1]), userHint: "") })
        #expect(fails { _ = try AIMealService.makeRequest(configuration: configuration(.anthropic), apiKey: nil, jpeg: Data([1]), userHint: "") })
        #expect(fails { _ = try AIMealService.makeRequest(configuration: configuration(.openAI), apiKey: "test", jpeg: Data(), userHint: "") })
    }

    @Test("Compatible endpoint keys cannot move to another host, port or API path") func endpointCredentialBinding() throws {
        let first = try AIMealSettingsStore.credentialIdentity(for: .openAICompatible, baseURL: "https://EXAMPLE.com:443/v1/")
        let normalized = try AIMealSettingsStore.credentialIdentity(for: .openAICompatible, baseURL: "https://example.com/v1")
        #expect(first.account == normalized.account)
        for url in ["https://other.example/v1", "https://example.com:8443/v1", "https://example.com/v2"] {
            let other = try AIMealSettingsStore.credentialIdentity(for: .openAICompatible, baseURL: url)
            #expect(first.account != other.account)
        }
        let openAI = try AIMealSettingsStore.credentialIdentity(for: .openAI)
        #expect(first.account != openAI.account)
    }

    @Test("Only HTTPS or loopback HTTP base URLs are accepted") func endpointValidation() throws {
        let loopback = try AIMealConfiguration.normalizedBaseURL("http://127.0.0.1:8080/v1/")
        let localhost = try AIMealConfiguration.normalizedBaseURL("http://localhost:8080/v1")
        #expect(loopback.absoluteString == "http://127.0.0.1:8080/v1")
        #expect(localhost.host == "localhost")
        for url in ["", "ftp://example.com/v1", "http://example.com/v1", "https://user:password@example.com/v1", "https://example.com/v1?key=test", "https://example.com/v1#secret"] {
            #expect(fails { _ = try AIMealConfiguration.normalizedBaseURL(url) })
        }
    }

    @Test("Upgrade keeps the original Anthropic key identity and model") func legacyMigration() throws {
        let suite = "AIMealProviderTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("legacy-custom-model", forKey: "claude.meal.model")
        #expect(AIMealSettingsStore.provider(defaults: defaults) == .anthropic)
        #expect(AIMealSettingsStore.model(for: .anthropic, defaults: defaults) == "legacy-custom-model")
        #expect(AIMealSettingsStore.model(for: .openAI, defaults: defaults).isEmpty)
        let identity = try AIMealSettingsStore.credentialIdentity(for: .anthropic)
        #expect(identity.service == "org.nightscout.trio.claude")
        #expect(identity.account == "anthropic_api_key")
    }

    @Test("Invalid item values cannot reach the editable form") func invalidNutrition() {
        #expect(fails { _ = try AIMealService.parse(estimateJSON.replacingOccurrences(of: "\"grams\":100", with: "\"grams\":1e30")) })
        #expect(fails { _ = try AIMealService.parse(estimateJSON.replacingOccurrences(of: "\"carbs\":20", with: "\"carbs\":-1")) })
        #expect(fails { _ = try AIMealService.parse("not JSON") })
    }
}
