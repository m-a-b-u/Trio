import CoreData
import Foundation
import Testing
@testable import Trio

@Suite("Additional AI Settings", .serialized) @MainActor struct AIAdditionalSettingsTests {
    private func context() throws -> NSManagedObjectContext {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: CoreDataStack.managedObjectModel)
        try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        return context
    }

    private func patch(_ rows: [[String: ClaudeJSONValue]]) -> [String: ClaudeJSONValue] {
        ["presets": .array(rows.map(ClaudeJSONValue.object))]
    }

    private func meal(id: String = UUID().uuidString, dish: String = "Synthetic meal") -> [String: ClaudeJSONValue] {
        ["id": .string(id), "dish": .string(dish), "carbs": .number(20), "fat": .number(5), "protein": .number(10)]
    }

    private func target(id: String = UUID().uuidString) -> [String: ClaudeJSONValue] {
        ["id": .string(id), "name": .string("Synthetic target"), "target": .number(120), "duration": .number(60), "halfBasalTarget": .null]
    }

    private func override(id: String = UUID().uuidString) -> [String: ClaudeJSONValue] {
        ["id": .string(id), "name": .string("Synthetic override"), "duration": .number(60), "indefinite": .bool(false),
         "percentage": .number(90), "target": .null, "advancedSettings": .bool(false), "smbIsOff": .bool(false),
         "smbIsScheduledOff": .bool(false), "start": .null, "end": .null, "isfAndCr": .bool(true), "isf": .bool(false),
         "cr": .bool(false), "smbMinutes": .null, "uamMinutes": .null]
    }

    @Test("Diagnostics accepts only native sharing modes") func diagnosticsValidation() throws {
        let old: [String: ClaudeJSONValue] = ["sharingOption": .string("full")]
        for option in ["full", "crashOnly", "disabled"] {
            let next = try AIAdditionalSettings.validatePatch(["sharingOption": .string(option)], current: old, target: "diagnostics")
            #expect(next["sharingOption"] == .string(option))
        }
        for invalid in [ClaudeJSONValue.string("telemetryOnly"), .bool(false)] {
            #expect(throws: (any Error).self) {
                try AIAdditionalSettings.validatePatch(["sharingOption": invalid], current: old, target: "diagnostics")
            }
        }
        #expect(throws: (any Error).self) {
            try AIAdditionalSettings.validatePatch(["unknown": .bool(true)], current: old, target: "diagnostics")
        }
    }

    @Test("Simulator preserves explicit zero and enforces UI ranges and steps") func simulatorValidation() throws {
        let suiteName = "AIAdditionalSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(0, forKey: "GlucoseSimulator_NoiseAmplitude")
        let old = AIAdditionalSettings.simulatorValues(defaults: defaults)
        #expect(old["noiseAmplitude"] == .number(0))
        #expect(old["centerValue"] == .number(120))
        let next = try AIAdditionalSettings.validatePatch(["period": .number(5400), "simulatedScenario": .string("warmup")],
                                                         current: old, target: "cgm_simulator")
        #expect(next["period"] == .number(5400))
        #expect(defaults.object(forKey: "GlucoseSimulator_Period") == nil)
        let invalid: [[String: ClaudeJSONValue]] = [
            ["centerValue": .number(79)], ["amplitude": .number(11)], ["period": .number(3601)],
            ["noiseAmplitude": .number(.infinity)], ["produceStaleValues": .number(1)], ["simulatedScenario": .string("unknown")]
        ]
        for change in invalid {
            #expect(throws: (any Error).self) {
                try AIAdditionalSettings.validatePatch(change, current: old, target: "cgm_simulator")
            }
        }
    }

    @Test("Preset validation rejects duplicate IDs, invented IDs, unknown keys, invalid types and native limits")
    func presetValidation() throws {
        let valid = meal()
        #expect(try AIAdditionalSettings.validatePresets(patch([valid]), kind: .meals, current: []).count == 1)
        #expect(throws: (any Error).self) {
            try AIAdditionalSettings.validatePresets(patch([valid, valid]), kind: .meals, current: [])
        }
        let invalid: [[String: ClaudeJSONValue]] = [
            meal(id: "x-coredata://unrelated/MealPresetStored/p1"),
            valid.merging(["enabled": .bool(true)]) { _, new in new },
            valid.merging(["carbs": .string("20")]) { _, new in new },
            valid.merging(["protein": .number(-1)]) { _, new in new },
            valid.merging(["fat": .number(.nan)]) { _, new in new },
            meal(dish: ""), meal(dish: String(repeating: "a", count: 26))
        ]
        for row in invalid {
            #expect(throws: (any Error).self) { try AIAdditionalSettings.validatePresets(patch([row]), kind: .meals, current: []) }
        }
        for (kind, row) in [(AIPresetKind.tempTargets, target().merging(["duration": .number(0)]) { _, new in new }),
                            (.tempTargets, target().merging(["target": .number(201)]) { _, new in new }),
                            (.overrides, override().merging(["percentage": .number(151)]) { _, new in new }),
                            (.overrides, override().merging(["smbIsScheduledOff": .bool(true)]) { _, new in new }),
                            (.overrides, override().merging(["isf": .bool(true)]) { _, new in new }),
                            (.tempTargets, target().merging(["halfBasalTarget": .number(1e300)]) { _, new in new })]
        {
            #expect(throws: (any Error).self) { try AIAdditionalSettings.validatePresets(patch([row]), kind: kind, current: []) }
        }
    }

    @Test("Custom half-basal targets match native five-percent slider values") func halfBasalTargets() throws {
        #expect(AIAdditionalSettings.validHalfBasalTarget(120, target: 120, autosensMax: 1.2))
        #expect(AIAdditionalSettings.validHalfBasalTarget(220, target: 80, autosensMax: 1.2))
        #expect(!AIAdditionalSettings.validHalfBasalTarget(220, target: 80, autosensMax: 1.1))
        #expect(!AIAdditionalSettings.validHalfBasalTarget(120, target: 80, autosensMax: nil))
        #expect(!AIAdditionalSettings.validHalfBasalTarget(0, target: 120, autosensMax: 1.2))
        #expect(!AIAdditionalSettings.validHalfBasalTarget(121.3, target: 120, autosensMax: 1.2))
        #expect(!AIAdditionalSettings.validHalfBasalTarget(1e300, target: 120, autosensMax: 1.2))
    }

    @Test("Meal collection supports create, edit, delete and stable native identities") func mealRoundTrip() throws {
        let context = try context()
        try AIAdditionalSettings.replacePresets(.meals, with: [meal()], expected: [], context: context)
        let first = try AIAdditionalSettings.presetValues(.meals, context: context)
        #expect(first.count == 1)
        #expect(first[0]["id"]?.stringValue?.hasPrefix("x-coredata://") == true)
        var edited = first[0]
        edited["carbs"] = .number(25)
        try AIAdditionalSettings.replacePresets(.meals, with: [edited, meal(dish: "Second meal")], expected: first, context: context)
        let updated = try AIAdditionalSettings.presetValues(.meals, context: context)
        #expect(updated.contains { $0["id"] == first[0]["id"] && $0["carbs"] == .number(25) })
        try AIAdditionalSettings.replacePresets(.meals, with: [], expected: updated, context: context)
        #expect(try context.count(for: MealPresetStored.fetchRequest()) == 0)
    }

    @Test("Replacing presets leaves non-preset history and active therapy unchanged") func preserveTherapy() throws {
        let context = try context()
        for kind in [AIPresetKind.overrides, .tempTargets] {
            let history = NSEntityDescription.insertNewObject(forEntityName: kind.entity, into: context)
            history.setValue(false, forKey: "isPreset")
            history.setValue(true, forKey: "enabled")
            history.setValue("Synthetic running history", forKey: "name")
            try context.save()
            let row = kind == .overrides ? override() : target()
            try AIAdditionalSettings.replacePresets(kind, with: [row], expected: [], context: context)
            let presets = try AIAdditionalSettings.presetValues(kind, context: context)
            try AIAdditionalSettings.replacePresets(kind, with: [], expected: presets, context: context)
            #expect(!history.isDeleted)
            #expect(history.value(forKey: "enabled") as? Bool == true)
            #expect(history.value(forKey: "name") as? String == "Synthetic running history")
        }
    }

    @Test("Active preset edits and removals fail before any collection write") func rejectActivePresetChange() throws {
        let context = try context()
        for kind in [AIPresetKind.overrides, .tempTargets] {
            try AIAdditionalSettings.replacePresets(kind, with: [kind == .overrides ? override() : target()], expected: [], context: context)
            let request = NSFetchRequest<NSManagedObject>(entityName: kind.entity)
            let active = try #require(context.fetch(request).first)
            active.setValue(true, forKey: "enabled")
            try context.save()
            let current = try AIAdditionalSettings.presetValues(kind, context: context)
            var changed = current[0]
            changed["name"] = .string("Must not change")
            for rows in [[], [changed]] {
                #expect(throws: (any Error).self) {
                    try AIAdditionalSettings.replacePresets(kind, with: rows, expected: current, context: context)
                }
                #expect(try AIAdditionalSettings.presetValues(kind, context: context) == current)
                #expect(active.value(forKey: "enabled") as? Bool == true)
                #expect(!context.hasChanges)
            }
        }
    }

    @Test("A changed collection invalidates approval without overwriting the new data") func staleApproval() throws {
        let context = try context()
        try AIAdditionalSettings.replacePresets(.meals, with: [meal()], expected: [], context: context)
        let snapshot = try AIAdditionalSettings.presetValues(.meals, context: context)
        let row = try #require(context.fetch(MealPresetStored.fetchRequest()).first)
        row.carbs = 30
        try context.save()
        #expect(throws: (any Error).self) {
            try AIAdditionalSettings.replacePresets(.meals, with: [], expected: snapshot, context: context)
        }
        #expect(row.carbs == 30)
        #expect(!row.isDeleted)
    }

    @Test("A concurrent activation causes a merge conflict and rolls back the entire preset edit") func concurrentActivation() throws {
        let context = try context()
        context.mergePolicy = NSErrorMergePolicy
        try AIAdditionalSettings.replacePresets(.overrides, with: [override()], expected: [], context: context)
        let snapshot = try AIAdditionalSettings.presetValues(.overrides, context: context)
        let other = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        other.persistentStoreCoordinator = context.persistentStoreCoordinator
        let request = NSFetchRequest<NSManagedObject>(entityName: "OverrideStored")
        let active = try #require(other.fetch(request).first)
        active.setValue(true, forKey: "enabled")
        try other.save()
        var changed = snapshot[0]
        changed["name"] = .string("Stale edit")
        #expect(throws: (any Error).self) {
            try AIAdditionalSettings.replacePresets(.overrides, with: [changed, override()], expected: snapshot, context: context)
        }
        context.reset()
        let result = try context.fetch(request)
        #expect(result.count == 1)
        #expect(result[0].value(forKey: "enabled") as? Bool == true)
        #expect(result[0].value(forKey: "name") as? String == "Synthetic override")
    }
}
