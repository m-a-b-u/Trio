import Combine
import CoreData
import Foundation
import LocalAuthentication
import LoopKit
import Security
import SwiftUI
import Swinject
import UserNotifications

// MARK: - Claude Bridge
//
// Connects Trio to a small relay server ("trio-mcp") that exposes Trio to Claude via MCP.
// - Trio pushes a read-only snapshot of its settings and status to the relay.
// - Claude can only create *proposals* on the relay.
// - Every proposal must be reviewed and approved on this iPhone (Face ID / passcode) before
//   anything is changed. Rejected or failed proposals are reported back to the relay.

// MARK: - Generic JSON value

enum ClaudeJSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: ClaudeJSONValue])
    case array([ClaudeJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ClaudeJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: ClaudeJSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var anyValue: Any {
        switch self {
        case let .string(value): return value
        case let .number(value): return value
        case let .bool(value): return value
        case let .object(value): return value.mapValues { $0.anyValue }
        case let .array(value): return value.map(\.anyValue)
        case .null: return NSNull()
        }
    }

    var doubleValue: Double? {
        switch self {
        case let .number(value): return value
        case let .string(value): return Double(value.replacingOccurrences(of: ",", with: "."))
        default: return nil
        }
    }

    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }
}

// MARK: - Models

struct ClaudeProposal: Codable, Identifiable, Equatable {
    let id: String
    let createdAt: String?
    /// "settings" | "preferences" | "basal_profile" | "isf" | "carb_ratios" | "bg_targets"
    let target: String
    let patch: [String: ClaudeJSONValue]?
    let schedule: [[String: ClaudeJSONValue]]?
    let reason: String?
    let status: String?
    var oldValues: [String: ClaudeJSONValue]? = nil
}

struct ClaudeDiffLine: Identifiable, Equatable {
    let id = UUID()
    let key: String
    let old: String
    let new: String
    let warning: String?
}

struct ClaudePreparedChange {
    let proposal: ClaudeProposal
    let title: String
    let lines: [ClaudeDiffLine]
    let commit: () async throws -> Void
}

enum ClaudeBridgeError: LocalizedError {
    case notConfigured
    case badURL
    case http(Int, String)
    case unknownTarget(String)
    case emptyPatch
    case notApplied(String)
    case invalidSchedule(String)
    case noPump
    case unsupportedBasalRate(Double)
    case authenticationFailed
    case invalidSetting(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "KI-Bridge ist nicht konfiguriert (URL/Token fehlen)."
        case .badURL: return "Ungültige Server-URL."
        case let .http(code, body): return "Server-Fehler \(code): \(body.prefix(200))"
        case let .unknownTarget(target): return "Unbekanntes Ziel: \(target)"
        case .emptyPatch: return "Der Vorschlag enthält keine Änderungen."
        case let .notApplied(key): return "„\(key)“ ist kein gültiger Einstellungsschlüssel oder der Wert ist ungültig."
        case let .invalidSchedule(message): return "Ungültiger Zeitplan: \(message)"
        case .noPump: return "Keine Pumpe verbunden – Basalrate kann nicht übertragen werden."
        case let .unsupportedBasalRate(rate): return "Basalrate \(rate) U/h wird von der Pumpe nicht unterstützt."
        case .authenticationFailed: return "Authentifizierung fehlgeschlagen."
        case let .invalidSetting(message): return "Ungültige Einstellung: \(message)"
        }
    }
}

// MARK: - Config (URL in UserDefaults, token in Keychain)

enum ClaudeBridgeConfig {
    private static let urlKey = "claude.bridge.url"
    private static let enabledKey = "claude.bridge.enabled"
    private static let service = "org.nightscout.trio.claude.bridge"
    private static let account = "bridge_token"

    static var baseURL: String {
        get { UserDefaults.standard.string(forKey: urlKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: urlKey) }
    }

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var token: String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    @discardableResult static func setToken(_ value: String?) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            let status = SecItemDelete(base as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static var isConfigured: Bool { !baseURL.isEmpty && token != nil }
}

// MARK: - Helpers

func claudeJSONString(_ value: Any?) -> String {
    guard let value, !(value is NSNull) else { return "–" }
    if let data = try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys]),
       var string = String(data: data, encoding: .utf8), string.count >= 2
    {
        string.removeFirst()
        string.removeLast()
        return string
    }
    return "\(value)"
}

func claudeValuesEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
    if let left = lhs as? NSNumber, let right = rhs as? NSNumber {
        guard (CFGetTypeID(left) == CFBooleanGetTypeID()) == (CFGetTypeID(right) == CFBooleanGetTypeID()) else { return false }
        return abs(left.doubleValue - right.doubleValue) < 1e-9
    }
    return claudeJSONString(lhs) == claudeJSONString(rhs)
}

