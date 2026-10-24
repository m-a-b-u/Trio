import CoreData
import Foundation
import Swinject

/// Settings outside the JSON preference files. Preparing a proposal never writes to its stores.
enum AIAdditionalSettings {
    @MainActor static func catalogRows(resolver _: Resolver) -> [[String: Any]] {
        var rows = catalog(target: "diagnostics", values: diagnosticsValues())
        rows += catalog(target: "cgm_simulator", values: simulatorValues(defaults: .standard))
        let context = CoreDataStack.shared.newTaskContext()
        for kind in AIPresetKind.allCases {
            do {
                let values = try context.performAndWait { try presetValues(kind, context: context) }
                rows += catalog(target: kind.rawValue, values: ["presets": .array(values.map(ClaudeJSONValue.object))])
            } catch {
                rows.append(["target": kind.rawValue, "key": "presets", "type": "array", "current": [],
                             "access": "readOnly", "constraints": [:], "reason": "Vorlagen konnten nicht geladen werden."])
            }
        }
        return rows
    }

    @MainActor static func prepare(_ proposal: ClaudeProposal, resolver: Resolver) throws -> ClaudePreparedChange? {
        switch proposal.target {
        case "diagnostics":
            let current = diagnosticsValues()
            let next = try validatePatch(proposal.patch, current: current, target: proposal.target)
            guard let raw = next["sharingOption"]?.stringValue, let option = DiagnosticsSharingOption(rawValue: raw) else {
                throw invalid("sharingOption")
            }
            return prepared(proposal, title: "Diagnosedaten teilen", current: current, next: next) {
                try unchanged(current, diagnosticsValues())
                let flags = PropertyPersistentFlags.shared
                let wasTelemetryOn = flags.telemetrySharingEnabled != false
                flags.crashlyticsSharingEnabled = option.crashlyticsEnabled
                flags.telemetrySharingEnabled = option.telemetryEnabled
                CrashReportingGate.setEnabled(option.crashlyticsEnabled)
                if option.telemetryEnabled, !wasTelemetryOn {
                    TelemetryClient.shared.scheduleRecurring()
                    Task.detached { await TelemetryClient.shared.maybeSend(reason: .optIn) }
                }
            }
        case "cgm_simulator":
            let current = simulatorValues(defaults: .standard)
            let next = try validatePatch(proposal.patch, current: current, target: proposal.target)
            return prepared(proposal, title: "CGM-Simulator", current: current, next: next) {
                try unchanged(current, simulatorValues(defaults: .standard))
                for (key, value) in next where value != current[key] {
                    UserDefaults.standard.set(value.anyValue, forKey: simulatorKeys[key]!)
                }
                if next["simulatedScenario"] != current["simulatedScenario"],
                   let raw = next["simulatedScenario"]?.stringValue,
                   let scenario = SimulatedSensorScenario(rawValue: raw),
                   let source = resolver.resolve(FetchGlucoseManager.self)?.glucoseSource as? GlucoseSimulatorSource
                {
                    source.applySimulatedScenario(scenario)
                }
            }
        default:
            guard let kind = AIPresetKind(rawValue: proposal.target) else { return nil }
            let context = CoreDataStack.shared.newTaskContext()
            context.mergePolicy = NSErrorMergePolicy
            let autosensMax = resolver.resolve(SettingsManager.self)?.preferences.autosensMax
            let current = try context.performAndWait { try presetValues(kind, context: context) }
            let next = try validatePresets(proposal.patch, kind: kind, current: current, autosensMax: autosensMax)
            let oldValues: [String: ClaudeJSONValue] = ["presets": .array(current.map(ClaudeJSONValue.object))]
            let newValues: [String: ClaudeJSONValue] = ["presets": .array(next.map(ClaudeJSONValue.object))]
            return prepared(proposal, title: kind.title, current: oldValues, next: newValues) {
                try await context.perform {
                    context.reset()
                    try replacePresets(kind, with: next, expected: current, context: context, autosensMax: autosensMax)
                }
                if kind == .overrides {
                    // Local save is complete even if the separately retried Nightscout upload fails.
                    try? await resolver.resolve(NightscoutManager.self)?.uploadProfiles()
                }
            }
        }
    }

    private static func invalid(_ key: String) -> ClaudeBridgeError {
        .invalidSetting("Ungültige Einstellung: \(key)")
    }

