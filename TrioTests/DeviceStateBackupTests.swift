import Foundation
import Security
import Testing
@testable import Trio

@Suite("Device state backup across reinstalls") struct DeviceStateBackupTests {
    private final class MemoryStore: DeviceStateBackupStore {
        var data: Data?
        var saves = 0
        var failLoad = false

        func load() throws -> Data? {
            if failLoad { throw KeychainError.darwinError(errSecInteractionNotAllowed) }
            return data
        }

        func save(_ data: Data) throws {
            self.data = data
            saves += 1
        }
    }

    private struct Container {
        let url: URL
        let defaults: UserDefaults
        let manager: DeviceStateBackupManager

        func write(_ path: String, _ data: Data) throws {
            let file = url.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }

        func read(_ path: String) -> Data? {
            try? Data(contentsOf: url.appendingPathComponent(path))
        }

        func exists(_ path: String) -> Bool {
            FileManager.default.fileExists(atPath: url.appendingPathComponent(path).path)
        }
    }

    /// A fresh app container sharing the Keychain store, as after deleting and reinstalling Trio.
    private func container(store: MemoryStore) throws -> Container {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DeviceStateBackupTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let suite = "DeviceStateBackupTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let manager = DeviceStateBackupManager(documentsURL: url, defaults: defaults, store: store, appVersion: "test(1)")
        return Container(url: url, defaults: defaults, manager: manager)
    }

    private func plist(_ value: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }

    /// Binary plists of dictionaries need not be byte-identical across serializations; compare contents.
    private func samePlist(_ lhs: Data?, _ rhs: Data) -> Bool {
        guard let lhs,
              let left = try? PropertyListSerialization.propertyList(from: lhs, options: [], format: nil) as? NSDictionary,
              let right = try? PropertyListSerialization.propertyList(from: rhs, options: [], format: nil) as? NSDictionary
        else { return false }
        return left.isEqual(right)
    }

    private func pumpState() throws -> Data {
        try plist(["managerIdentifier": "Omnipod-Dash", "state": ["podState": "synthetic"]])
    }

    private func cgmState() throws -> Data {
        try plist(["managerIdentifier": "G7CGMManager", "state": ["sensorID": "synthetic"]])
    }

