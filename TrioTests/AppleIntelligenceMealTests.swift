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
        private func item(
            carbsPer100g: Double = 20, fatPer100g: Double = 2, proteinPer100g: Double = 3,
            grams: Double = 100, name: String = "Reis"
        ) -> AppleMealDraftItem {
            AppleMealDraftItem(
                name: name, grams: grams, carbsPer100g: carbsPer100g, fatPer100g: fatPer100g, proteinPer100g: proteinPer100g
            )
        }

        @available(iOS 26.0, macOS 26.0, *)
        private func draft(items: [AppleMealDraftItem], usable: Bool = true) -> AppleMealDraft {
            AppleMealDraft(
                hasUsablePortion: usable, items: items,
                notes: "Synthetische Portionsschätzung", shortNote: "Reis"
            )
        }

        @available(iOS 26.0, macOS 26.0, *)
        @Test("Swift calculates 150 g at 3.5 percent plus a second 30 g portion without premature rounding")
        func structuredMapping() throws {
            let yogurt = item(carbsPer100g: 4.8, fatPer100g: 3.5, proteinPer100g: 3.6, grams: 150, name: "Naturjoghurt")
            let oats = item(carbsPer100g: 60, fatPer100g: 7, proteinPer100g: 13, grams: 30, name: "Haferflocken")
            let estimate = try AppleIntelligenceMealService.mappedEstimate(draft(items: [yogurt, oats]))
            #expect(estimate.items.first?.fat == 5.25)
            #expect(abs(estimate.carbs - 25.2) < 1e-9)
            #expect(abs(estimate.fat - 7.35) < 1e-9)
            #expect(abs(estimate.protein - 9.3) < 1e-9)
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
            let zero = item(carbsPer100g: 0, fatPer100g: 0, proteinPer100g: 0)
            #expect(fails { _ = try AppleIntelligenceMealService.mappedEstimate(draft(items: [zero])) })
        }

        @available(iOS 26.0, macOS 26.0, *)
        @Test("Generated constraints are revalidated, including sums and non-finite values")
        func invalidStructuredValues() {
            let invalidItems = [item(carbsPer100g: -1), item(carbsPer100g: 100.01), item(carbsPer100g: .infinity),
                                item(carbsPer100g: .nan), item(fatPer100g: -1), item(fatPer100g: 100.01),
                                item(fatPer100g: .infinity), item(proteinPer100g: -1), item(proteinPer100g: 100.01),
                                item(proteinPer100g: .nan), item(grams: 0), item(grams: -1), item(grams: 10000),
                                item(grams: .infinity), item(grams: .nan), item(name: " ")]
            for invalid in invalidItems {
                #expect(fails { _ = try AppleIntelligenceMealService.mappedEstimate(draft(items: [invalid])) })
            }
            let large = item(carbsPer100g: 60, grams: 1000)
            #expect(fails { _ = try AppleIntelligenceMealService.mappedEstimate(draft(items: [large, large])) })
            #expect(fails { _ = try AppleIntelligenceMealService.mappedEstimate(draft(items: Array(repeating: item(), count: 9))) })
        }

        @available(iOS 26.0, macOS 26.0, *)
        @Test("Nutrients cannot exceed 100 g per 100 g; a pure nutrient remains valid")
        func per100gMassLimit() throws {
            let impossible = item(carbsPer100g: 60, fatPer100g: 30, proteinPer100g: 10.01)
            #expect(fails { _ = try AppleIntelligenceMealService.mappedEstimate(draft(items: [impossible])) })
            let oil = item(carbsPer100g: 0, fatPer100g: 100, proteinPer100g: 0, grams: 10, name: "Öl")
            let estimate = try AppleIntelligenceMealService.mappedEstimate(draft(items: [oil]))
            #expect(estimate.carbs == 0)
            #expect(estimate.fat == 10)
            #expect(estimate.protein == 0)
            #expect(estimate.confidence == "low")
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