    private static func unchanged(_ expected: [String: ClaudeJSONValue], _ actual: [String: ClaudeJSONValue]) throws {
        guard expected == actual else {
            throw ClaudeBridgeError.invalidSetting("Einstellungen wurden inzwischen geändert. Vorschlag erneut laden.")
        }
    }

    private static func prepared(
        _ proposal: ClaudeProposal, title: String, current: [String: ClaudeJSONValue], next: [String: ClaudeJSONValue],
        commit: @escaping () async throws -> Void
    ) -> ClaudePreparedChange {
        let lines = next.keys.sorted().compactMap { key -> ClaudeDiffLine? in
            guard next[key] != current[key] else { return nil }
            return ClaudeDiffLine(key: key, old: claudeJSONString(current[key]?.anyValue),
                                  new: claudeJSONString(next[key]?.anyValue), warning: nil)
        }
        return ClaudePreparedChange(proposal: proposal, title: title, lines: lines, commit: commit)
    }

    private static func diagnosticsValues() -> [String: ClaudeJSONValue] {
        let flags = PropertyPersistentFlags.shared
        let option = DiagnosticsSharingOption(crashlyticsEnabled: flags.crashlyticsSharingEnabled ?? true,
                                              telemetryEnabled: flags.telemetrySharingEnabled ?? true)
        return ["sharingOption": .string(option.rawValue)]
    }

    static let simulatorKeys = [
        "centerValue": "GlucoseSimulator_CenterValue", "amplitude": "GlucoseSimulator_Amplitude",
        "period": "GlucoseSimulator_Period", "noiseAmplitude": "GlucoseSimulator_NoiseAmplitude",
        "produceStaleValues": "GlucoseSimulator_ProduceStaleValues", "simulatedScenario": "GlucoseSimulator.simulatedScenario"
    ]

    static func simulatorValues(defaults: UserDefaults) -> [String: ClaudeJSONValue] {
        let fallback = ["centerValue": OscillatingGenerator.Defaults.centerValue,
                        "amplitude": OscillatingGenerator.Defaults.amplitude,
                        "period": OscillatingGenerator.Defaults.period,
                        "noiseAmplitude": OscillatingGenerator.Defaults.noiseAmplitude]
        var values = fallback.mapValues(ClaudeJSONValue.number)
        for key in fallback.keys {
            if defaults.object(forKey: simulatorKeys[key]!) != nil {
                values[key] = .number(defaults.double(forKey: simulatorKeys[key]!))
            }
        }
        values["produceStaleValues"] = .bool(defaults.bool(forKey: simulatorKeys["produceStaleValues"]!))
        let raw = defaults.string(forKey: simulatorKeys["simulatedScenario"]!)
        values["simulatedScenario"] = .string(raw.flatMap(SimulatedSensorScenario.init(rawValue:))?.rawValue ?? "runningNormally")
        return values
    }

    static func constraints(target: String, key: String) -> [String: Any] {
        if target == "diagnostics", key == "sharingOption" { return ["enum": DiagnosticsSharingOption.allCases.map(\.rawValue)] }
        if target == "cgm_simulator" {
            switch key {
            case "centerValue": return ["minimum": 80, "maximum": 200, "step": 1]
            case "amplitude": return ["minimum": 10, "maximum": 100, "step": 5]
            case "period": return ["minimum": 3600, "maximum": 21600, "step": 1800]
            case "noiseAmplitude": return ["minimum": 0, "maximum": 20, "step": 1]
            case "simulatedScenario": return ["enum": SimulatedSensorScenario.allCases.map(\.rawValue)]
            default: return [:]
            }
        }
        if let kind = AIPresetKind(rawValue: target), key == "presets" {
            return ["maxItems": Int(Int16.max), "itemFields": kind.fields,
                    "description": "Vollständige Vorlagenliste; vorhandene id unverändert übernehmen, neue id als UUID. Aktive Vorlagen dürfen nicht geändert oder entfernt werden. Glukosewerte in mg/dL, Dauer in Minuten."]
        }
        return [:]
    }

    private static func catalog(target: String, values: [String: ClaudeJSONValue]) -> [[String: Any]] {
        values.keys.sorted().map { key in
            ["target": target, "key": key, "type": claudeSettingType(values[key]!.anyValue),
             "current": values[key]!.anyValue, "access": "proposal", "constraints": constraints(target: target, key: key)]
        }
    }