func claudeDictionary<T: Encodable>(_ value: T) throws -> [String: Any] {
    let data = try JSONCoding.encoder.encode(value)
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

func claudeJSONObject<T: Encodable>(_ value: T) -> Any {
    guard let data = try? JSONCoding.encoder.encode(value),
          let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    else { return NSNull() }
    return object
}

func claudeChangesMatch(_ preview: [ClaudeDiffLine], _ current: [ClaudeDiffLine]) -> Bool {
    preview.count == current.count && zip(preview, current).allSatisfy {
        $0.key == $1.key && $0.old == $1.old && $0.new == $1.new
    }
}

// The catalog and proposal validator use the same constraints as the native pickers.
func claudeSettingConstraints(target: String, key: String) -> [String: Any] {
    let aliases = [
        "max_iob": "maxIOB", "max_daily_safety_multiplier": "maxDailySafetyMultiplier",
        "current_basal_safety_multiplier": "currentBasalSafetyMultiplier", "autosens_max": "autosensMax",
        "autosens_min": "autosensMin", "smb_delivery_ratio": "smbDeliveryRatio",
        "half_basal_exercise_target": "halfBasalExerciseTarget", "min_5m_carbimpact": "min5mCarbimpact",
        "SMBInterval": "smbInterval", "bolus_increment": "bolusIncrement",
        "maxDelta_bg_threshold": "maxDeltaBGthreshold", "insulin_action_curve": "dia"
    ]
    let pickerKey = aliases[key] ?? key
    if ["settings", "preferences", "pump_settings"].contains(target),
       let picker = Mirror(reflecting: DecimalPickerSettings()).children
        .first(where: { $0.label == pickerKey })?.value as? PickerSetting
    {
        return ["minimum": NSDecimalNumber(decimal: picker.min), "maximum": NSDecimalNumber(decimal: picker.max),
                "step": NSDecimalNumber(decimal: picker.step)]
    }
    if target == "settings" {
        switch key {
        case "localGlucosePort": return ["minimum": 1, "maximum": 65535, "integer": true]
        case "insulinConcentration": return ["exclusiveMinimum": 0, "note": "Legacy stored value; unused by current UI/algorithm"]
        case "units": return ["enum": GlucoseUnits.allCases.map(\.rawValue)]
        case "dosingMode": return ["enum": DosingMode.userSelectable.map(\.rawValue), "requires": "configured CGM and pump"]
        case "cgm": return ["enum": CGMType.allCases.map(\.rawValue)]
        case "eA1cDisplayUnit": return ["enum": EstimatedA1cDisplayUnit.allCases.map(\.rawValue)]
        case "glucoseColorScheme": return ["enum": GlucoseColorScheme.allCases.map(\.rawValue)]
        case "bolusDisplayThreshold": return ["enum": BolusDisplayThreshold.allCases.map { NSDecimalNumber(decimal: $0.rawValue) }]
        case "forecastDisplayType": return ["enum": ForecastDisplayType.allCases.map(\.rawValue)]
        case "lockScreenView", "smartStackView": return ["enum": LockScreenView.allCases.map(\.rawValue)]
        case "bolusShortcut": return ["enum": BolusShortcutLimit.allCases.map(\.rawValue)]
        case "timeInRangeType": return ["enum": TimeInRangeType.allCases.map(\.rawValue)]
        case "homeStatsPanelFace": return ["enum": HomeStatsPanelFace.allCases.map(\.rawValue)]
        case "garminWatchface": return ["enum": GarminWatchface.allCases.map(\.rawValue)]
        case "garminDatafield": return ["enum": GarminDatafield.allCases.map(\.rawValue)]
        case "primaryAttributeChoice": return ["enum": GarminPrimaryAttributeChoice.allCases.map(\.rawValue)]
        case "secondaryAttributeChoice": return ["enum": GarminSecondaryAttributeChoice.allCases.map(\.rawValue)]
        default: break
        }
    }
    if target == "glucose_alerts", key == "configuration" {
        return ["properties": ["dayStart": ["hour": "integer 0...23", "minute": "integer 0...59"],
                               "nightStart": ["hour": "integer 0...23", "minute": "integer 0...59"],
                               "forceTrioAlertsWhenCGMProvidesOwn": ["type": "boolean"]]]
    }
    if target == "glucose_alerts", key == "alerts" {
        return ["items": ["id": "UUID", "type": GlucoseAlertType.allCases.map(\.rawValue), "name": "nonempty string",
                          "isEnabled": "boolean; urgentLow must remain true", "thresholdMgDL": "urgentLow 54...80; low/forecastedLow 54...100; high 100...400; carbsRequired 5...50 grams",
                          "soundFilename": AlarmSoundCatalog.allFilenames, "playsSound": "boolean", "overridesSilenceAndDND": "boolean",
                          "activeOption": ["always", "day", "night"], "snoozedUntil": "runtime state; preserve existing value"],
                "collection": "At least one alert per type; unique IDs and nonoverlapping activeOption per type."]
    }
    if target == "device_alerts", key == "configs" {
        return ["items": ["id": "UUID", "severity": DeviceAlertSeverity.allCases.map(\.rawValue),
                          "isEnabled": "boolean; critical must remain true", "soundFilename": AlarmSoundCatalog.allFilenames,
                          "playsSound": "boolean", "overridesSilenceAndDND": "boolean", "activeOption": ["always", "day", "night"]],
                "collection": "Each severity requires an always baseline; unique IDs and activeOption per severity."]
    }
    if target == "app_preferences", key == "liveActivityOrder" {
        return ["length": 4, "items": ["", "currentGlucoseLarge", "currentGlucose", "iob", "cob", "updatedLabel", "totalDailyDose"]]
    }
    if target == "preferences", key == "curve" { return ["enum": InsulinCurve.allCases.map(\.rawValue)] }
    if target == "app_preferences", key == "colorSchemePreference" { return ["enum": ColorSchemeOption.allCases.map(\.rawValue)] }
    if target == "ai_meal", key == "provider" {
        return ["enum": AIMealProvider.allCases.map(\.rawValue)]
    }
    if target == "relay_config", key == "provider" {
        return ["enum": ["anthropic", "openai", "openai-compatible"]]
    }
    return [:]
}

func claudeSettingType(_ value: Any) -> String {
    if let number = value as? NSNumber { return CFGetTypeID(number) == CFBooleanGetTypeID() ? "boolean" : "number" }
    if value is String { return "string" }
    if value is [Any] { return "array" }
    if value is [String: Any] { return "object" }
    return "null"
}

func claudeValidateSettingPatch(_ patch: [String: ClaudeJSONValue], current: [String: Any], target: String) throws {
    guard !patch.isEmpty else { throw ClaudeBridgeError.emptyPatch }
    for (key, proposed) in patch {
        guard let old = current[key], claudeSettingType(old) == claudeSettingType(proposed.anyValue) else {
            throw ClaudeBridgeError.notApplied(key)
        }
        let rules = claudeSettingConstraints(target: target, key: key)
        if let allowed = rules["enum"] as? [Any], !allowed.contains(where: { claudeValuesEqual($0, proposed.anyValue) }) {
            throw ClaudeBridgeError.notApplied(key)
        }
        if let number = proposed.doubleValue, claudeSettingType(proposed.anyValue) == "number" {
            guard number.isFinite else { throw ClaudeBridgeError.notApplied(key) }
            if let min = rules["minimum"] as? NSNumber, number < min.doubleValue { throw ClaudeBridgeError.notApplied(key) }
            if let max = rules["maximum"] as? NSNumber, number > max.doubleValue { throw ClaudeBridgeError.notApplied(key) }
            if let min = rules["exclusiveMinimum"] as? NSNumber, number <= min.doubleValue { throw ClaudeBridgeError.notApplied(key) }
            if rules["integer"] as? Bool == true, number.rounded() != number { throw ClaudeBridgeError.notApplied(key) }
            if let step = rules["step"] as? NSNumber, !claudeValuesEqual(old, proposed.anyValue) {
                let origin = (rules["minimum"] as? NSNumber)?.doubleValue ?? 0
                let count = (number - origin) / step.doubleValue
                guard step.doubleValue > 0, abs(count - count.rounded()) < 0.000001 else {
                    throw ClaudeBridgeError.notApplied(key)
                }
            }
        }
    }
}

func claudeCatalogRows(target: String, values: [String: Any]) -> [[String: Any]] {
    values.keys.sorted().map { key in
        var row: [String: Any] = ["target": target, "key": key, "type": claudeSettingType(values[key]!),
                                 "current": values[key]!, "access": "proposal",
                                 "constraints": claudeSettingConstraints(target: target, key: key)]
        if target == "settings", key == "cgmPluginIdentifier" {
            row["access"] = "action"
            row["reason"] = "CGM plugin identity is assigned by the native pairing/onboarding flow."
        }
        return row
    }
}

private struct ClaudeGlucoseAlertSettings: Codable {
    var configuration: GlucoseAlertConfiguration
    var alerts: [GlucoseAlert]
}

private struct ClaudeDeviceAlertSettings: Codable {
    var configs: [DeviceAlertSeverityConfig]
}

private struct ClaudeAppPreferences: Codable {
    var colorSchemePreference: ColorSchemeOption
    var calendarID: String
    var liveActivityOrder: [String]
    var isTrioRemoteControlEnabled: Bool
}

struct ClaudeAIMealPreferences: Codable, Equatable {
    var provider: String
    var anthropicModel: String
    var openAIModel: String
    var openAICompatibleModel: String
    var customBaseURL: String
}

func claudeAIMealCatalogRows(_ preferences: ClaudeAIMealPreferences) throws -> [[String: Any]] {
    // Keep inactive fields writable so one proposal can select and configure a cloud provider.
    let cloudProviders = ["anthropicModel": "Anthropic", "openAIModel": "OpenAI",
                          "openAICompatibleModel": "OpenAI-kompatibel", "customBaseURL": "OpenAI-kompatibel"]
    return try claudeCatalogRows(target: "ai_meal", values: claudeDictionary(preferences)).map { row in
        guard let key = row["key"] as? String, let provider = cloudProviders[key] else { return row }
        var annotated = row
        var constraints = row["constraints"] as? [String: Any] ?? [:]
        constraints["note"] = "Gespeicherte Konfiguration für \(provider). Apple Intelligence verwendet dieses Feld nicht."
        annotated["constraints"] = constraints
        return annotated
    }
}

func claudeValidateAIMealPreferences(
    _ proposed: ClaudeAIMealPreferences,
    current: ClaudeAIMealPreferences
) throws -> AIMealProvider {
    guard let provider = AIMealProvider(rawValue: proposed.provider) else { throw ClaudeBridgeError.notApplied("provider") }
    for (new, old) in [(proposed.anthropicModel, current.anthropicModel),
                       (proposed.openAIModel, current.openAIModel),
                       (proposed.openAICompatibleModel, current.openAICompatibleModel),
                       (proposed.customBaseURL, current.customBaseURL)] where new != old {
        guard new == new.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw ClaudeBridgeError.invalidSetting("Modell-IDs/URL ohne äußere Leerzeichen erforderlich")
        }
    }
    if proposed.anthropicModel != current.anthropicModel, proposed.anthropicModel.isEmpty {
        throw ClaudeBridgeError.invalidSetting("Anthropic-Modell darf nicht leer sein")
    }
    let selectedModel: String?
    switch provider {
    case .appleIntelligence: selectedModel = nil
    case .anthropic: selectedModel = proposed.anthropicModel
    case .openAI: selectedModel = proposed.openAIModel
    case .openAICompatible: selectedModel = proposed.openAICompatibleModel
    }
    if let selectedModel {
        guard !selectedModel.isEmpty, selectedModel == selectedModel.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw ClaudeBridgeError.invalidSetting("Modell-ID erforderlich, ohne äußere Leerzeichen")
        }
    }
    if provider == .openAICompatible || (proposed.customBaseURL != current.customBaseURL && !proposed.customBaseURL.isEmpty) {
        _ = try AIMealConfiguration.normalizedBaseURL(proposed.customBaseURL)
    }
    return provider
}

private struct ClaudeBridgePreferences: Codable {
    var enabled: Bool
    var baseURL: String
}

func claudeValidateEndpoint(_ string: String, allowLocalHTTP: Bool = true) throws -> URL {
    guard let components = URLComponents(string: string), let url = components.url,
          let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
          components.query == nil, components.fragment == nil,
          components.scheme == "https" || (allowLocalHTTP && components.scheme == "http" &&
              ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased()))
    else { throw ClaudeBridgeError.invalidSetting("HTTPS-URL ohne Zugangsdaten, Query oder Fragment erforderlich") }
    return url
}

func claudeValidateGlucoseAlerts(_ alerts: [GlucoseAlert], configuration: GlucoseAlertConfiguration) throws {
    for time in [configuration.dayStart, configuration.nightStart] {
        guard (0 ... 23).contains(time.hour), (0 ... 59).contains(time.minute) else {
            throw ClaudeBridgeError.invalidSetting("Alarmzeit außerhalb 00:00–23:59")
        }
    }
    guard Set(alerts.map(\.id)).count == alerts.count else { throw ClaudeBridgeError.invalidSetting("Doppelte Alarm-ID") }
    for type in GlucoseAlertType.allCases {
        let entries = alerts.filter { $0.type == type }
        guard !entries.isEmpty else { throw ClaudeBridgeError.invalidSetting("Mindestens ein Alarm je Typ erforderlich") }
        let windows = entries.map(\.activeOption)
        guard Set(windows).count == windows.count, !(windows.contains(.always) && windows.count > 1) else {
            throw ClaudeBridgeError.invalidSetting("Überlappende Alarm-Zeitfenster")
        }
    }
    for alert in alerts {
        let range: ClosedRange<Decimal>
        switch alert.type {
        case .urgentLow: range = 54 ... 80
        case .low, .forecastedLow: range = 54 ... 100
        case .high: range = 100 ... 400
        case .carbsRequired: range = 5 ... 50
        }
        guard range.contains(alert.thresholdMgDL), alert.type != .urgentLow || alert.isEnabled else {
            throw ClaudeBridgeError.invalidSetting("Alarmgrenze oder Pflichtalarm ungültig")
        }
        guard !alert.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              AlarmSoundCatalog.allFilenames.contains(alert.soundFilename) else {
            throw ClaudeBridgeError.invalidSetting("Alarmname oder Sounddatei ungültig")
        }
    }
}

