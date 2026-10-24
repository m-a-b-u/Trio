import Foundation
import Testing
@testable import Trio

@Suite("AI settings catalog and proposal validation") struct ClaudeSettingsCatalogTests {
    @Test("Every encoded Trio setting and preference has a catalog entry") func encodedCoverage() throws {
        for (target, values) in [
            ("settings", try claudeDictionary(TrioSettings())),
            ("preferences", try claudeDictionary(Preferences())),
            ("pump_settings", try claudeDictionary(PumpSettings(insulinActionCurve: 10, maxBolus: 10, maxBasal: 2)))
        ] {
            let rows = claudeCatalogRows(target: target, values: values)
            #expect(Set(rows.compactMap { $0["key"] as? String }) == Set(values.keys))
            #expect(rows.allSatisfy { $0["type"] != nil && $0["current"] != nil && $0["constraints"] != nil })
            #expect(rows.filter { $0["access"] as? String == "action" }.count == (target == "settings" ? 1 : 0))
        }
    }

    @Test("Boolean values cannot be replaced by zero or one") func boolNumberSeparation() throws {
        let values = try claudeDictionary(TrioSettings())
        #expect(throws: (any Error).self) {
            try claudeValidateSettingPatch(["useAppleHealth": .number(1)], current: values, target: "settings")
        }
        #expect(!claudeValuesEqual(true, 1))
        #expect(!claudeValuesEqual(false, 0))
        try claudeValidateSettingPatch(["useAppleHealth": .bool(true)], current: values, target: "settings")
    }

    @Test("Encoded oref names use the native picker bounds") func encodedPickerBounds() throws {
        let values = try claudeDictionary(Preferences())
        #expect((claudeSettingConstraints(target: "preferences", key: "max_iob")["maximum"] as? NSNumber)?.intValue == 30)
        #expect((claudeSettingConstraints(target: "preferences", key: "SMBInterval")["minimum"] as? NSNumber)?.intValue == 1)
        #expect(throws: (any Error).self) {
            try claudeValidateSettingPatch(["max_iob": .number(31)], current: values, target: "preferences")
        }
        try claudeValidateSettingPatch(["max_iob": .number(5)], current: values, target: "preferences")
        #expect(throws: (any Error).self) {
            try claudeValidateSettingPatch(["smb_delivery_ratio": .number(0.51)], current: values, target: "preferences")
        }
        try claudeValidateSettingPatch(["updateInterval": .number(20)], current: values, target: "preferences")
        try claudeValidateSettingPatch(["updateInterval": .number(21)], current: values, target: "preferences")
    }

    @Test("Unknown fields, enum values and fractional ports are rejected") func invalidFields() throws {
        let values = try claudeDictionary(TrioSettings())
        for patch: [String: ClaudeJSONValue] in [
            ["unknown": .bool(true)], ["dosingMode": .string("unsafe")],
            ["localGlucosePort": .number(8080.5)], ["localGlucosePort": .number(65536)]
        ] {
            #expect(throws: (any Error).self) { try claudeValidateSettingPatch(patch, current: values, target: "settings") }
        }
    }

    @Test("Endpoint rules permit HTTPS and loopback HTTP only") func endpointRules() throws {
        for value in ["https://example.test/v1", "http://127.0.0.1:8080/v1", "http://[::1]:8080/v1"] {
            _ = try claudeValidateEndpoint(value)
        }
        for value in ["http://example.test/v1", "https://user:secret@example.test", "https://example.test?key=value", "https://example.test/#x"] {
            #expect(throws: (any Error).self) { try claudeValidateEndpoint(value) }
        }
        #expect(throws: (any Error).self) { try claudeValidateEndpoint("http://localhost:8080", allowLocalHTTP: false) }
    }

    @Test("Schedule parsing rejects malformed and out-of-day times") func scheduleTimes() throws {
        for entry: [String: ClaudeJSONValue] in [
            ["time": .string("00:00:30")], ["time": .string("00:00:00:00")],
            ["minutes": .number(1440)], ["minutes": .number(-30)], ["minutes": .number(0.5)],
            ["minutes": .number(.infinity)]
        ] {
            #expect(throws: (any Error).self) { try claudeParseSchedule([entry]) }
        }
        let items = try claudeParseSchedule([["time": .string("00:00:00")], ["time": .string("23:30")]])
        #expect(items.map(\.minutes) == [0, 1410])
    }

    @Test("Schedule values enforce the native range and precision") func scheduleValues() throws {
        for (target, valid, invalid) in [
            ("isf", 9.0, 8.0), ("carb_ratios", 1.1, 50.1), ("bg_targets", 72.0, 181.0),
            ("isf", 540.0, 10.5), ("carb_ratios", 50.0, 1.15), ("bg_targets", 180.0, 100.5)
        ] {
            try claudeValidateScheduleValue(valid, target: target)
            #expect(throws: (any Error).self) { try claudeValidateScheduleValue(invalid, target: target) }
        }
    }

    @Test("Glucose alerts preserve urgent-low safety and native sound choices") func glucoseAlertSafety() throws {
        let configuration = GlucoseAlertConfiguration()
        let valid = GlucoseAlertType.allCases.map { GlucoseAlert(type: $0) }
        try claudeValidateGlucoseAlerts(valid, configuration: configuration)
        var disabled = valid
        let urgent = try #require(disabled.firstIndex { $0.type == .urgentLow })
        disabled[urgent].isEnabled = false
        #expect(throws: (any Error).self) { try claudeValidateGlucoseAlerts(disabled, configuration: configuration) }
        var missingSound = valid
        missingSound[0].soundFilename = "missing.caf"
        #expect(throws: (any Error).self) { try claudeValidateGlucoseAlerts(missingSound, configuration: configuration) }
    }

    @Test("Glucose alerts cannot overlap or remove a complete type") func glucoseAlertCoverage() throws {
        let valid = GlucoseAlertType.allCases.map { GlucoseAlert(type: $0) }
        var duplicate = GlucoseAlert(type: .low)
        duplicate.activeOption = .night
        #expect(throws: (any Error).self) {
            try claudeValidateGlucoseAlerts(valid + [duplicate], configuration: GlucoseAlertConfiguration())
        }
        #expect(throws: (any Error).self) {
            try claudeValidateGlucoseAlerts(valid.filter { $0.type != .low }, configuration: GlucoseAlertConfiguration())
        }
    }

    @Test("Device alert tiers require a baseline and enabled critical alarms") func deviceAlertSafety() throws {
        let valid = DeviceAlertSeverity.allCases.map { DeviceAlertSeverityConfig(severity: $0) }
        try claudeValidateDeviceAlerts(valid)
        var disabled = valid
        let critical = try #require(disabled.firstIndex { $0.severity == .critical })
        disabled[critical].isEnabled = false
        #expect(throws: (any Error).self) { try claudeValidateDeviceAlerts(disabled) }
        #expect(throws: (any Error).self) { try claudeValidateDeviceAlerts(Array(valid.dropFirst())) }
    }

    @Test("Approval comparisons ignore display IDs but detect changed baselines") func staleApproval() {
        let shown = [ClaudeDiffLine(key: "max_iob", old: "3", new: "4", warning: nil)]
        let same = [ClaudeDiffLine(key: "max_iob", old: "3", new: "4", warning: nil)]
        let changed = [ClaudeDiffLine(key: "max_iob", old: "5", new: "4", warning: nil)]
        #expect(claudeChangesMatch(shown, same))
        #expect(!claudeChangesMatch(shown, changed))
        #expect(!claudeChangesMatch(shown, []))
    }

    @Test("Relay proposals decode optional old values without breaking existing proposals") func proposalCompatibility() throws {
        let minimal = Data(#"{"id":"test","target":"settings","patch":{"high":180}}"#.utf8)
        let proposal = try JSONDecoder().decode(ClaudeProposal.self, from: minimal)
        #expect(proposal.oldValues == nil)
        let relay = Data(#"{"id":"test","target":"relay_config","patch":{"model":"next"},"oldValues":{"model":"current"}}"#.utf8)
        let decoded = try JSONDecoder().decode(ClaudeProposal.self, from: relay)
        #expect(decoded.oldValues?["model"] == .string("current"))
    }
}
