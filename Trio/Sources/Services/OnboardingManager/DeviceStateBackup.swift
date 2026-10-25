import Foundation
import UIKit

/// Copy of the files that make an installed Trio "set up": therapy settings, the paired pump and CGM,
/// and the onboarding flag. Deleting the app removes its container, but not its Keychain items,
/// so this copy lets a reinstalled Trio pick up where the old installation left off.
struct DeviceStateBackup: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    var createdAt: Date
    var appVersion: String
    /// Contents keyed by path relative to the Documents directory.
    var files: [String: Data]
    /// Allowlisted UserDefaults values, each serialized as its own property list.
    var defaults: [String: Data]

    var pumpManagerIdentifier: String? {
        managerIdentifier(in: DeviceStateBackupManager.pumpStateFile)
    }

    var cgmManagerIdentifier: String? {
        managerIdentifier(in: DeviceStateBackupManager.cgmStateFile)
    }

    var restoresSettings: Bool {
        files[OpenAPS.Settings.preferences] != nil || files[OpenAPS.Trio.settings] != nil
    }

    private func managerIdentifier(in file: String) -> String? {
        guard let data = files[file],
              let raw = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { return nil }
        return raw["managerIdentifier"] as? String
    }

    /// Everything except the creation metadata; equal fingerprints mean nothing worth saving changed.
    fileprivate var fingerprint: Data {
        struct Content: Encodable {
            let files: [String: Data]
            let defaults: [String: Data]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(Content(files: files, defaults: defaults))) ?? Data()
    }
}

protocol DeviceStateBackupStore {
    func load() throws -> Data?
    func save(_ data: Data) throws
}

/// Device-only, non-synchronizing Keychain item: a pod's session state must never reach another phone.
struct KeychainDeviceStateBackupStore: DeviceStateBackupStore {
    private static let key = "device-state-backup.v1"

    private let keychain = BaseKeychain(
        serviceName: (Bundle.main.bundleIdentifier ?? "Trio") + ".device-backup",
        synchronizable: false,
        accessibilityLevel: .afterFirstUnlockThisDeviceOnly
    )

    func load() throws -> Data? {
        try keychain.getData(forKey: Self.key).get()
    }

    func save(_ data: Data) throws {
        try keychain.setData(data, forKey: Self.key).get()
    }
}

/// Keeps a Keychain backup of Trio's setup current and restores it into a fresh installation.
///
/// A restore is a two-step process: the user confirms it while the fresh installation is already running,
/// which only records the decision. The files are written at the next launch, before the pump and CGM
/// managers read their state, so no running service can overwrite the restored files.
final class DeviceStateBackupManager {
    static let shared = DeviceStateBackupManager()

    static let pumpStateFile = "PumpManagerState.plist"
    static let cgmStateFile = "CGMManagerState.plist"
    static let onboardingFile = "onboardingCompleted.plist"
    static let pendingRestoreFile = "pendingDeviceStateRestore.plist"
    static let declinedRestoreFile = "declinedDeviceStateRestore.plist"

    static let backedUpFiles = [
        pumpStateFile,
        cgmStateFile,
        onboardingFile,
        "hasSeenFatProteinOrderChange.plist",
        "crashlyticsSharingEnabled.plist",
        "telemetrySharingEnabled.plist",
        OpenAPS.Settings.preferences,
        OpenAPS.Settings.settings,
        OpenAPS.Settings.bgTargets,
        OpenAPS.Settings.insulinSensitivities,
        OpenAPS.Settings.basalProfile,
        OpenAPS.Settings.carbRatios,
        OpenAPS.Settings.tempTargets,
        OpenAPS.Trio.settings,
        OpenAPS.Trio.tempTargetsPresets,
        OpenAPS.Trio.calibrations
    ]

    static let backedUpDefaultsKeys: Set<String> = [
        "BaseGarminManager.persistedDevices",
        "CalendarManager.currentCalendarID",
        "cgmSensorStateLog",
        "colorSchemePreference",
        "isTrioRemoteControlEnabled",
        "trioRemoteControlSharedSecret",
        "trio.glucoseAlerts.v1",
        "trio.glucoseAlertConfiguration.v1",
        "trio.deviceAlertSeverityConfigs.v1"
    ]

    static let backedUpDefaultsPrefixes = ["ai.", "claude."]

    private static let backupInterval: DispatchTimeInterval = .seconds(5 * 60)