func claudeValidateDeviceAlerts(_ configs: [DeviceAlertSeverityConfig]) throws {
    guard Set(configs.map(\.id)).count == configs.count else { throw ClaudeBridgeError.invalidSetting("Doppelte Alarm-ID") }
    for severity in DeviceAlertSeverity.allCases {
        let entries = configs.filter { $0.severity == severity }
        guard entries.contains(where: { $0.activeOption == .always }),
              Set(entries.map(\.activeOption)).count == entries.count else {
            throw ClaudeBridgeError.invalidSetting("Eine Basis-Konfiguration und eindeutige Zeitfenster je Schweregrad erforderlich")
        }
    }
    for config in configs {
        guard config.severity != .critical || config.isEnabled,
              AlarmSoundCatalog.allFilenames.contains(config.soundFilename) else {
            throw ClaudeBridgeError.invalidSetting("Kritischer Alarm darf nicht deaktiviert werden; Sounddatei muss lokal sein")
        }
    }
}

private func claudeDecimal(_ value: Double, places: Int = 3) -> Decimal {
    Decimal(string: String(format: "%.\(places)f", value)) ?? Decimal(value)
}

private func claudeStartString(_ minutes: Int) -> String {
    String(format: "%02d:%02d:00", minutes / 60, minutes % 60)
}

private func claudeTimeLabel(_ minutes: Int) -> String {
    String(format: "%02d:%02d", minutes / 60, minutes % 60)
}

struct ClaudeScheduleItem {
    let minutes: Int
    let fields: [String: ClaudeJSONValue]
}

func claudeParseSchedule(_ raw: [[String: ClaudeJSONValue]]?) throws -> [ClaudeScheduleItem] {
    guard let raw, !raw.isEmpty else { throw ClaudeBridgeError.invalidSchedule("leer") }
    var items: [ClaudeScheduleItem] = []
    for entry in raw {
        let minutes: Int
        if let time = entry["time"]?.stringValue ?? entry["start"]?.stringValue {
            let parts = time.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard (parts.count == 2 || parts.count == 3),
                  let hour = Int(parts[0]), let minute = Int(parts[1]),
                  (0 ..< 24).contains(hour), (0 ..< 60).contains(minute),
                  parts.count == 2 || parts[2] == "00" else {
                throw ClaudeBridgeError.invalidSchedule("Zeit „\(time)“")
            }
            minutes = hour * 60 + minute
        } else if let offset = entry["minutes"]?.doubleValue ?? entry["offset"]?.doubleValue {
            guard offset.isFinite, offset.rounded() == offset, (0 ..< 1440).contains(offset) else {
                throw ClaudeBridgeError.invalidSchedule("Minuten außerhalb 0–1439 oder nicht ganzzahlig")
            }
            minutes = Int(offset)
        } else {
            throw ClaudeBridgeError.invalidSchedule("Eintrag ohne Zeit")
        }
        guard minutes % 30 == 0 else {
            throw ClaudeBridgeError.invalidSchedule("Zeiten müssen auf 30 Minuten liegen (\(claudeTimeLabel(minutes)))")
        }
        items.append(ClaudeScheduleItem(minutes: minutes, fields: entry))
    }
    guard items.first?.minutes == 0 else { throw ClaudeBridgeError.invalidSchedule("erster Eintrag muss 00:00 sein") }
    for index in 1 ..< max(items.count, 1) where items[index].minutes <= items[index - 1].minutes {
        throw ClaudeBridgeError.invalidSchedule("Zeiten müssen aufsteigend sein")
    }
    return items
}

func claudeValidateScheduleValue(_ value: Double, target: String) throws {
    let range: ClosedRange<Double>
    let step: Double
    switch target {
    case "isf": range = 9 ... 540; step = 1
    case "carb_ratios": range = 1 ... 50; step = 0.1
    case "bg_targets": range = 72 ... 180; step = 1
    default: throw ClaudeBridgeError.unknownTarget(target)
    }
    guard value.isFinite, range.contains(value), abs(value / step - (value / step).rounded()) < 0.000001 else {
        throw ClaudeBridgeError.invalidSchedule("Wert außerhalb der nativen Grenzen oder Schrittweite für \(target)")
    }
}

private func claudeValue(_ item: ClaudeScheduleItem, _ keys: [String]) throws -> Double {
    for key in keys {
        if let value = item.fields[key]?.doubleValue {
            guard value > 0, value.isFinite else { throw ClaudeBridgeError.invalidSchedule("Wert muss > 0 sein") }
            return value
        }
    }
    throw ClaudeBridgeError.invalidSchedule("Wert fehlt um \(claudeTimeLabel(item.minutes))")
}

/// Value of a schedule (minutes -> value) at a given minute of the day.
private func claudeValueAt(_ minute: Int, _ entries: [(Int, Double)]) -> Double? {
    entries.last(where: { $0.0 <= minute })?.1
}

private func claudeScheduleDiff(
    old: [(Int, Double)],
    new: [(Int, Double)],
    unit: String
) -> [ClaudeDiffLine] {
    let times = Set(old.map(\.0) + new.map(\.0)).sorted()
    return times.compactMap { minute in
        let before = claudeValueAt(minute, old)
        let after = claudeValueAt(minute, new)
        guard before != after else { return nil }
        var warning: String?
        if let before, let after, before > 0 {
            let change = abs(after - before) / before
            if change >= 0.3 { warning = "Änderung um \(Int((change * 100).rounded())) %" }
        }
        return ClaudeDiffLine(
            key: "ab \(claudeTimeLabel(minute))",
            old: before.map { "\(claudeFormat($0)) \(unit)" } ?? "–",
            new: after.map { "\(claudeFormat($0)) \(unit)" } ?? "–",
            warning: warning
        )
    }
}

func claudeBGTargetDiff(old: [BGTargetEntry], new: [BGTargetEntry]) -> [ClaudeDiffLine] {
    let bounds: [(String, KeyPath<BGTargetEntry, Decimal>)] = [("Untergrenze", \.low), ("Obergrenze", \.high)]
    return bounds.flatMap { label, keyPath in
        claudeScheduleDiff(
            old: old.map { ($0.offset, NSDecimalNumber(decimal: $0[keyPath: keyPath]).doubleValue) },
            new: new.map { ($0.offset, NSDecimalNumber(decimal: $0[keyPath: keyPath]).doubleValue) },
            unit: "mg/dL"
        ).map { line in
            ClaudeDiffLine(key: "\(label) \(line.key)", old: line.old, new: line.new, warning: line.warning)
        }
    }
}

private func claudeFormat(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = 3
    return formatter.string(from: value as NSNumber) ?? "\(value)"
}

// MARK: - Service

@MainActor final class ClaudeBridgeService: ObservableObject {
    static let shared = ClaudeBridgeService()

    @Published private(set) var pending: [ClaudeProposal] = []
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var history: [String] = []
    @Published private(set) var isSyncing = false

    private var resolver: Resolver?
    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?
    private var notifiedIDs = Set<String>()
    private var lastHistoryUpload: Date?

    private var settingsManager: SettingsManager? { resolver?.resolve(SettingsManager.self) }
    private var storage: FileStorage? { resolver?.resolve(FileStorage.self) }
    private var broadcaster: Broadcaster? { resolver?.resolve(Broadcaster.self) }
    private var deviceManager: DeviceDataManager? { resolver?.resolve(DeviceDataManager.self) }

    /// A newly imported connection must not inherit proposals or upload checkpoints from its predecessor.
    func resetConnectionState() {
        pending = []
        lastSync = nil
        lastError = nil
        lastHistoryUpload = nil
        notifiedIDs = []
        history = []
    }

