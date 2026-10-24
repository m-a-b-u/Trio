import Foundation
import MockKit
import Testing
@testable import Trio

@Suite("Mac device operation boundary") struct MacDeviceOperationPolicyTests {
    @Test("The build boundary cannot be enabled through a runtime preference")
    func compiledBoundary() {
        #if targetEnvironment(macCatalyst)
            #expect(MacDeviceOperationPolicy.isRestrictedBuild)
        #else
            #expect(!MacDeviceOperationPolicy.isRestrictedBuild)
        #endif
        #expect(MacDeviceOperationPolicy.permitsPump(identifier: MockPumpManager.pluginIdentifier))
        #expect(MacDeviceOperationPolicy.permitsGlucoseSource(CGMType.none.rawValue))
        #expect(MacDeviceOperationPolicy.permitsGlucoseSource(CGMType.simulator.rawValue))
    }

    @Test("Hardware and unknown restore identifiers fail closed only on Catalyst")
    func persistedPumpBoundary() {
        for identifier in ["Omnipod", "Omnipod-DASH", "Minimed500", "Dana", "Medtrum", "Unknown", ""] {
            let state: [String: Any] = ["managerIdentifier": identifier, "state": ["synthetic": "preserve"]]
            #expect(MacDeviceOperationPolicy.permitsPumpRestore(state) == !MacDeviceOperationPolicy.isRestrictedBuild)
        }
        #expect(MacDeviceOperationPolicy.permitsPumpRestore(["state": [:]]) == !MacDeviceOperationPolicy.isRestrictedBuild)
        #expect(MacDeviceOperationPolicy.permitsPumpRestore(nil))
        #expect(MacDeviceOperationPolicy.permitsPumpRestore([
            "managerIdentifier": MockPumpManager.pluginIdentifier, "state": [:]
        ]))
    }

    @Test("Mac exposes only simulated data sources and has a usable simulator onboarding entry")
    func catalogBoundary() {
        for source in [CGMType.plugin, .nightscout, .xdrip] {
            #expect(MacDeviceOperationPolicy.permitsGlucoseSource(source.rawValue) == !MacDeviceOperationPolicy.isRestrictedBuild)
        }
        #if targetEnvironment(macCatalyst)
            #expect(DeviceCatalog.pumps.map(\.id) == [MockPumpManager.pluginIdentifier])
            #expect(Set(DeviceCatalog.cgms.map(\.cgmType)) == [.none, .simulator])
            #expect(DeviceCatalog.cgmManagerEntries.isEmpty)
            #expect(DeviceCatalog.onboardingPumps.map(\.id) == [MockPumpManager.pluginIdentifier])
            #expect(DeviceCatalog.defaultOnboardingPump.id == MockPumpManager.pluginIdentifier)
            #expect(DeviceCatalog.pumpEntry(forPersistedIdentifier: "Omnipod-DASH") == nil)
        #else
            #expect(DeviceCatalog.pumpEntry(forPersistedIdentifier: "Omnipod-DASH") != nil)
            #expect(!DeviceCatalog.cgmManagerEntries.isEmpty)
            #expect(!DeviceCatalog.onboardingPumps.contains { $0.id == MockPumpManager.pluginIdentifier })
        #endif
    }
}
