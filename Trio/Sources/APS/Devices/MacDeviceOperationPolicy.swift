import Foundation

/// Temporary build-time boundary until the standalone Mac controller is validated.
enum MacDeviceOperationPolicy {
    static var isRestrictedBuild: Bool {
        #if targetEnvironment(macCatalyst)
            return true
        #else
            return false
        #endif
    }

    static let title = "Mac-Port: Gerätebetrieb noch nicht freigegeben"
    static let explanation = "Die aktive G7-Kopplung, Touch ID für alle kritischen Einstellungen und die sichere Controller-Übergabe sind noch nicht abgenommen. Dieser Entwicklungsstand erlaubt nur Simulatoren. Beim Blockieren bleiben gespeicherte Gerätekonfigurationen erhalten."

    static func permitsPump(identifier: String?) -> Bool {
        !isRestrictedBuild || identifier == "MockPumpManager"
    }

    static func permitsPumpRestore(_ rawValue: [String: Any]?) -> Bool {
        guard let rawValue else { return true }
        return permitsPump(identifier: rawValue["managerIdentifier"] as? String)
    }

    static func permitsGlucoseSource(_ source: String) -> Bool {
        !isRestrictedBuild || source == "none" || source == "simulator"
    }
}
