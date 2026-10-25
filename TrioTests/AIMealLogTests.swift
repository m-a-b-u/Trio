import Foundation
import Testing
@testable import Trio

@Suite("AI meal log, text-only input and web search") struct AIMealLogTests {
    private let estimate = AIMealEstimate(
        items: [.init(name: "Spaghetti", grams: 300, carbs: 90, fat: 4, protein: 15)],
        carbs: 90, fat: 12, protein: 20, confidence: "medium", notes: "Synthetisch", shortNote: "🍝 Pasta"
    )

    private func configuration(_ provider: AIMealProvider) -> AIMealConfiguration {
        AIMealConfiguration(provider: provider, model: "synthetic-model", baseURL: "https://compatible.example/v1")
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func store() -> AIMealLogStore {
        AIMealLogStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("AIMealLogTests-\(UUID().uuidString)"))
    }

    @Test("Text-only requests send no image; empty input is rejected") func textOnly() throws {
        for provider in [AIMealProvider.anthropic, .openAI, .openAICompatible] {
            let request = try AIMealService.makeRequest(
                configuration: configuration(provider), apiKey: "synthetic-key", jpeg: nil, userHint: "300 g Spaghetti"
            )
            let json = String(decoding: try #require(request.httpBody), as: UTF8.self)
            #expect(json.contains("300 g Spaghetti"))
            #expect(!json.contains("base64"))
            #expect(throws: AIMealError.self) {
                _ = try AIMealService.makeRequest(configuration: configuration(provider), apiKey: "synthetic-key", jpeg: nil, userHint: "  ")
            }
        }
    }

    @Test("Web search adds the provider tool only when enabled and supported") func webSearchTools() throws {
        let anthropic = try body(AIMealService.makeRequest(
            configuration: configuration(.anthropic), apiKey: "k", jpeg: Data([1]), userHint: "", webSearch: true
        ))
        let anthropicTool = try #require((anthropic["tools"] as? [[String: Any]])?.first)
        #expect(anthropicTool["type"] as? String == "web_search_20250305")
        #expect(AIMealService.anthropicWebSearchType(model: "claude-opus-5-5") == "web_search_20260209")
        #expect(AIMealService.anthropicWebSearchType(model: "claude-sonnet-4-5") == "web_search_20250305")
        #expect((anthropic["system"] as? String)?.contains("web search") == true)

        let openAI = try body(AIMealService.makeRequest(
            configuration: configuration(.openAI), apiKey: "k", jpeg: nil, userHint: "Big Mac", webSearch: true
        ))
        #expect((openAI["tools"] as? [[String: Any]])?.first?["type"] as? String == "web_search")

        let off = try body(AIMealService.makeRequest(configuration: configuration(.anthropic), apiKey: "k", jpeg: Data([1]), userHint: ""))
        #expect(off["tools"] == nil)
        let compatible = try body(AIMealService.makeRequest(
            configuration: configuration(.openAICompatible), apiKey: nil, jpeg: Data([1]), userHint: "", webSearch: true
        ))
        #expect(compatible["tools"] == nil)
    }

    @Test("Anthropic answers after web search results are parsed; paused turns are incomplete") func webSearchResponse() throws {
        let answer = #"{"items":[],"carbs":45,"fat":25,"protein":26,"confidence":"high","notes":"Herstellerangabe","short_note":"Burger"}"#
        let response: [String: Any] = [
            "stop_reason": "end_turn",
            "content": [
                ["type": "text", "text": "Ich suche die Nährwerte {nicht JSON}."],
                ["type": "server_tool_use", "id": "1", "name": "web_search", "input": ["query": "Big Mac"]],
                ["type": "web_search_tool_result", "tool_use_id": "1", "content": []],
                ["type": "text", "text": String(answer.prefix(40))],
                ["type": "text", "text": String(answer.dropFirst(40))]
            ]
        ]
        let estimate = try AIMealService.parseResponse(
            JSONSerialization.data(withJSONObject: response), status: 200, provider: .anthropic
        )
        #expect(estimate.carbs == 45)
        #expect(estimate.notes == "Herstellerangabe")

        let paused: [String: Any] = ["stop_reason": "pause_turn", "content": [["type": "text", "text": answer]]]
        #expect(throws: AIMealError.self) {
            _ = try AIMealService.parseResponse(JSONSerialization.data(withJSONObject: paused), status: 200, provider: .anthropic)
        }
    }

    @Test("Analyses are stored with photo, applied values and upload revisions") func logLifecycle() throws {
        let store = store()
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let id = try #require(store.record(
            estimate: estimate, configuration: configuration(.anthropic), webSearch: true, description: " 300 g ", jpeg: jpeg
        ))
        let textOnly = try #require(store.record(
            estimate: estimate, configuration: configuration(.openAI), webSearch: false, description: "Apfel", jpeg: nil
        ))

        #expect(store.photo(for: id) == jpeg)
        #expect(store.photo(for: textOnly) == nil)
        #expect(store.entries().first?.description == "300 g")
        #expect(store.pendingUploads(limit: 10).count == 2)

        store.markUploaded([id: 1, textOnly: 1])
        #expect(store.pendingUploads(limit: 10).isEmpty)

        store.markApplied(id, carbs: 85, fat: 12, protein: 20, note: "Pasta")
        let pending = store.pendingUploads(limit: 10)
        #expect(pending.map(\.id) == [id])
        #expect(pending.first?.revision == 2)

        let payload = store.uploadPayload(try #require(pending.first))
        #expect(payload["photo"] as? String == jpeg.base64EncodedString())
        #expect((payload["applied"] as? [String: Any])?["carbs"] as? Double == 85)
        #expect((payload["estimate"] as? [String: Any])?["shortNote"] as? String == "🍝 Pasta")
        let textEntry = try #require(store.entries().last)
        #expect(store.uploadPayload(textEntry)["photo"] == nil)

        store.resetUploadState()
        #expect(store.pendingUploads(limit: 10).count == 2)
    }

    @Test("Old entries and their photos are pruned") func retention() throws {
        let store = store()
        let old = try #require(store.record(
            estimate: estimate, configuration: configuration(.anthropic), webSearch: false, description: "alt",
            jpeg: Data([0xFF, 0xD8]), now: Date().addingTimeInterval(-AIMealLogStore.retention - 3600)
        ))
        _ = store.record(estimate: estimate, configuration: configuration(.anthropic), webSearch: false, description: "neu", jpeg: nil)
        #expect(store.entries().map(\.description) == ["neu"])
        #expect(store.photo(for: old) == nil)
    }
}
