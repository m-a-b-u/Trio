import Combine
import LocalAuthentication

protocol UnlockManager {
    func unlock() async throws -> Bool
}

extension UnlockManager {
    /// Mac bolus authentication happens in APSManager immediately before fresh pump checks.
    /// This only skips the earlier UI prompt; it does not grant or cache authorization.
    func unlockForManualBolusEntry() async throws -> Bool {
        #if targetEnvironment(macCatalyst)
            return true
        #else
            return try await unlock()
        #endif
    }
}

enum DeviceOwnerAuthentication {
    @MainActor static func authenticate(_ reason: String) async throws -> Bool {
        #if targetEnvironment(macCatalyst)
            return try await authenticateWithTouchID(reason)
        #else
            return try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        #endif
    }

    @MainActor static func authenticateWithTouchID(_ reason: String, context: LAContext = LAContext()) async throws -> Bool {
        // Every action gets a fresh context, with no password/Watch fallback or device-unlock reuse.
        context.localizedFallbackTitle = ""
        context.touchIDAuthenticationAllowableReuseDuration = 0
        defer { context.invalidate() }

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw error ?? LAError(.biometryNotAvailable)
        }
        guard context.biometryType == .touchID else { throw LAError(.biometryNotAvailable) }
        let authenticated = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
        guard authenticated else { throw LAError(.authenticationFailed) }
        return true
    }
}

final class BaseUnlockManager: UnlockManager {
    @MainActor func unlock() async throws -> Bool {
        let reason = "We need to make sure you are the owner of the device."
        _ = try await DeviceOwnerAuthentication.authenticate(reason)
        return true
    }
}