    func start(resolver: Resolver) {
        guard self.resolver == nil else { return }
        self.resolver = resolver

        resolver.resolve(APSManager.self)?.lastLoopDateSubject
            .receive(on: DispatchQueue.main)
            .sink { _ in
                Task { @MainActor in await ClaudeBridgeService.shared.sync() }
            }
            .store(in: &cancellables)

        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in await ClaudeBridgeService.shared.sync() }
        }

        Task { @MainActor in await self.sync() }
    }

    // MARK: Networking

    private struct Connection {
        let baseURL: String
        let token: String?
    }

    private var connection: Connection { Connection(baseURL: ClaudeBridgeConfig.baseURL, token: ClaudeBridgeConfig.token) }

    private func request(_ path: String, method: String = "GET", body: Any? = nil, connection: Connection? = nil) async throws -> Data {
        let connection = connection ?? self.connection
        guard let token = connection.token, !connection.baseURL.isEmpty else {
            throw ClaudeBridgeError.notConfigured
        }
        var base = connection.baseURL
        if !base.lowercased().hasPrefix("http") { base = "http://" + base }
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + path) else { throw ClaudeBridgeError.badURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            throw ClaudeBridgeError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    func sync() async {
        guard ClaudeBridgeConfig.enabled, ClaudeBridgeConfig.isConfigured, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let stateResponse = try await request("/trio/state", method: "POST", body: snapshot())
            try await uploadHistoryIfNeeded(stateResponse)
            let data = try await request("/trio/proposals?status=pending")
            let proposals = try JSONDecoder().decode([ClaudeProposal].self, from: data)
            pending = proposals
            lastSync = Date()
            lastError = nil
            notifyAboutNew(proposals)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: History (up to 30 days, incremental)

    private func uploadHistoryIfNeeded(_ stateResponse: Data) async throws {
        if let last = lastHistoryUpload, Date().timeIntervalSince(last) < 15 * 60 { return }
        struct StateResponse: Decodable { let historyThrough: String? }
        let response = try? JSONDecoder().decode(StateResponse.self, from: stateResponse)
        let earliest = Date().addingTimeInterval(-30 * 24 * 3600)
        var since = earliest
        if let through = response?.historyThrough, let date = ISO8601DateFormatter().date(from: through) {
            since = max(earliest, date.addingTimeInterval(-2 * 3600))
        }
        let context = CoreDataStack.shared.newTaskContext()
        let payload: [String: Any] = await context.perform {
            ClaudeBridgeService.collectHistory(since: since, context: context)
        }
        _ = try await request("/trio/history", method: "POST", body: payload)
        lastHistoryUpload = Date()
    }

    nonisolated static func collectHistory(since: Date, context: NSManagedObjectContext) -> [String: Any] {
        let iso = ISO8601DateFormatter()

        func fetch(_ entity: String, _ dateKey: String) -> [NSManagedObject] {
            let request = NSFetchRequest<NSManagedObject>(entityName: entity)
            request.predicate = NSPredicate(format: "%K > %@", dateKey, since as NSDate)
            request.sortDescriptors = [NSSortDescriptor(key: dateKey, ascending: true)]
            request.fetchLimit = 20000
            return (try? context.fetch(request)) ?? []
        }
        func num(_ object: NSManagedObject?, _ key: String) -> Double? {
            (object?.value(forKey: key) as? NSNumber)?.doubleValue
        }
        func flag(_ object: NSManagedObject?, _ key: String) -> Bool {
            (object?.value(forKey: key) as? NSNumber)?.boolValue ?? false
        }
        func time(_ object: NSManagedObject, _ key: String) -> String? {
            (object.value(forKey: key) as? Date).map { iso.string(from: $0) }
        }

        let glucose: [[String: Any]] = fetch("GlucoseStored", "date").compactMap { object in
            guard let t = time(object, "date"), let value = num(object, "glucose") else { return nil }
            return ["t": t, "v": value, "d": object.value(forKey: "direction") as? String ?? ""]
        }
        let carbs: [[String: Any]] = fetch("CarbEntryStored", "date").compactMap { object in
            guard let t = time(object, "date") else { return nil }
            return [
                "t": t,
                "c": num(object, "carbs") ?? 0,
                "f": num(object, "fat") ?? 0,
                "p": num(object, "protein") ?? 0,
                "fpu": flag(object, "isFPU"),
                "note": object.value(forKey: "note") as? String ?? ""
            ]
        }
        var boluses: [[String: Any]] = []
        var tempBasals: [[String: Any]] = []
        for event in fetch("PumpEventStored", "timestamp") {
            guard let t = time(event, "timestamp") else { continue }
            if let bolus = event.value(forKey: "bolus") as? NSManagedObject {
                boluses.append([
                    "t": t,
                    "u": num(bolus, "amount") ?? 0,
                    "smb": flag(bolus, "isSMB"),
                    "ext": flag(bolus, "isExternal")
                ])
            }
            if let temp = event.value(forKey: "tempBasal") as? NSManagedObject {
                tempBasals.append(["t": t, "rate": num(temp, "rate") ?? 0, "min": num(temp, "duration") ?? 0])
            }
        }
        let determinations: [[String: Any]] = fetch("OrefDetermination", "deliverAt").compactMap { object in
            guard let t = time(object, "deliverAt") else { return nil }
            var entry: [String: Any] = ["t": t, "enacted": flag(object, "enacted")]
            for (short, key) in [
                ("bg", "glucose"), ("iob", "iob"), ("cob", "cob"), ("isf", "insulinSensitivity"),
                ("cr", "carbRatio"), ("sens", "sensitivityRatio"), ("target", "currentTarget"),
                ("eventual", "eventualBG"), ("rate", "rate"), ("smb", "smbToDeliver"),
                ("basal", "scheduledBasal"), ("req", "insulinReq")
            ] {
                if let value = num(object, key) { entry[short] = value }
            }
            return entry
        }
        let tdd: [[String: Any]] = fetch("TDDStored", "date").compactMap { object in
            guard let t = time(object, "date") else { return nil }
            return [
                "t": t,
                "total": num(object, "total") ?? 0,
                "bolus": num(object, "bolus") ?? 0,
                "temp": num(object, "tempBasal") ?? 0,
                "scheduled": num(object, "scheduledBasal") ?? 0
            ]
        }
        return [
            "since": iso.string(from: since),
            "glucose": glucose,
            "carbs": carbs,
            "boluses": boluses,
            "tempBasals": tempBasals,
            "determinations": determinations,
            "tdd": tdd
        ]
    }

    private func notifyAboutNew(_ proposals: [ClaudeProposal]) {
        let fresh = proposals.filter { !notifiedIDs.contains($0.id) }
        guard !fresh.isEmpty else { return }
        fresh.forEach { notifiedIDs.insert($0.id) }
        let content = UNMutableNotificationContent()
        content.title = "Die KI schlägt eine Änderung vor"
        content.body = fresh.count == 1
            ? (fresh[0].reason ?? "Bitte in Trio prüfen und freigeben.")
            : "\(fresh.count) neue Vorschläge – bitte in Trio prüfen."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "claude.bridge.\(fresh[0].id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func appPreferences() -> ClaudeAppPreferences {
        let defaults = UserDefaults.standard
        return ClaudeAppPreferences(
            colorSchemePreference: ColorSchemeOption(rawValue: defaults.string(forKey: "colorSchemePreference") ?? "") ?? .systemDefault,
            calendarID: resolver?.resolve(CalendarManager.self)?.currentCalendarID ?? "",
            liveActivityOrder: defaults.stringArray(forKey: "liveActivityOrder") ?? LiveActivityItem.defaultItems.map(\.rawValue),
            isTrioRemoteControlEnabled: defaults.bool(forKey: "isTrioRemoteControlEnabled")
        )
    }

    private func mealPreferences() -> ClaudeAIMealPreferences {
        ClaudeAIMealPreferences(
            provider: AIMealSettingsStore.provider.rawValue,
            anthropicModel: AIMealSettingsStore.model(for: .anthropic),
            openAIModel: AIMealSettingsStore.model(for: .openAI),
            openAICompatibleModel: AIMealSettingsStore.model(for: .openAICompatible),
            customBaseURL: AIMealSettingsStore.customBaseURL
        )
    }

    private func settingsCatalog() -> [[String: Any]] {
        var rows: [[String: Any]] = []
        func add<T: Encodable>(_ target: String, _ value: T) {
            if let values = try? claudeDictionary(value) { rows += claudeCatalogRows(target: target, values: values) }
        }
        if let settingsManager {
            add("settings", settingsManager.settings)
            add("preferences", settingsManager.preferences)
            add("pump_settings", settingsManager.pumpSettings)
        }
        add("glucose_alerts", ClaudeGlucoseAlertSettings(
            configuration: GlucoseAlertsStore.shared.configuration, alerts: GlucoseAlertsStore.shared.alerts
        ))
        add("device_alerts", ClaudeDeviceAlertSettings(configs: DeviceAlertsStore.shared.configs))
        add("app_preferences", appPreferences())
        let meal = mealPreferences()
        if let mealRows = try? claudeAIMealCatalogRows(meal) { rows += mealRows }
        add("bridge_config", ClaudeBridgePreferences(enabled: ClaudeBridgeConfig.enabled, baseURL: ClaudeBridgeConfig.baseURL))
        let url = resolver?.resolve(Keychain.self)?.getValue(String.self, forKey: NightscoutConfig.Config.urlKey) ?? ""
        rows += claudeCatalogRows(target: "nightscout", values: ["url": url])
        for (target, key, reason) in [
            ("nightscout", "secret", "Zugangsdaten ausschließlich lokal in Nightscout eingeben; Verbindung wird geprüft."),
            ("ai_meal", "apiKey", "API-Key ausschließlich lokal im gewählten Anbieter hinterlegen."),
            ("bridge_config", "token", "Bridge-Token ausschließlich lokal eingeben."),
            ("app_preferences", "remoteControlSharedSecret", "Remote-Control-Geheimnis ausschließlich lokal eingeben."),
            ("device_setup", "pump", "Pumpen-Pairing und gerätespezifische Einstellungen im nativen Herstellerdialog."),
            ("device_setup", "cgm", "CGM-Pairing und gerätespezifische Einstellungen im nativen Herstellerdialog."),
            ("integrations", "tidepool", "Tidepool-Anmeldung benötigt den interaktiven OAuth-Dialog."),
            ("permissions", "health_calendar_notifications", "iOS-Berechtigungen werden ausschließlich im Systemdialog erteilt.")
        ] {
            if target == "ai_meal", meal.provider == AIMealProvider.appleIntelligence.rawValue { continue }
            rows.append(["target": target, "key": key, "type": "string", "access": "action", "reason": reason,
                         "constraints": [:], "current": NSNull()])
        }
        // These vendor settings have no public read/write API. Name them explicitly instead of claiming proposal support.
        let libreReason = "Im nativen Libre-CGM-Dialog ändern; Vendor-Modul bietet keine öffentliche Get/Set-API."
        for key in ["mmBackfillFromHistory", "mmSyncToNS", "shouldPersistSensorData", "mmAlwaysDisplayGlucose",
                    "mmShowTransmitterBattery", "mmAlertLowBatteryWarning", "mmAlertInvalidSensorDetected",
                    "mmAlertNewSensorDetected", "mmAlertNoSensorDetected", "mmAlertSensorSoonExpire"] {
            rows.append(["target": "libre_settings", "key": key, "type": "boolean", "current": NSNull(),
                         "access": "action", "constraints": [:], "reason": libreReason])
        }
        for (key, type, constraints) in [
            ("mmNotifyEveryXTimes", "number", ["minimum": 0, "maximum": 9, "integer": true] as [String: Any]),
            ("mmCriticalAlarmsVolume", "number", ["minimum": 60, "maximum": 100, "step": 5, "requires": "iOS Critical Alerts permission"]),
            ("glucoseSchedules", "array", ["itemFields": ["from", "to", "enabled", "lowAlarm", "highAlarm"]]),
            ("snoozedUntil", "string", ["description": "Lokale Alarm-Stummschaltung"])
        ] {
            rows.append(["target": "libre_settings", "key": key, "type": type, "current": NSNull(),
                         "access": "action", "constraints": constraints, "reason": libreReason])
        }
        if let storage {
            for (target, value, constraints) in [
                ("basal_profile", claudeJSONObject(storage.retrieve(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self) ?? []), ["unit": "U/h", "intervalMinutes": 30] as [String: Any]),
                ("isf", claudeJSONObject(storage.retrieve(OpenAPS.Settings.insulinSensitivities, as: InsulinSensitivities.self)?.sensitivities ?? []), ["minimum": 9, "maximum": 540, "unit": "mg/dL/U", "intervalMinutes": 30]),
                ("carb_ratios", claudeJSONObject(storage.retrieve(OpenAPS.Settings.carbRatios, as: CarbRatios.self)?.schedule ?? []), ["minimum": 1, "maximum": 50, "unit": "g/U", "intervalMinutes": 30]),
                ("bg_targets", claudeJSONObject(storage.retrieve(OpenAPS.Settings.bgTargets, as: BGTargets.self)?.targets ?? []), ["minimum": 72, "maximum": 180, "unit": "mg/dL", "intervalMinutes": 30])
            ] {
                rows.append(["target": target, "key": "schedule", "type": "array", "current": value,
                             "access": "proposal", "constraints": constraints])
            }
        }
        if let resolver { rows += AIAdditionalSettings.catalogRows(resolver: resolver) }
        return rows
    }

    // MARK: Snapshot (read-only data for Claude)

    private func snapshot() -> [String: Any] {
        var result: [String: Any] = [
            "app": "Trio",
            "sentAt": ISO8601DateFormatter().string(from: Date()),
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "",
            "scheduleUnits": [
                "isf": "mg/dL per U",
                "bg_targets": "mg/dL",
                "carb_ratios": "g per U",
                "basal_profile": "U/h"
            ]
        ]
        if let settingsManager {
            result["settings"] = claudeJSONObject(settingsManager.settings)
            result["preferences"] = claudeJSONObject(settingsManager.preferences)
            result["pumpSettings"] = claudeJSONObject(settingsManager.pumpSettings)
            result["units"] = settingsManager.settings.units.rawValue
        }
        if let storage {
            if let basal = storage.retrieve(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self) {
                result["basalProfile"] = claudeJSONObject(basal)
            }
            if let isf = storage.retrieve(OpenAPS.Settings.insulinSensitivities, as: InsulinSensitivities.self) {
                result["isf"] = claudeJSONObject(isf)
            }
            if let carbRatios = storage.retrieve(OpenAPS.Settings.carbRatios, as: CarbRatios.self) {
                result["carbRatios"] = claudeJSONObject(carbRatios)
            }
            if let targets = storage.retrieve(OpenAPS.Settings.bgTargets, as: BGTargets.self) {
                result["bgTargets"] = claudeJSONObject(targets)
            }
        }
        if let pumpManager = deviceManager?.pumpManager {
            result["supportedBasalRates"] = pumpManager.supportedBasalRates.filter { $0 > 0 }
            result["pump"] = pumpManager.localizedTitle
        }
        let stateRequest = StateIntentRequest()
        let context = CoreDataStack.shared.persistentContainer.viewContext
        var status: [String: Any] = [:]
        if let glucose = try? stateRequest.getLastGlucose(onContext: context) {
            status["glucose"] = glucose.glucose
            status["trend"] = glucose.trend
            status["delta"] = glucose.delta
            status["glucoseDate"] = ISO8601DateFormatter().string(from: glucose.dateGlucose)
        }
        if let iobCob = try? stateRequest.getIobAndCob(onContext: context) {
            status["iob"] = iobCob.iob
            status["cob"] = iobCob.cob
        }
        if let lastLoop = resolver?.resolve(APSManager.self)?.lastLoopDate {
            status["lastLoop"] = ISO8601DateFormatter().string(from: lastLoop)
        }
        result["status"] = status
        result["settingsCatalog"] = settingsCatalog()
        return result
    }

    private func uploadTherapySettings() async {
        do { try await resolver?.resolve(NightscoutManager.self)?.uploadProfiles() }
        catch { warning(.default, "Profile upload failed after approved change: \(error.localizedDescription)") }
        await resolver?.resolve(TidepoolManager.self)?.uploadSettings()
    }

    // MARK: Prepare (preview) & apply

    func prepare(_ proposal: ClaudeProposal) throws -> ClaudePreparedChange {
        guard let settingsManager, let storage, let broadcaster else { throw ClaudeBridgeError.notConfigured }

        switch proposal.target {
        case "settings":
            let (newValue, lines) = try patched(settingsManager.settings, with: proposal.patch, target: "settings")
            let oldValue = settingsManager.settings
            guard newValue.low < newValue.high else { throw ClaudeBridgeError.invalidSetting("low muss kleiner als high sein") }
            guard newValue.cgmPluginIdentifier == oldValue.cgmPluginIdentifier else {
                throw ClaudeBridgeError.invalidSetting("CGM-Plugin ausschließlich im nativen Pairing-Dialog ändern")
            }
            if newValue.cgm != oldValue.cgm, newValue.cgm == .plugin || oldValue.cgm == .plugin {
                throw ClaudeBridgeError.invalidSetting("CGM-Plugin ausschließlich im nativen Pairing-Dialog ändern")
            }
            if (newValue.dosingMode != oldValue.dosingMode || newValue.cgm != oldValue.cgm), newValue.dosingMode != .open,
               (newValue.cgm == .none || deviceManager?.pumpManager == nil) {
                throw ClaudeBridgeError.invalidSetting("Automatisierung benötigt CGM und Pumpe")
            }
            let resolver = self.resolver
            return ClaudePreparedChange(proposal: proposal, title: "Trio-Einstellungen", lines: lines) {
                if newValue.useCalendar && !oldValue.useCalendar {
                    guard await resolver?.resolve(CalendarManager.self)?.requestAccessIfNeeded() == true else {
                        throw ClaudeBridgeError.invalidSetting("Kalenderberechtigung fehlt")
                    }
                }
                if newValue.useAppleHealth && !oldValue.useAppleHealth {
                    guard try await resolver?.resolve(HealthKitManager.self)?.requestPermission() == true else {
                        throw ClaudeBridgeError.invalidSetting("Health-Berechtigung fehlt")
                    }
                }
                guard claudeValuesEqual(try claudeDictionary(settingsManager.settings), try claudeDictionary(oldValue)) else {
                    throw ClaudeBridgeError.invalidSetting("Einstellungen wurden während der Freigabe geändert; Vorschlag erneut prüfen")
                }
                settingsManager.settings = newValue
                if newValue.cgm != oldValue.cgm {
                    resolver?.resolve(FetchGlucoseManager.self)?.updateGlucoseSource(
                        cgmGlucoseSourceType: newValue.cgm, cgmGlucosePluginId: newValue.cgm.rawValue
                    )
                    broadcaster.notify(GlucoseObserver.self, on: .main) { $0.glucoseDidUpdate([]) }
                }
                if newValue.isUploadEnabled && !oldValue.isUploadEnabled {
                    do { try await resolver?.resolve(NightscoutManager.self)?.uploadProfiles() }
                    catch { warning(.default, "Nightscout profile upload after approved settings change failed: \(error.localizedDescription)") }
                }
            }

        case "preferences":
            let oldValue = settingsManager.preferences
            let (newValue, lines) = try patched(oldValue, with: proposal.patch, target: "preferences")
            guard !newValue.sigmoid || newValue.useNewFormula else {
                throw ClaudeBridgeError.invalidSetting("Sigmoid benötigt aktivierte dynamische Empfindlichkeit (useNewFormula)")
            }
            guard newValue.autosensMin <= newValue.autosensMax else {
                throw ClaudeBridgeError.invalidSetting("autosens_min darf autosens_max nicht übersteigen")
            }
            let resolver = self.resolver
            return ClaudePreparedChange(proposal: proposal, title: "Algorithmus-Einstellungen (oref)", lines: lines) {
                if newValue.useNewFormula && !oldValue.useNewFormula {
                    guard try await resolver?.resolve(TDDStorage.self)?.hasSufficientTDD() == true else {
                        throw ClaudeBridgeError.invalidSetting("Dynamische Empfindlichkeit benötigt ausreichend TDD-Verlauf")
                    }
                }
                guard settingsManager.preferences == oldValue else {
                    throw ClaudeBridgeError.invalidSetting("Algorithmus-Einstellungen wurden während der Freigabe geändert")
                }
                settingsManager.preferences = newValue
            }

        case "isf":
            let items = try claudeParseSchedule(proposal.schedule)
            let entries = try items.map { item in
                let value = try claudeValue(item, ["value", "sensitivity", "isf"])
                try claudeValidateScheduleValue(value, target: "isf")
                return InsulinSensitivityEntry(
                    sensitivity: claudeDecimal(value, places: 1),
                    offset: item.minutes,
                    start: claudeStartString(item.minutes)
                )
            }
            let old = storage.retrieve(OpenAPS.Settings.insulinSensitivities, as: InsulinSensitivities.self)?
                .sensitivities.map { ($0.offset, NSDecimalNumber(decimal: $0.sensitivity).doubleValue) } ?? []
            let new = entries.map { ($0.offset, NSDecimalNumber(decimal: $0.sensitivity).doubleValue) }
            let profile = InsulinSensitivities(units: .mgdL, userPreferredUnits: .mgdL, sensitivities: entries)
            return ClaudePreparedChange(
                proposal: proposal,
                title: "Insulinempfindlichkeit (ISF)",
                lines: claudeScheduleDiff(old: old, new: new, unit: "mg/dL/U")
            ) {
                storage.save(profile, as: OpenAPS.Settings.insulinSensitivities)
                broadcaster.notify(InsulinSensitivitiesObserver.self, on: .main) {
                    $0.insulinSensitivitiesDidChange(profile)
                }
                await self.uploadTherapySettings()
            }

        case "carb_ratios":
            let items = try claudeParseSchedule(proposal.schedule)
            let entries = try items.map { item in
                let value = try claudeValue(item, ["value", "ratio"])
                try claudeValidateScheduleValue(value, target: "carb_ratios")
                return CarbRatioEntry(
                    start: claudeStartString(item.minutes),
                    offset: item.minutes,
                    ratio: claudeDecimal(value, places: 1)
                )
            }
            let old = storage.retrieve(OpenAPS.Settings.carbRatios, as: CarbRatios.self)?
                .schedule.map { ($0.offset, NSDecimalNumber(decimal: $0.ratio).doubleValue) } ?? []
            let new = entries.map { ($0.offset, NSDecimalNumber(decimal: $0.ratio).doubleValue) }
            let profile = CarbRatios(units: .grams, schedule: entries)
            return ClaudePreparedChange(
                proposal: proposal,
                title: "Kohlenhydrat-Faktor (KH/IE)",
                lines: claudeScheduleDiff(old: old, new: new, unit: "g/U")
            ) {
                storage.save(profile, as: OpenAPS.Settings.carbRatios)
                broadcaster.notify(CarbRatiosObserver.self, on: .main) {
                    $0.carbRatiosDidChange(profile)
                }
                await self.uploadTherapySettings()
            }

        case "bg_targets":
            let items = try claudeParseSchedule(proposal.schedule)
            let entries = try items.map { item -> BGTargetEntry in
                let low = try claudeValue(item, ["low", "value", "target"])
                let high = item.fields["high"] == nil ? low : try claudeValue(item, ["high"])
                try claudeValidateScheduleValue(low, target: "bg_targets")
                try claudeValidateScheduleValue(high, target: "bg_targets")
                guard high >= low else { throw ClaudeBridgeError.invalidSchedule("high < low") }
                return BGTargetEntry(
                    low: claudeDecimal(low, places: 0),
                    high: claudeDecimal(high, places: 0),
                    start: claudeStartString(item.minutes),
                    offset: item.minutes
                )
            }
            let old = storage.retrieve(OpenAPS.Settings.bgTargets, as: BGTargets.self)?.targets ?? []
            let profile = BGTargets(units: .mgdL, userPreferredUnits: .mgdL, targets: entries)
            return ClaudePreparedChange(
                proposal: proposal,
                title: "Glukose-Zielbereich",
                lines: claudeBGTargetDiff(old: old, new: entries)
            ) {
                storage.save(profile, as: OpenAPS.Settings.bgTargets)
                broadcaster.notify(BGTargetsObserver.self, on: .main) {
                    $0.bgTargetsDidChange(profile)
                }
                await self.uploadTherapySettings()
            }

        case "basal_profile":
            let items = try claudeParseSchedule(proposal.schedule)
            guard let pump = deviceManager?.pumpManager else { throw ClaudeBridgeError.noPump }
            let supported = pump.supportedBasalRates.filter { $0 > 0 }
            let entries = try items.map { item -> BasalProfileEntry in
                var rate = try claudeValue(item, ["value", "rate"])
                guard let match = supported.first(where: { abs($0 - rate) < 0.0005 }) else {
                    throw ClaudeBridgeError.unsupportedBasalRate(rate)
                }
                rate = match
                return BasalProfileEntry(start: claudeStartString(item.minutes), minutes: item.minutes, rate: claudeDecimal(rate))
            }
            let old = storage.retrieve(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self)?
                .map { ($0.minutes, NSDecimalNumber(decimal: $0.rate).doubleValue) } ?? []
            let new = entries.map { ($0.minutes, NSDecimalNumber(decimal: $0.rate).doubleValue) }
            let deviceManager = self.deviceManager
            return ClaudePreparedChange(
                proposal: proposal,
                title: "Basalrate",
                lines: claudeScheduleDiff(old: old, new: new, unit: "U/h")
            ) {
                guard let pump = deviceManager?.pumpManager else { throw ClaudeBridgeError.noPump }
                let values = entries.map {
                    RepeatingScheduleValue(
                        startTime: TimeInterval($0.minutes * 60),
                        value: NSDecimalNumber(decimal: $0.rate).doubleValue
                    )
                }
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    pump.syncBasalRateSchedule(items: values) { result in
                        switch result {
                        case .success: continuation.resume()
                        case let .failure(error): continuation.resume(throwing: error)
                        }
                    }
                }
                storage.save(entries, as: OpenAPS.Settings.basalProfile)
                broadcaster.notify(BasalProfileObserver.self, on: .main) {
                    $0.basalProfileDidChange(entries)
                }
                await self.uploadTherapySettings()
            }

        default:
            return try prepareAdditional(proposal)
        }
    }

    private func prepareAdditional(_ proposal: ClaudeProposal) throws -> ClaudePreparedChange {
        guard let resolver else { throw ClaudeBridgeError.notConfigured }
        switch proposal.target {
        case "pump_settings":
            guard let settingsManager else { throw ClaudeBridgeError.notConfigured }
            let (new, lines) = try patched(settingsManager.pumpSettings, with: proposal.patch, target: proposal.target)
            let provider = UnitsLimitsSettings.Provider(resolver: resolver)
            return ClaudePreparedChange(proposal: proposal, title: "Insulinwirkdauer und Abgabegrenzen", lines: lines) {
                for try await _ in provider.save(settings: new).values {}
                let actual = try claudeDictionary(settingsManager.pumpSettings)
                let requested = try claudeDictionary(new)
                let mismatches = (proposal.patch ?? [:]).keys.filter { !claudeValuesEqual(actual[$0], requested[$0]) }.sorted()
                guard mismatches.isEmpty else {
                    let result = mismatches.map { "\($0)=\(claudeJSONString(actual[$0]))" }.joined(separator: ", ")
                    throw ClaudeBridgeError.invalidSetting("Pumpe hat abweichende Istwerte gespeichert: \(result)")
                }
                await self.uploadTherapySettings()
            }
        case "glucose_alerts":
            let store = GlucoseAlertsStore.shared
            let old = ClaudeGlucoseAlertSettings(configuration: store.configuration, alerts: store.alerts)
            let (new, lines) = try patched(old, with: proposal.patch, target: proposal.target)
            try claudeValidateGlucoseAlerts(new.alerts, configuration: new.configuration)
            for alert in new.alerts where alert.snoozedUntil != old.alerts.first(where: { $0.id == alert.id })?.snoozedUntil {
                throw ClaudeBridgeError.invalidSetting("Alarm-Stummschaltung bleibt eine separate lokale Aktion")
            }
            return ClaudePreparedChange(proposal: proposal, title: "Glukose-Alarme", lines: lines) {
                store.configuration = new.configuration
                store.alerts = new.alerts
            }
        case "device_alerts":
            let store = DeviceAlertsStore.shared
            let (new, lines) = try patched(ClaudeDeviceAlertSettings(configs: store.configs), with: proposal.patch, target: proposal.target)
            try claudeValidateDeviceAlerts(new.configs)
            return ClaudePreparedChange(proposal: proposal, title: "Geräte-Alarme", lines: lines) { store.configs = new.configs }
        case "app_preferences":
            let (new, lines) = try patched(appPreferences(), with: proposal.patch, target: proposal.target)
            guard new.liveActivityOrder.count == 4,
                  new.liveActivityOrder.allSatisfy({ $0.isEmpty || LiveActivityItem(rawValue: $0) != nil }) else {
                throw ClaudeBridgeError.invalidSetting("Live Activity benötigt vier gültige Felder")
            }
            if !new.calendarID.isEmpty,
               !(resolver.resolve(CalendarManager.self)?.calendarIDs().contains(new.calendarID) ?? false) {
                throw ClaudeBridgeError.invalidSetting("Kalender nicht verfügbar; Kalenderberechtigung lokal erteilen")
            }
            if new.isTrioRemoteControlEnabled,
               (UserDefaults.standard.string(forKey: "trioRemoteControlSharedSecret") ?? "").isEmpty {
                throw ClaudeBridgeError.invalidSetting("Remote-Control-Geheimnis zuerst lokal einrichten")
            }
            return ClaudePreparedChange(proposal: proposal, title: "App-Darstellung und Dienste", lines: lines) {
                UserDefaults.standard.set(new.colorSchemePreference.rawValue, forKey: "colorSchemePreference")
                UserDefaults.standard.saveLiveActivityOrder(new.liveActivityOrder.map { LiveActivityItem(rawValue: $0) })
                Foundation.NotificationCenter.default.post(name: .liveActivityOrderDidChange, object: nil)
                UserDefaults.standard.set(new.isTrioRemoteControlEnabled, forKey: "isTrioRemoteControlEnabled")
                if var calendar = resolver.resolve(CalendarManager.self) {
                    calendar.currentCalendarID = new.calendarID.isEmpty ? nil : new.calendarID
                }
            }
        case "ai_meal":
            let old = mealPreferences()
            let (new, lines) = try patched(old, with: proposal.patch, target: proposal.target)
            let provider = try claudeValidateAIMealPreferences(new, current: old)
            return ClaudePreparedChange(proposal: proposal, title: "KI-Mahlzeitenanbieter", lines: lines) {
                if new.customBaseURL != old.customBaseURL { AIMealSettingsStore.customBaseURL = new.customBaseURL }
                if new.anthropicModel != old.anthropicModel { AIMealSettingsStore.setModel(new.anthropicModel, for: .anthropic) }
                if new.openAIModel != old.openAIModel { AIMealSettingsStore.setModel(new.openAIModel, for: .openAI) }
                if new.openAICompatibleModel != old.openAICompatibleModel {
                    AIMealSettingsStore.setModel(new.openAICompatibleModel, for: .openAICompatible)
                }
                AIMealSettingsStore.provider = provider
            }
        case "bridge_config":
            let old = ClaudeBridgePreferences(enabled: ClaudeBridgeConfig.enabled, baseURL: ClaudeBridgeConfig.baseURL)
            let (new, lines) = try patched(old, with: proposal.patch, target: proposal.target)
            if !new.baseURL.isEmpty {
                guard let components = URLComponents(string: new.baseURL), let host = components.host, !host.isEmpty,
                      ["http", "https"].contains(components.scheme ?? ""), components.user == nil, components.password == nil,
                      components.query == nil, components.fragment == nil else { throw ClaudeBridgeError.badURL }
            }
            guard !new.enabled || !new.baseURL.isEmpty else { throw ClaudeBridgeError.badURL }
            return ClaudePreparedChange(proposal: proposal, title: "KI-Bridge-Verbindung", lines: lines) {
                if new.baseURL != old.baseURL, !ClaudeBridgeConfig.setToken(nil) {
                    throw AIBridgeSetupError.keychain
                }
                ClaudeBridgeConfig.baseURL = new.baseURL
                ClaudeBridgeConfig.enabled = new.enabled
            }
        case "nightscout":
            guard let keychain = resolver.resolve(Keychain.self) else { throw ClaudeBridgeError.notConfigured }
            let oldURL = keychain.getValue(String.self, forKey: NightscoutConfig.Config.urlKey) ?? ""
            let (new, lines) = try patched(["url": oldURL], with: proposal.patch, target: proposal.target)
            let url = try claudeValidateEndpoint(new["url"] ?? "", allowLocalHTTP: false)
            let old = URLComponents(string: oldURL)
            let next = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let sameOrigin = old?.scheme == next?.scheme && old?.host == next?.host && old?.port == next?.port
            let secret = sameOrigin ? keychain.getValue(String.self, forKey: NightscoutConfig.Config.secretKey) : nil
            return ClaudePreparedChange(proposal: proposal, title: "Nightscout-Verbindung", lines: lines) {
                for try await _ in NightscoutAPI(url: url, secret: secret).checkConnection().values {}
                guard (keychain.getValue(String.self, forKey: NightscoutConfig.Config.urlKey) ?? "") == oldURL else {
                    throw ClaudeBridgeError.invalidSetting("Nightscout-Verbindung wurde während der Prüfung geändert")
                }
                if !sameOrigin { keychain.setValue("", forKey: NightscoutConfig.Config.secretKey) }
                keychain.setValue(url.absoluteString, forKey: NightscoutConfig.Config.urlKey)
            }
        case "relay_config":
            guard let patch = proposal.patch, let old = proposal.oldValues else { throw ClaudeBridgeError.emptyPatch }
            let allowed = Set(["provider", "model", "baseURL", "analysisTime"])
            guard Set(patch.keys).isSubset(of: allowed), Set(patch.keys).isSubset(of: Set(old.keys)) else {
                throw ClaudeBridgeError.notApplied("relay_config")
            }
            try claudeValidateSettingPatch(patch, current: old.mapValues(\.anyValue), target: proposal.target)
            var lines: [ClaudeDiffLine] = []
            for key in patch.keys.sorted() {
                guard let value = patch[key]?.stringValue else { throw ClaudeBridgeError.notApplied(key) }
                if key == "baseURL", !value.isEmpty { _ = try claudeValidateEndpoint(value) }
                if key == "model", value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ClaudeBridgeError.notApplied(key) }
                if key == "analysisTime", value.range(of: #"^([01][0-9]|2[0-3]):[0-5][0-9]$"#, options: .regularExpression) == nil {
                    throw ClaudeBridgeError.notApplied(key)
                }
                lines.append(ClaudeDiffLine(key: key, old: claudeJSONString(old[key]?.anyValue), new: claudeJSONString(value), warning: nil))
            }
            return ClaudePreparedChange(proposal: proposal, title: "Mac-Relay und Tagesanalyse", lines: lines) {}
        default:
            if let change = try AIAdditionalSettings.prepare(proposal, resolver: resolver) { return change }
            throw ClaudeBridgeError.unknownTarget(proposal.target)
        }
    }

    /// Applies a key/value patch to any Codable settings struct, validating that every key really took effect.
    private func patched<T: Codable>(_ value: T, with patch: [String: ClaudeJSONValue]?, target: String) throws -> (T, [ClaudeDiffLine]) {
        guard let patch, !patch.isEmpty else { throw ClaudeBridgeError.emptyPatch }
        var dict = try claudeDictionary(value)
        let oldDict = dict
        try claudeValidateSettingPatch(patch, current: oldDict, target: target)
        for (key, newValue) in patch {
            dict[key] = newValue.anyValue
        }
        let data = try JSONSerialization.data(withJSONObject: dict)
        let decoded: T
        do {
            decoded = try JSONCoding.decoder.decode(T.self, from: data)
        } catch {
            throw ClaudeBridgeError.notApplied(patch.keys.sorted().joined(separator: ", "))
        }
        let verify = try claudeDictionary(decoded)
        var lines: [ClaudeDiffLine] = []
        for key in patch.keys.sorted() {
            guard claudeValuesEqual(verify[key], patch[key]?.anyValue) else { throw ClaudeBridgeError.notApplied(key) }
            var warning: String?
            if let old = oldDict[key] as? NSNumber, let new = verify[key] as? NSNumber, old.doubleValue > 0,
               !(CFGetTypeID(old) == CFBooleanGetTypeID())
            {
                let change = abs(new.doubleValue - old.doubleValue) / old.doubleValue
                if change >= 0.3 { warning = "Änderung um \(Int((change * 100).rounded())) %" }
            }
            lines.append(ClaudeDiffLine(
                key: key,
                old: claudeJSONString(oldDict[key]),
                new: claudeJSONString(verify[key]),
                warning: warning
            ))
        }
        return (decoded, lines)
    }

    private func authenticate(_ reason: String) async throws {
        do {
            let ok = try await DeviceOwnerAuthentication.authenticate(reason)
            guard ok else { throw ClaudeBridgeError.authenticationFailed }
        } catch {
            throw ClaudeBridgeError.authenticationFailed
        }
    }

    func approve(_ proposal: ClaudeProposal, preview: [ClaudeDiffLine]) async -> Bool {
        let reportConnection = connection
        var change: ClaudePreparedChange
        do {
            let beforeAuthentication = try prepare(proposal)
            guard claudeChangesMatch(preview, beforeAuthentication.lines) else {
                throw ClaudeBridgeError.invalidSetting("Einstellungen wurden seit der Vorschau geändert; Vorschlag erneut prüfen")
            }
            try await authenticate("Änderung der KI übernehmen: \(beforeAuthentication.title)")
            let currentData = try await request("/trio/proposals?status=pending", connection: reportConnection)
            let currentProposals = try JSONDecoder().decode([ClaudeProposal].self, from: currentData)
            guard currentProposals.contains(proposal) else {
                throw ClaudeBridgeError.invalidSetting("Vorschlag wurde auf dem Relay geändert oder zurückgezogen")
            }
            change = try prepare(proposal)
            guard claudeChangesMatch(preview, change.lines) else {
                throw ClaudeBridgeError.invalidSetting("Einstellungen wurden während der Freigabe geändert; Vorschlag erneut prüfen")
            }
            // Reserve the proposal after local approval; cancellation can no longer race the commit.
            _ = try await request("/trio/proposals/\(proposal.id)/claim", method: "POST", body: [:], connection: reportConnection)
            change = try prepare(proposal)
            guard claudeChangesMatch(preview, change.lines) else {
                throw ClaudeBridgeError.invalidSetting("Einstellungen wurden während der Reservierung geändert; Vorschlag erneut prüfen")
            }
            // Fresh closures preserve unrelated settings changed while authentication was open.
            try await change.commit()
        } catch ClaudeBridgeError.authenticationFailed {
            lastError = ClaudeBridgeError.authenticationFailed.localizedDescription
            return false
        } catch {
            let message = error.localizedDescription
            log("⚠️ Fehler bei Vorschlag \(proposal.id): \(message)")
            _ = await report(proposal, status: "failed", message: message, connection: reportConnection)
            lastError = message
            return false
        }
        let summary = change.lines.map { "\($0.key): \($0.old) → \($0.new)" }.joined(separator: "; ")
        // The relay claim prevents a second application; a missing acknowledgement must not offer the action again.
        pending.removeAll { $0.id == proposal.id }
        guard await report(proposal, status: "applied", message: summary, connection: reportConnection) else {
            log(proposal.target == "relay_config"
                ? "⚠️ Relay-Änderung nicht bestätigt: \(lastError ?? "Verbindungsfehler")"
                : "⚠️ Lokal übernommen; Rückmeldung ausstehend: \(change.title)")
            return true
        }
        log("✅ \(change.title) übernommen – \(summary)")
        await sync()
        return true
    }

    func reject(_ proposal: ClaudeProposal, note: String = "") async {
        log("✋ Vorschlag \(proposal.id) abgelehnt")
        _ = await report(proposal, status: "rejected", message: note.isEmpty ? "Vom Nutzer abgelehnt" : note)
        await sync()
    }

    private func report(_ proposal: ClaudeProposal, status: String, message: String, connection: Connection? = nil) async -> Bool {
        do {
            _ = try await request(
                "/trio/proposals/\(proposal.id)/result",
                method: "POST",
                body: ["status": status, "message": message, "at": ISO8601DateFormatter().string(from: Date())],
                connection: connection
            )
            pending.removeAll { $0.id == proposal.id }
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    private func log(_ entry: String) {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        history.insert("\(formatter.string(from: Date())) \(entry)", at: 0)
        if history.count > 50 { history.removeLast() }
    }
}

// MARK: - Views

struct ClaudeBridgeView: View {
    @ObservedObject private var bridge = ClaudeBridgeService.shared

    @State private var url = ClaudeBridgeConfig.baseURL
    @State private var tokenInput = ""
    @State private var enabled = ClaudeBridgeConfig.enabled
    @State private var hasToken = ClaudeBridgeConfig.token != nil
    @State private var configurationError: String?

    var body: some View {
        Form {
            Section {
                ForEach(bridge.pending) { proposal in
                    NavigationLink(destination: ClaudeProposalDetailView(proposal: proposal)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ClaudeProposalDetailView.title(for: proposal.target)).bold()
                            if let reason = proposal.reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                if bridge.pending.isEmpty {
                    Text("Keine offenen Vorschläge").foregroundStyle(.secondary)
                }
            } header: {
                Text("KI-Vorschläge")
            } footer: {
                Text("Die KI kann Einstellungen vorschlagen. Jede Änderung wird erst nach deiner Prüfung und lokalen Freigabe übernommen.")
            }

            Section {
                Toggle("KI-Bridge aktiv", isOn: $enabled)
                    .onChange(of: enabled) { _, value in
                        ClaudeBridgeConfig.enabled = value
                        Task { await bridge.sync() }
                    }
                TextField("Server, z.B. http://192.168.1.20:8765", text: $url)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField(hasToken ? "Token gespeichert – neu eingeben zum Ändern" : "Token", text: $tokenInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Speichern & verbinden") {
                    if !tokenInput.isEmpty, !ClaudeBridgeConfig.setToken(tokenInput) {
                        configurationError = AIBridgeSetupError.keychain.localizedDescription
                        return
                    }
                    ClaudeBridgeConfig.baseURL = url
                    tokenInput = ""
                    hasToken = ClaudeBridgeConfig.token != nil
                    configurationError = nil
                    Task { await bridge.sync() }
                }
                if let configurationError { Text(configurationError).font(.caption).foregroundStyle(.red) }
                HStack {
                    Text("Status")
                    Spacer()
                    if bridge.isSyncing {
                        ProgressView()
                    } else if let error = bridge.lastError {
                        Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.trailing)
                    } else if let last = bridge.lastSync {
                        Text("Synchronisiert \(last.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
                    } else {
                        Text("Nicht verbunden").foregroundStyle(.secondary)
                    }
                }
                Button("Jetzt synchronisieren") { Task { await bridge.sync() } }
                    .disabled(!enabled)
            } header: {
                Text("Verbindung (trio-mcp)")
            } footer: {
                Text("Trio sendet Einstellungen, Status und den Verlauf der letzten 30 Tage (Glukose, Insulin, KH, Loop-Entscheidungen) an deinen trio-mcp-Server. Dort erstellt dein gewählter KI-Anbieter täglich eine Analyse.")
            }

            if !bridge.history.isEmpty {
                Section(header: Text("Verlauf")) {
                    ForEach(bridge.history, id: \.self) { entry in
                        Text(entry).font(.caption)
                    }
                }
            }
        }
        .navigationTitle("KI-Bridge")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refreshConfiguration)
        .onReceive(Foundation.NotificationCenter.default.publisher(for: .aiBridgeConfigurationChanged)) { _ in
            refreshConfiguration()
        }
    }

    private func refreshConfiguration() {
        url = ClaudeBridgeConfig.baseURL
        enabled = ClaudeBridgeConfig.enabled
        hasToken = ClaudeBridgeConfig.token != nil
        tokenInput = ""
        configurationError = nil
    }
}

struct ClaudeProposalDetailView: View {
    let proposal: ClaudeProposal

    @ObservedObject private var bridge = ClaudeBridgeService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var prepared: ClaudePreparedChange?
    @State private var prepareError: String?
    @State private var working = false

    static func title(for target: String) -> String {
        switch target {
        case "settings": return "Trio-Einstellungen"
        case "preferences": return "Algorithmus-Einstellungen (oref)"
        case "isf": return "Insulinempfindlichkeit (ISF)"
        case "carb_ratios": return "Kohlenhydrat-Faktor"
        case "bg_targets": return "Glukose-Zielbereich"
        case "basal_profile": return "Basalrate"
        case "pump_settings": return "Insulinwirkdauer und Abgabegrenzen"
        case "glucose_alerts": return "Glukose-Alarme"
        case "device_alerts": return "Geräte-Alarme"
        case "app_preferences": return "App-Darstellung und Dienste"
        case "ai_meal": return "KI-Mahlzeitenanbieter"
        case "bridge_config": return "KI-Bridge-Verbindung"
        case "nightscout": return "Nightscout-Verbindung"
        case "relay_config": return "Mac-Relay und Tagesanalyse"
        case "diagnostics": return "Diagnosedaten"
        case "cgm_simulator": return "CGM-Simulator"
        case "override_presets": return "Override-Vorlagen"
        case "temp_target_presets": return "Temporäre Zielwert-Vorlagen"
        case "meal_presets": return "Mahlzeiten-Vorlagen"
        default: return target
        }
    }

    var body: some View {
        Form {
            if let reason = proposal.reason {
                Section(header: Text("Begründung der KI")) { Text(reason) }
            }

            if let prepareError {
                Section { Text(prepareError).foregroundStyle(.red) }
            }
            if let prepared {
                Section {
                    ForEach(prepared.lines) { line in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(line.key).font(.subheadline).bold()
                            HStack {
                                Text(line.old).foregroundStyle(.secondary)
                                Image(systemName: "arrow.right")
                                Text(line.new).bold()
                            }
                            if let warning = line.warning {
                                Label(warning, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                    if prepared.lines.isEmpty { Text("Keine Unterschiede zum aktuellen Stand.") }
                } header: {
                    Text(prepared.title)
                } footer: {
                    Text("Bitte jede Änderung prüfen. Therapie-Einstellungen beeinflussen direkt die Insulinabgabe.")
                }

                Section {
                    Button {
                        working = true
                        Task {
                            let applied = await bridge.approve(proposal, preview: prepared.lines)
                            working = false
                            if applied { dismiss() }
                            else {
                                self.prepared = try? bridge.prepare(proposal)
                                prepareError = bridge.lastError
                            }
                        }
                    } label: {
                        Label("Freigeben (Face ID)", systemImage: "faceid").frame(maxWidth: .infinity)
                    }
                    .disabled(working)
                    Button(role: .destructive) {
                        working = true
                        Task {
                            await bridge.reject(proposal)
                            working = false
                            dismiss()
                        }
                    } label: {
                        Text("Ablehnen").frame(maxWidth: .infinity)
                    }
                    .disabled(working)
                }
            } else if let prepareError {
                Section(header: Text("Vorschlag kann nicht angewendet werden")) {
                    Text(prepareError).foregroundStyle(.red)
                    Button("Ablehnen und an KI melden", role: .destructive) {
                        Task {
                            await bridge.reject(proposal, note: prepareError)
                            dismiss()
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(Self.title(for: proposal.target))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            do {
                prepared = try bridge.prepare(proposal)
            } catch {
                prepareError = error.localizedDescription
            }
        }
    }
}
