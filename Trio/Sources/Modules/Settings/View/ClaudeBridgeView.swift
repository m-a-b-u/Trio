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

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Claude-Bridge ist nicht konfiguriert (URL/Token fehlen)."
        case .badURL: return "Ungültige Server-URL."
        case let .http(code, body): return "Server-Fehler \(code): \(body.prefix(200))"
        case let .unknownTarget(target): return "Unbekanntes Ziel: \(target)"
        case .emptyPatch: return "Der Vorschlag enthält keine Änderungen."
        case let .notApplied(key): return "„\(key)“ ist kein gültiger Einstellungsschlüssel oder der Wert ist ungültig."
        case let .invalidSchedule(message): return "Ungültiger Zeitplan: \(message)"
        case .noPump: return "Keine Pumpe verbunden – Basalrate kann nicht übertragen werden."
        case let .unsupportedBasalRate(rate): return "Basalrate \(rate) U/h wird von der Pumpe nicht unterstützt."
        case .authenticationFailed: return "Authentifizierung fehlgeschlagen."
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

    static func setToken(_ value: String?) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static var isConfigured: Bool { !baseURL.isEmpty && token != nil }
}

// MARK: - Helpers

private func claudeJSONString(_ value: Any?) -> String {
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

private func claudeValuesEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
    if let left = lhs as? NSNumber, let right = rhs as? NSNumber {
        return abs(left.doubleValue - right.doubleValue) < 1e-9
    }
    return claudeJSONString(lhs) == claudeJSONString(rhs)
}