    static func validatePatch(
        _ patch: [String: ClaudeJSONValue]?, current: [String: ClaudeJSONValue], target: String
    ) throws -> [String: ClaudeJSONValue] {
        guard let patch, !patch.isEmpty else { throw ClaudeBridgeError.emptyPatch }
        for (key, value) in patch {
            guard let old = current[key], claudeSettingType(old.anyValue) == claudeSettingType(value.anyValue) else {
                throw invalid(key)
            }
            let rules = constraints(target: target, key: key)
            if let options = rules["enum"] as? [String], !options.contains(value.stringValue ?? "") { throw invalid(key) }
            if case let .number(number) = value {
                guard number.isFinite else { throw invalid(key) }
                let min = (rules["minimum"] as? NSNumber)?.doubleValue ?? -.infinity
                let max = (rules["maximum"] as? NSNumber)?.doubleValue ?? .infinity
                guard min ... max ~= number else { throw invalid(key) }
                if let step = (rules["step"] as? NSNumber)?.doubleValue {
                    let count = (number - min) / step
                    guard abs(count - count.rounded()) < 0.000001 else { throw invalid(key) }
                }
            }
        }
        return current.merging(patch) { _, new in new }
    }

    static func presetValues(_ kind: AIPresetKind, context: NSManagedObjectContext) throws -> [[String: ClaudeJSONValue]] {
        try fetchPresets(kind, context: context).map { row in
            var values: [String: ClaudeJSONValue] = ["id": .string(row.objectID.uriRepresentation().absoluteString)]
            for (key, type) in kind.fields where key != "id" {
                let value = row.value(forKey: key)
                switch type {
                case "string": values[key] = .string(value as? String ?? "")
                case "boolean": values[key] = .bool((value as? NSNumber)?.boolValue ?? false)
                case "nullableNumber": values[key] = (value as? NSNumber).map { .number($0.doubleValue) } ?? .null
                default: values[key] = .number((value as? NSNumber)?.doubleValue ?? 0)
                }
            }
            return values
        }
    }