    private let documentsURL: URL
    private let defaults: UserDefaults
    private let store: DeviceStateBackupStore
    private let appVersion: String
    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "DeviceStateBackupManager.queue", qos: .utility)

    private var lastSavedFingerprint: Data?
    private var timer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []

    init(
        documentsURL: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0],
        defaults: UserDefaults = .standard,
        store: DeviceStateBackupStore = KeychainDeviceStateBackupStore(),
        appVersion: String = "\(Bundle.main.appDevVersion ?? "unknown")(\(Bundle.main.buildVersionNumber ?? ""))"
    ) {
        self.documentsURL = documentsURL
        self.defaults = defaults
        self.store = store
        self.appVersion = appVersion
    }

    // MARK: - Backup

    /// Starts periodic backups and backs up whenever Trio leaves the foreground or finishes onboarding.
    func start() {
        guard timer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(30), repeating: Self.backupInterval, leeway: .seconds(30))
        timer.setEventHandler { [weak self] in self?.backupIfNeeded() }
        timer.resume()
        self.timer = timer

        for name in [UIApplication.didEnterBackgroundNotification, .onboardingCompleted] {
            observers.append(Foundation.NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.backupInBackground()
            })
        }
    }

    private func backupInBackground() {
        let task = UIApplication.shared.beginBackgroundTask(withName: "DeviceStateBackup")
        queue.async {
            self.backupIfNeeded()
            if task != .invalid {
                DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(task) }
            }
        }
    }

    /// Saves the current setup when it differs from the stored backup.
    ///
    /// Nothing is saved before onboarding is complete: a fresh installation must not replace
    /// the backup it may still be asked to restore.
    @discardableResult func backupIfNeeded(now: Date = Date()) -> Bool {
        guard isOnboardingCompleted(), !fileExists(Self.pendingRestoreFile) else { return false }

        let backup = makeBackup(now: now)
        let fingerprint = backup.fingerprint
        if lastSavedFingerprint == nil, let stored = try? loadBackup() {
            lastSavedFingerprint = stored.fingerprint
        }
        guard fingerprint != lastSavedFingerprint else { return false }

        do {
            try store.save(try PropertyListEncoder().encode(backup))
            lastSavedFingerprint = fingerprint
            debug(.storage, "Device state backup saved (\(backup.files.count) files)")
            return true
        } catch {
            warning(.storage, "Device state backup failed: \(error)")
            return false
        }
    }

    func makeBackup(now: Date = Date()) -> DeviceStateBackup {
        var files: [String: Data] = [:]
        for path in Self.backedUpFiles {
            if let data = try? Data(contentsOf: documentsURL.appendingPathComponent(path)) {
                files[path] = data
            }
        }

        var values: [String: Data] = [:]
        for (key, value) in defaults.dictionaryRepresentation() where Self.isBackedUpDefaultsKey(key) {
            if let data = try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0) {
                values[key] = data
            }
        }

        return DeviceStateBackup(
            version: DeviceStateBackup.currentVersion,
            createdAt: now,
            appVersion: appVersion,
            files: files,
            defaults: values
        )
    }

    private static func isBackedUpDefaultsKey(_ key: String) -> Bool {
        backedUpDefaultsKeys.contains(key) || backedUpDefaultsPrefixes.contains { key.hasPrefix($0) }
    }

    // MARK: - Restore

    /// The backup to offer, if this looks like a fresh installation that has not answered the offer yet.
    func restoreOffer() -> DeviceStateBackup? {
        guard !isOnboardingCompleted(),
              !fileExists(Self.declinedRestoreFile),
              !fileExists(Self.pendingRestoreFile),
              let backup = try? loadBackup(),
              backup.restoresSettings || backup.pumpManagerIdentifier != nil || backup.cgmManagerIdentifier != nil
        else { return nil }
        return backup
    }

    /// Records the user's confirmation; the files are written by `applyPendingRestoreIfNeeded()` at next launch.
    func scheduleRestore(includePumpState: Bool) throws {
        let marker = try PropertyListSerialization.data(
            fromPropertyList: ["includePumpState": includePumpState],
            format: .binary,
            options: 0
        )
        try marker.write(to: documentsURL.appendingPathComponent(Self.pendingRestoreFile), options: .atomic)
    }

    func declineRestore() {
        try? Data().write(to: documentsURL.appendingPathComponent(Self.declinedRestoreFile), options: .atomic)
    }

    /// Writes a confirmed backup into the container. Must run before any service reads its state.
    @discardableResult func applyPendingRestoreIfNeeded() -> Bool {
        let markerURL = documentsURL.appendingPathComponent(Self.pendingRestoreFile)
        guard let marker = try? Data(contentsOf: markerURL) else { return false }

        // Onboarding finished in the meantime: the user set Trio up by hand, keep that.
        guard !isOnboardingCompleted() else {
            try? fileManager.removeItem(at: markerURL)
            return false
        }

        let options = (try? PropertyListSerialization.propertyList(from: marker, options: [], format: nil)) as? [String: Any]
        let includePumpState = options?["includePumpState"] as? Bool ?? false

        // Keychain unavailable (e.g. launched before first unlock): keep the marker and retry next launch.
        guard let backup = try? loadBackup() else {
            warning(.storage, "Device state restore postponed: backup not readable")
            return false
        }

        do {
            for (path, data) in backup.files where Self.backedUpFiles.contains(path) {
                if path == Self.pumpStateFile, !includePumpState { continue }
                let url = documentsURL.appendingPathComponent(path)
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                if url.pathExtension == "plist" {
                    // Same protection as PersistedProperty, so background launches can read the state.
                    try? fileManager.setAttributes([.protectionKey: FileProtectionType.none], ofItemAtPath: url.path)
                }
            }
            for (key, data) in backup.defaults where Self.isBackedUpDefaultsKey(key) {
                if let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
                    defaults.set(value, forKey: key)
                }
            }
            try fileManager.removeItem(at: markerURL)
            debug(.storage, "Device state restored from backup of \(backup.createdAt) (pump state: \(includePumpState))")
            return true
        } catch {
            warning(.storage, "Device state restore failed: \(error)")
            return false
        }
    }

    // MARK: - Helpers

    private func loadBackup() throws -> DeviceStateBackup? {
        guard let data = try store.load() else { return nil }
        let backup = try PropertyListDecoder().decode(DeviceStateBackup.self, from: data)
        return backup.version <= DeviceStateBackup.currentVersion ? backup : nil
    }

    private func isOnboardingCompleted() -> Bool {
        guard let data = try? Data(contentsOf: documentsURL.appendingPathComponent(Self.onboardingFile)) else { return false }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? Bool ?? false
    }

    private func fileExists(_ path: String) -> Bool {
        fileManager.fileExists(atPath: documentsURL.appendingPathComponent(path).path)
    }
}