private func claudeDictionary<T: Encodable>(_ value: T) throws -> [String: Any] {
    let data = try JSONCoding.encoder.encode(value)
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

private func claudeJSONObject<T: Encodable>(_ value: T) -> Any {
    guard let data = try? JSONCoding.encoder.encode(value),
          let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    else { return NSNull() }
    return object
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

private struct ClaudeScheduleItem {
    let minutes: Int
    let fields: [String: ClaudeJSONValue]
}

private func claudeParseSchedule(_ raw: [[String: ClaudeJSONValue]]?) throws -> [ClaudeScheduleItem] {
    guard let raw, !raw.isEmpty else { throw ClaudeBridgeError.invalidSchedule("leer") }
    var items: [ClaudeScheduleItem] = []
    for entry in raw {
        let minutes: Int
        if let time = entry["time"]?.stringValue ?? entry["start"]?.stringValue {
            let parts = time.split(separator: ":").compactMap { Int($0) }
            guard parts.count >= 2, (0 ..< 24).contains(parts[0]), (0 ..< 60).contains(parts[1]) else {
                throw ClaudeBridgeError.invalidSchedule("Zeit „\(time)“")
            }
            minutes = parts[0] * 60 + parts[1]
        } else if let offset = entry["minutes"]?.doubleValue ?? entry["offset"]?.doubleValue {
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

    private var settingsManager: SettingsManager? { resolver?.resolve(SettingsManager.self) }
    private var storage: FileStorage? { resolver?.resolve(FileStorage.self) }
    private var broadcaster: Broadcaster? { resolver?.resolve(Broadcaster.self) }
    private var deviceManager: DeviceDataManager? { resolver?.resolve(DeviceDataManager.self) }

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

    private func request(_ path: String, method: String = "GET", body: Any? = nil) async throws -> Data {
        guard let token = ClaudeBridgeConfig.token, !ClaudeBridgeConfig.baseURL.isEmpty else {
            throw ClaudeBridgeError.notConfigured
        }
        var base = ClaudeBridgeConfig.baseURL
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
            _ = try await request("/trio/state", method: "POST", body: snapshot())
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

    private func notifyAboutNew(_ proposals: [ClaudeProposal]) {
        let fresh = proposals.filter { !notifiedIDs.contains($0.id) }
        guard !fresh.isEmpty else { return }
        fresh.forEach { notifiedIDs.insert($0.id) }
        let content = UNMutableNotificationContent()
        content.title = "Claude schlägt eine Änderung vor"
        content.body = fresh.count == 1
            ? (fresh[0].reason ?? "Bitte in Trio prüfen und freigeben.")
            : "\(fresh.count) neue Vorschläge – bitte in Trio prüfen."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "claude.bridge.\(fresh[0].id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
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
        return result
    }

    // MARK: Prepare (preview) & apply

    func prepare(_ proposal: ClaudeProposal) throws -> ClaudePreparedChange {
        guard let settingsManager, let storage, let broadcaster else { throw ClaudeBridgeError.notConfigured }

        switch proposal.target {
        case "settings":
            let (newValue, lines) = try patched(settingsManager.settings, with: proposal.patch)
            return ClaudePreparedChange(proposal: proposal, title: "Trio-Einstellungen", lines: lines) {
                settingsManager.settings = newValue
            }

        case "preferences":
            let (newValue, lines) = try patched(settingsManager.preferences, with: proposal.patch)
            return ClaudePreparedChange(proposal: proposal, title: "Algorithmus-Einstellungen (oref)", lines: lines) {
                settingsManager.preferences = newValue
            }

        case "isf":
            let items = try claudeParseSchedule(proposal.schedule)
            let entries = try items.map { item in
                InsulinSensitivityEntry(
                    sensitivity: claudeDecimal(try claudeValue(item, ["value", "sensitivity", "isf"]), places: 1),
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
            }

        case "carb_ratios":
            let items = try claudeParseSchedule(proposal.schedule)
            let entries = try items.map { item in
                CarbRatioEntry(
                    start: claudeStartString(item.minutes),
                    offset: item.minutes,
                    ratio: claudeDecimal(try claudeValue(item, ["value", "ratio"]), places: 1)
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
            }

        case "bg_targets":
            let items = try claudeParseSchedule(proposal.schedule)
            let entries = try items.map { item -> BGTargetEntry in
                let low = try claudeValue(item, ["low", "value", "target"])
                let high = (try? claudeValue(item, ["high"])) ?? low
                guard high >= low else { throw ClaudeBridgeError.invalidSchedule("high < low") }
                return BGTargetEntry(
                    low: claudeDecimal(low, places: 0),
                    high: claudeDecimal(high, places: 0),
                    start: claudeStartString(item.minutes),
                    offset: item.minutes
                )
            }
            let old = storage.retrieve(OpenAPS.Settings.bgTargets, as: BGTargets.self)?
                .targets.map { ($0.offset, NSDecimalNumber(decimal: $0.low).doubleValue) } ?? []
            let new = entries.map { ($0.offset, NSDecimalNumber(decimal: $0.low).doubleValue) }
            let profile = BGTargets(units: .mgdL, userPreferredUnits: .mgdL, targets: entries)
            return ClaudePreparedChange(
                proposal: proposal,
                title: "Glukose-Zielbereich",
                lines: claudeScheduleDiff(old: old, new: new, unit: "mg/dL")
            ) {
                storage.save(profile, as: OpenAPS.Settings.bgTargets)
                broadcaster.notify(BGTargetsObserver.self, on: .main) {
                    $0.bgTargetsDidChange(profile)
                }
            }

        case "basal_profile":
            let items = try claudeParseSchedule(proposal.schedule)
            let supported = deviceManager?.pumpManager?.supportedBasalRates.filter { $0 > 0 } ?? []
            let entries = try items.map { item -> BasalProfileEntry in
                var rate = try claudeValue(item, ["value", "rate"])
                if !supported.isEmpty {
                    guard let match = supported.first(where: { abs($0 - rate) < 0.0005 }) else {
                        throw ClaudeBridgeError.unsupportedBasalRate(rate)
                    }
                    rate = match
                }
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
            }

        default:
            throw ClaudeBridgeError.unknownTarget(proposal.target)
        }
    }

    /// Applies a key/value patch to any Codable settings struct, validating that every key really took effect.
    private func patched<T: Codable>(_ value: T, with patch: [String: ClaudeJSONValue]?) throws -> (T, [ClaudeDiffLine]) {
        guard let patch, !patch.isEmpty else { throw ClaudeBridgeError.emptyPatch }
        var dict = try claudeDictionary(value)
        let oldDict = dict
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
        let context = LAContext()
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            guard ok else { throw ClaudeBridgeError.authenticationFailed }
        } catch {
            throw ClaudeBridgeError.authenticationFailed
        }
    }

    func approve(_ proposal: ClaudeProposal) async {
        do {
            let change = try prepare(proposal)
            try await authenticate("Änderung von Claude übernehmen: \(change.title)")
            try await change.commit()
            let summary = change.lines.map { "\($0.key): \($0.old) → \($0.new)" }.joined(separator: "; ")
            log("✅ \(change.title) übernommen – \(summary)")
            await report(proposal, status: "applied", message: summary)
        } catch ClaudeBridgeError.authenticationFailed {
            lastError = ClaudeBridgeError.authenticationFailed.localizedDescription
            return
        } catch {
            log("⚠️ Fehler bei Vorschlag \(proposal.id): \(error.localizedDescription)")
            await report(proposal, status: "failed", message: error.localizedDescription)
        }
        await sync()
    }

    func reject(_ proposal: ClaudeProposal, note: String = "") async {
        log("✋ Vorschlag \(proposal.id) abgelehnt")
        await report(proposal, status: "rejected", message: note.isEmpty ? "Vom Nutzer abgelehnt" : note)
        await sync()
    }

    private func report(_ proposal: ClaudeProposal, status: String, message: String) async {
        do {
            _ = try await request(
                "/trio/proposals/\(proposal.id)/result",
                method: "POST",
                body: ["status": status, "message": message, "at": ISO8601DateFormatter().string(from: Date())]
            )
            pending.removeAll { $0.id == proposal.id }
        } catch {
            lastError = error.localizedDescription
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
                Text("Vorschläge von Claude")
            } footer: {
                Text("Claude kann Einstellungen nur vorschlagen. Jede Änderung wird erst nach deiner Freigabe mit Face ID übernommen.")
            }

            Section {
                Toggle("Claude-Bridge aktiv", isOn: $enabled)
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
                    ClaudeBridgeConfig.baseURL = url
                    if !tokenInput.isEmpty { ClaudeBridgeConfig.setToken(tokenInput) }
                    tokenInput = ""
                    hasToken = ClaudeBridgeConfig.token != nil
                    Task { await bridge.sync() }
                }
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
                Text("Trio sendet Einstellungen, Glukose, IOB und COB an deinen trio-mcp-Server, damit Claude sie lesen kann.")
            }

            if !bridge.history.isEmpty {
                Section(header: Text("Verlauf")) {
                    ForEach(bridge.history, id: \.self) { entry in
                        Text(entry).font(.caption)
                    }
                }
            }
        }
        .navigationTitle("Claude")
        .navigationBarTitleDisplayMode(.inline)
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
        default: return target
        }
    }

    var body: some View {
        Form {
            if let reason = proposal.reason {
                Section(header: Text("Begründung von Claude")) { Text(reason) }
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
                            await bridge.approve(proposal)
                            working = false
                            dismiss()
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
                    Button("Ablehnen und an Claude melden", role: .destructive) {
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