    /// An installation that finished onboarding with a paired pump and CGM.
    private func setUpInstallation(_ old: Container) throws {
        try old.write(DeviceStateBackupManager.onboardingFile, plist(true))
        try old.write(DeviceStateBackupManager.pumpStateFile, pumpState())
        try old.write(DeviceStateBackupManager.cgmStateFile, cgmState())
        try old.write(OpenAPS.Settings.preferences, Data(#"{"maxIOB":3}"#.utf8))
        try old.write(OpenAPS.Settings.basalProfile, Data(#"[{"rate":0.8}]"#.utf8))
        try old.write(OpenAPS.Trio.settings, Data(#"{"units":"mg/dL"}"#.utf8))
        try old.write(OpenAPS.Settings.profile, Data(#"{"generated":true}"#.utf8))
        old.defaults.set("anthropic", forKey: "ai.meal.provider")
        old.defaults.set(true, forKey: "isTrioRemoteControlEnabled")
        old.defaults.set(Date(), forKey: "lastLoopDate")
    }

    @Test("Backup captures setup files and allowlisted defaults only") func backupContents() throws {
        let store = MemoryStore()
        let old = try container(store: store)
        try setUpInstallation(old)

        let backup = old.manager.makeBackup()
        #expect(samePlist(backup.files[DeviceStateBackupManager.pumpStateFile], try pumpState()))
        #expect(backup.files[OpenAPS.Settings.basalProfile] != nil)
        #expect(backup.files[OpenAPS.Settings.profile] == nil)
        #expect(backup.defaults["ai.meal.provider"] != nil)
        #expect(backup.defaults["isTrioRemoteControlEnabled"] != nil)
        #expect(backup.defaults["lastLoopDate"] == nil)
        #expect(backup.pumpManagerIdentifier == "Omnipod-Dash")
        #expect(backup.cgmManagerIdentifier == "G7CGMManager")
    }

    @Test("Backups are written only after onboarding and only when something changed") func backupTiming() throws {
        let store = MemoryStore()
        let fresh = try container(store: store)
        try fresh.write(OpenAPS.Settings.preferences, Data("{}".utf8))
        #expect(!fresh.manager.backupIfNeeded())
        #expect(store.saves == 0)

        try setUpInstallation(fresh)
        #expect(fresh.manager.backupIfNeeded())
        #expect(!fresh.manager.backupIfNeeded())
        try fresh.write(DeviceStateBackupManager.pumpStateFile, plist(["managerIdentifier": "Omnipod-Dash", "state": ["n": 2]]))
        #expect(fresh.manager.backupIfNeeded())
        #expect(store.saves == 2)

        // A new process compares against the stored backup instead of rewriting it.
        let relaunched = DeviceStateBackupManager(
            documentsURL: fresh.url,
            defaults: fresh.defaults,
            store: store,
            appVersion: "test(2)"
        )
        #expect(!relaunched.backupIfNeeded())
        #expect(store.saves == 2)
    }

    @Test("Reinstall restores settings, CGM and pump after confirmation and next launch") func fullRestore() throws {
        let store = MemoryStore()
        let old = try container(store: store)
        try setUpInstallation(old)
        #expect(old.manager.backupIfNeeded())

        let reinstalled = try container(store: store)
        // A fresh launch already wrote defaults before the user answered.
        try reinstalled.write(OpenAPS.Settings.preferences, Data("{}".utf8))
        let offer = try #require(reinstalled.manager.restoreOffer())
        #expect(offer.pumpManagerIdentifier == "Omnipod-Dash")
        #expect(!reinstalled.manager.backupIfNeeded())

        try reinstalled.manager.scheduleRestore(includePumpState: true)
        #expect(reinstalled.manager.restoreOffer() == nil)

        let nextLaunch = DeviceStateBackupManager(documentsURL: reinstalled.url, defaults: reinstalled.defaults, store: store)
        #expect(nextLaunch.applyPendingRestoreIfNeeded())
        #expect(samePlist(reinstalled.read(DeviceStateBackupManager.pumpStateFile), try pumpState()))
        #expect(samePlist(reinstalled.read(DeviceStateBackupManager.cgmStateFile), try cgmState()))
        #expect(reinstalled.read(OpenAPS.Settings.preferences) == Data(#"{"maxIOB":3}"#.utf8))
        #expect(reinstalled.read(OpenAPS.Settings.basalProfile) == Data(#"[{"rate":0.8}]"#.utf8))
        #expect(reinstalled.exists(DeviceStateBackupManager.onboardingFile))
        #expect(!reinstalled.exists(DeviceStateBackupManager.pendingRestoreFile))
        #expect(reinstalled.defaults.string(forKey: "ai.meal.provider") == "anthropic")
        #expect(reinstalled.defaults.bool(forKey: "isTrioRemoteControlEnabled"))
        #expect(!nextLaunch.applyPendingRestoreIfNeeded())
    }

    @Test("Pump state can be left out of the restore") func restoreWithoutPump() throws {
        let store = MemoryStore()
        let old = try container(store: store)
        try setUpInstallation(old)
        old.manager.backupIfNeeded()

        let reinstalled = try container(store: store)
        try reinstalled.manager.scheduleRestore(includePumpState: false)
        #expect(reinstalled.manager.applyPendingRestoreIfNeeded())
        #expect(!reinstalled.exists(DeviceStateBackupManager.pumpStateFile))
        #expect(samePlist(reinstalled.read(DeviceStateBackupManager.cgmStateFile), try cgmState()))
    }

    @Test("Declining keeps the backup until a completed setup replaces it") func decline() throws {
        let store = MemoryStore()
        let old = try container(store: store)
        try setUpInstallation(old)
        old.manager.backupIfNeeded()

        let reinstalled = try container(store: store)
        reinstalled.manager.declineRestore()
        #expect(reinstalled.manager.restoreOffer() == nil)
        let stored = try PropertyListDecoder().decode(DeviceStateBackup.self, from: try #require(store.data))
        #expect(stored.pumpManagerIdentifier != nil)
    }

    @Test("No offer for set-up installations, missing backups or an unreadable Keychain") func noOffer() throws {
        let store = MemoryStore()
        let fresh = try container(store: store)
        #expect(fresh.manager.restoreOffer() == nil)

        let old = try container(store: store)
        try setUpInstallation(old)
        old.manager.backupIfNeeded()
        #expect(old.manager.restoreOffer() == nil)

        store.failLoad = true
        #expect(fresh.manager.restoreOffer() == nil)
    }

    @Test("Pending restore waits for a readable Keychain and never overrides a manual setup") func pendingRestoreGuards() throws {
        let store = MemoryStore()
        let old = try container(store: store)
        try setUpInstallation(old)
        old.manager.backupIfNeeded()

        let reinstalled = try container(store: store)
        try reinstalled.manager.scheduleRestore(includePumpState: true)
        store.failLoad = true
        #expect(!reinstalled.manager.applyPendingRestoreIfNeeded())
        #expect(reinstalled.exists(DeviceStateBackupManager.pendingRestoreFile))

        store.failLoad = false
        try reinstalled.write(DeviceStateBackupManager.onboardingFile, plist(true))
        #expect(!reinstalled.manager.applyPendingRestoreIfNeeded())
        #expect(!reinstalled.exists(DeviceStateBackupManager.pendingRestoreFile))
        #expect(!reinstalled.exists(DeviceStateBackupManager.pumpStateFile))
    }
}
