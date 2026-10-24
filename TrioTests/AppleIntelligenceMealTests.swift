import Foundation
import Testing
@testable import Trio
#if canImport(FoundationModels)
    import FoundationModels
#endif

@Suite("Apple Intelligence Meal") struct AppleIntelligenceMealTests {
    private func fails(_ operation: () throws -> Void) -> Bool {
        do { try operation(); return false } catch { return true }
    }

    @Test("Descriptions are trimmed and bounded without silent truncation")
    func descriptionValidation() throws {
        let description = try AppleIntelligenceMealService.preparedDescription(" \n150 g gekochter Reis\n ")
        #expect(description == "150 g gekochter Reis")
        #expect(fails { _ = try AppleIntelligenceMealService.preparedDescription(" \n ") })
        #expect(fails { _ = try AppleIntelligenceMealService.preparedDescription(String(repeating: "ä", count: 2001)) })
        let boundary = try AppleIntelligenceMealService.preparedDescription(String(repeating: "ä", count: 2000))
        #expect(boundary.count == 2000)
    }

    @Test("Availability distinguishes OS, hardware, settings, model and locale", arguments: AppleIntelligenceMealService.AvailabilityState.allCases)
    func availabilityMapping(_ state: AppleIntelligenceMealService.AvailabilityState) {
        let status = AppleIntelligenceMealService.status(for: state)
        #expect(status.available == (state == .available))
        #expect(!status.message.isEmpty)
        let messages = AppleIntelligenceMealService.AvailabilityState.allCases.map { AppleIntelligenceMealService.status(for: $0).message }
        #expect(Set(messages).count == messages.count)
    }

    @Test("Cancellation stays cancellation and unknown errors do not expose details")
    func genericErrors() {
        #expect(AppleIntelligenceMealService.normalizedError(CancellationError()) is CancellationError)
        let error = NSError(domain: "synthetic-private-error", code: 1, userInfo: [NSLocalizedDescriptionKey: "private-input"])
        let mapped = AppleIntelligenceMealService.normalizedError(error)
        #expect(mapped as? AppleIntelligenceMealError == .failed)
        #expect(!mapped.localizedDescription.contains("private"))
        let missing = AppleIntelligenceMealService.normalizedError(AppleIntelligenceMealError.missingPortion)
        #expect(missing as? AppleIntelligenceMealError == .missingPortion)
    }

    #if canImport(FoundationModels)
        @available(iOS 26.0, macOS 26.0, *)
        private func item(carbs: Double = 20, grams: Double = 100, name: String = "Reis") -> AppleMealDraftItem {
            AppleMealDraftItem(name: name, grams: grams, carbs: carbs, fat: 2, protein: 3)
        }

        @available(iOS 26.0, macOS 26.0, *)
        private func draft(items: [AppleMealDraftItem], usable: Bool = true) -> AppleMealDraft {
            AppleMealDraft(
                hasUsablePortion: usable, items: items, confidence: .low,
                notes: "Synthetische Portionsschätzung", shortNote: "Reis"
            )
        }

        @available(iOS 26.0, macOS 26.0, *)
        @Test("Structured item values are summed in Swift and keep uncertainty")
        func structuredMapping() throws {
            let estimate = try AppleIntelligenceMealService.mappedEstimate(draft(items: [item(), item(carbs: 10, name: "Gemüse")]))
            #expect(estimate.carbs == 30)
            #expect(estimate.fat == 4)
            #expect(estimate.protein == 6)
            #expect(estimate.items.count == 2)
            #expect(estimate.confidence == "low")
            #expect(estimate.notes == "Synthetische Portionsschätzung")
        }

        @available(iOS 26.0, macOS 26.0, *)
        @Test("Missing portions and empty output require clarification, never a zero meal")
        func missingPortion() {
            for value in [draft(items: []), draft(items: [item()], usable: false)] {
                do {
                    _ = try AppleIntelligenceMealService.mappedEstimate(value)
                    Issue.record("Eine fehlende Portion muss einen Klärungsfehler auslösen.")
                } catch {
                    #expect(error as? AppleIntelligenceMealError == .missingPortion)
                }
            }
            let zero = AppleMealDraftItem(name: "Unbekannt", grams: 100, carbs: 0, fat: 0, protein: 0)
            #expect(fails { _ = try AppleIntelligenceMealService.mappedEstimate(draft(items: [zero])) })
        }

        @available(iOS 26.0, macOS 26.0, *)
        @Test("Generated constraints are revalidated, including sums and non-finite values")
        func invalidStructuredValues() {
            let invalidItems = [item(carbs: -1), item(carbs: 1000), item(carbs: .infinity), item(carbs: .nan),
                                item(grams: 0), item(grams: 10000), item(grams: .infinity), item(name: " ")]
            for invalid in invalidItems {
                #expect(fails { _ = try AppleIntelligenceMealService.mappedEstimate(draft(items: [invalid])) })
            }
            #expect(fails { _ = try AppleIntelligenceMealService.mappedEstimate(draft(items: [item(carbs: 600), item(carbs: 600)])) })
            #expect(fails { _ = try AppleIntelligenceMealService.mappedEstimate(draft(items: Array(repeating: item(), count: 9))) })
        }

        @available(iOS 26.0, macOS 26.0, *)
        @Test("Generated labels are bounded before reaching the meal form")
        func outputTextBounds() throws {
            var value = draft(items: [item()])
            value.notes = String(repeating: "a", count: 500)
            value.shortNote = String(repeating: "b", count: 50)
            let estimate = try AppleIntelligenceMealService.mappedEstimate(value)
            #expect(estimate.notes?.count == 400)
            #expect(estimate.shortNote?.count == 20)
        }

        @available(iOS 26.0, macOS 26.0, *)
        @Test("Foundation Models failures become fixed German messages")
        func foundationErrors() {
            let context = LanguageModelSession.GenerationError.Context(debugDescription: "synthetic-private-error")
            let cases: [(LanguageModelSession.GenerationError, AppleIntelligenceMealError)] = [
                (.assetsUnavailable(context), .unavailable(AppleIntelligenceMealService.status(for: .modelNotReady).message)),
                (.unsupportedLanguageOrLocale(context), .unavailable(AppleIntelligenceMealService.status(for: .unsupportedLocale).message)),
                (.guardrailViolation(context), .refused),
                (.rateLimited(context), .busy),
                (.decodingFailure(context), .invalidEstimate),
                (.exceededContextWindowSize(context), .descriptionTooLong)
            ]
            for (error, expected) in cases {
                let mapped = AppleIntelligenceMealService.normalizedError(error)
                #expect(mapped as? AppleIntelligenceMealError == expected)
                #expect(!mapped.localizedDescription.contains("synthetic-private"))
            }
        }
    #endif
}