    private static func fetchPresets(_ kind: AIPresetKind, context: NSManagedObjectContext) throws -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: kind.entity)
        if kind != .meals { request.predicate = NSPredicate(format: "isPreset == YES") }
        request.sortDescriptors = kind == .meals ? [NSSortDescriptor(key: "dish", ascending: true)] :
            [NSSortDescriptor(key: "orderPosition", ascending: true)]
        // A tie-breaker keeps the approval snapshot stable when native rows share a sort value.
        return try context.fetch(request).sorted { left, right in
            let lhs = kind == .meals ? (left.value(forKey: "dish") as? String ?? "") :
                String(format: "%05d", (left.value(forKey: "orderPosition") as? NSNumber)?.intValue ?? 0)
            let rhs = kind == .meals ? (right.value(forKey: "dish") as? String ?? "") :
                String(format: "%05d", (right.value(forKey: "orderPosition") as? NSNumber)?.intValue ?? 0)
            return lhs == rhs ? left.objectID.uriRepresentation().absoluteString < right.objectID.uriRepresentation().absoluteString : lhs < rhs
        }
    }

    static func validatePresets(
        _ patch: [String: ClaudeJSONValue]?, kind: AIPresetKind, current: [[String: ClaudeJSONValue]], autosensMax: Decimal? = nil
    ) throws -> [[String: ClaudeJSONValue]] {
        guard let patch, Set(patch.keys) == ["presets"], case let .array(array) = patch["presets"],
              array.count <= Int(Int16.max) else { throw invalid("presets") }
        let existingIDs = Set(current.compactMap { $0["id"]?.stringValue })
        var seen = Set<String>()
        let validated = try array.map { item in
            guard case let .object(row) = item, Set(row.keys) == Set(kind.fields.keys),
                  let id = row["id"]?.stringValue, seen.insert(id).inserted,
                  existingIDs.contains(id) || UUID(uuidString: id) != nil else { throw invalid("presets.id") }
            for (key, type) in kind.fields {
                let value = row[key]!
                switch (type, value) {
                case ("string", .string), ("boolean", .bool), ("nullableNumber", .null): break
                case let ("number", .number(number)), let ("nullableNumber", .number(number)):
                    guard number.isFinite, NSDecimalNumber(string: String(number)) != .notANumber else { throw invalid(key) }
                default: throw invalid(key)
                }
            }
            // Unchanged legacy entries can be retained even if older UI versions allowed other limits.
            if current.contains(row) { return row }
            let previous = current.first { $0["id"] == row["id"] }
            let nameKey = kind == .meals ? "dish" : "name"
            guard let name = row[nameKey]?.stringValue, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw invalid(nameKey)
            }
            func number(_ key: String, _ range: ClosedRange<Double>, step: Double? = nil, nullable: Bool = false) throws {
                if nullable, row[key] == .null { return }
                guard case let .number(value) = row[key], range.contains(value) else { throw invalid(key) }
                if let step, previous?[key] != row[key], abs(value / step - (value / step).rounded()) > 0.000001 { throw invalid(key) }
            }
            switch kind {
            case .meals:
                guard name.count <= 25 else { throw invalid("dish") }
                for key in ["carbs", "fat", "protein"] { try number(key, 0 ... 999, step: 1) }
                guard ["carbs", "fat", "protein"].contains(where: { (row[$0]?.doubleValue ?? 0) > 0 }) else {
                    throw invalid("Nährwerte")
                }
            case .tempTargets:
                try number("target", 80 ... 200, step: 1)
                try number("duration", 5 ... 1435, step: 5)
                if case let .number(halfBasalTarget) = row["halfBasalTarget"],
                   previous?["halfBasalTarget"] != row["halfBasalTarget"] || previous?["target"] != row["target"]
                {
                    guard let target = row["target"]?.doubleValue,
                          validHalfBasalTarget(halfBasalTarget, target: target, autosensMax: autosensMax)
                    else { throw invalid("halfBasalTarget außerhalb der nativen Empfindlichkeitsauswahl") }
                }
            case .overrides:
                try number("percentage", 40 ... 150, step: 1)
                try number("duration", row["indefinite"] == .bool(true) ? 0 ... 1435 : 5 ... 1435, step: 5)
                if row["target"] != .null, row["target"] != .number(0) { try number("target", 72 ... 270, step: 1) }
                for key in ["start", "end"] { try number(key, 0 ... 23, step: 1, nullable: row["smbIsScheduledOff"] != .bool(true)) }
                for key in ["smbMinutes", "uamMinutes"] {
                    try number(key, 0 ... 180, step: 5, nullable: row["advancedSettings"] != .bool(true))
                }
                for group in [["isfAndCr", "isf", "cr"], ["smbIsOff", "smbIsScheduledOff"]] {
                    if group.contains(where: { previous?[$0] != row[$0] }), group.filter({ row[$0] == .bool(true) }).count > 1 {
                        throw invalid(group.joined(separator: "/"))
                    }
                }
                guard row["percentage"] != .number(100) || (row["target"] != .null && row["target"] != .number(0)) ||
                    row["advancedSettings"] == .bool(true) || row["smbIsOff"] == .bool(true) || row["smbIsScheduledOff"] == .bool(true)
                else { throw invalid("Override ohne Änderung") }
            }
            return row
        }
        // Meal presets have no order column; the native view always sorts them by dish.
        return kind == .meals ? validated.sorted {
            let left = $0["dish"]?.stringValue ?? ""
            let right = $1["dish"]?.stringValue ?? ""
            return left == right ? ($0["id"]?.stringValue ?? "") < ($1["id"]?.stringValue ?? "") : left < right
        } : validated
    }

    static func validHalfBasalTarget(_ value: Double, target: Double, autosensMax: Decimal?) -> Bool {
        guard value.isFinite, value > 100 else { return false }
        if target == 100 { return value == 160 }
        let low: Double = target < 100 ? 105 : TempTargetCalculations.minSensitivityRatioTT
        let high: Double
        if target < 100 {
            guard let autosensMax else { return false }
            high = NSDecimalNumber(decimal: autosensMax * 100).doubleValue
        } else { high = 95 }
        let nativeMax = NSDecimalNumber(decimal: DecimalPickerSettings().autosensMax.max * 100).doubleValue
        guard high.isFinite, high >= low, high <= nativeMax else { return false }
        return stride(from: low, through: high, by: 5).contains {
            TempTargetCalculations.computeHalfBasalTarget(target: Decimal(target), percentage: $0) == value
        }
    }

    /// Called on the supplied isolated context queue; one save makes the complete collection atomic.
    static func replacePresets(
        _ kind: AIPresetKind, with next: [[String: ClaudeJSONValue]], expected: [[String: ClaudeJSONValue]],
        context: NSManagedObjectContext, autosensMax: Decimal? = nil
    ) throws {
        let actual = try presetValues(kind, context: context)
        guard actual == expected else { throw invalid("Vorlagen wurden inzwischen geändert; Vorschlag erneut laden") }
        _ = try validatePresets(["presets": .array(next.map(ClaudeJSONValue.object))], kind: kind, current: actual, autosensMax: autosensMax)
        let rows = try fetchPresets(kind, context: context)
        let existing = Dictionary(uniqueKeysWithValues: rows.map { ($0.objectID.uriRepresentation().absoluteString, $0) })
        let proposed = Dictionary(uniqueKeysWithValues: next.map { ($0["id"]!.stringValue!, $0) })
        if kind != .meals {
            for (index, row) in rows.enumerated() where (row.value(forKey: "enabled") as? NSNumber)?.boolValue == true {
                guard proposed[actual[index]["id"]!.stringValue!] == actual[index],
                      next.firstIndex(where: { $0["id"] == actual[index]["id"] }) == index else {
                    throw invalid("Aktive Vorlage zuerst in Trio beenden")
                }
            }
        }
        do {
            for row in rows where proposed[row.objectID.uriRepresentation().absoluteString] == nil { context.delete(row) }
            for (index, values) in next.enumerated() {
                let id = values["id"]!.stringValue!
                let row = existing[id] ?? NSEntityDescription.insertNewObject(forEntityName: kind.entity, into: context)
                if kind != .meals, (row.value(forKey: "enabled") as? NSNumber)?.boolValue == true { continue }
                if actual.contains(values), kind == .meals || (row.value(forKey: "orderPosition") as? NSNumber)?.intValue == index + 1 {
                    continue
                }
                for (key, value) in values where key != "id" {
                    switch value {
                    case let .number(number): row.setValue(key == "percentage" ? NSNumber(value: number) : NSDecimalNumber(string: String(number)), forKey: key)
                    case .null: row.setValue(nil, forKey: key)
                    default: row.setValue(value.anyValue, forKey: key)
                    }
                }
                if kind != .meals {
                    row.setValue(true, forKey: "isPreset")
                    row.setValue(false, forKey: "enabled")
                    row.setValue(false, forKey: "isUploadedToNS")
                    row.setValue(Int16(index + 1), forKey: "orderPosition")
                    if existing[id] == nil {
                        row.setValue(Date(), forKey: "date")
                        row.setValue(kind == .overrides ? id as Any : UUID(uuidString: id)! as Any, forKey: "id")
                        if kind == .tempTargets { row.setValue(TempTarget.local, forKey: "enteredBy") }
                    }
                }
            }
            if context.hasChanges { try context.save() }
        } catch {
            context.rollback()
            throw error
        }
    }
}

enum AIPresetKind: String, CaseIterable {
    case overrides = "override_presets", tempTargets = "temp_target_presets", meals = "meal_presets"

    var entity: String {
        switch self {
        case .overrides: return "OverrideStored"
        case .tempTargets: return "TempTargetStored"
        case .meals: return "MealPresetStored"
        }
    }

    var title: String {
        switch self {
        case .overrides: return "Override-Vorlagen"
        case .tempTargets: return "Temporäre Zielwert-Vorlagen"
        case .meals: return "Mahlzeiten-Vorlagen"
        }
    }

    var fields: [String: String] {
        switch self {
        case .overrides:
            return ["id": "string", "name": "string", "duration": "number", "indefinite": "boolean", "percentage": "number",
                    "target": "nullableNumber", "advancedSettings": "boolean", "smbIsOff": "boolean", "smbIsScheduledOff": "boolean",
                    "start": "nullableNumber", "end": "nullableNumber", "isfAndCr": "boolean", "isf": "boolean", "cr": "boolean",
                    "smbMinutes": "nullableNumber", "uamMinutes": "nullableNumber"]
        case .tempTargets:
            return ["id": "string", "name": "string", "target": "number", "duration": "number", "halfBasalTarget": "nullableNumber"]
        case .meals:
            return ["id": "string", "dish": "string", "carbs": "number", "fat": "number", "protein": "number"]
        }
    }
}
