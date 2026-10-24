import LocalAuthentication
import Testing
@testable import Trio

@Suite("Touch ID authorization") @MainActor struct UnlockManagerTests {
    @Test("Touch ID uses only biometrics and never reuses device unlock") func touchIDPolicy() async throws {
        let context = StubAuthenticationContext()
        context.localizedFallbackTitle = "Password"
        context.touchIDAuthenticationAllowableReuseDuration = 60

        let authenticated = try await DeviceOwnerAuthentication.authenticateWithTouchID("Synthetic action", context: context)

        #expect(authenticated)
        #expect(context.checkedPolicies == [.deviceOwnerAuthenticationWithBiometrics])
        #expect(context.evaluatedPolicies == [.deviceOwnerAuthenticationWithBiometrics])
        #expect(context.localizedFallbackTitle == "")
        #expect(context.touchIDAuthenticationAllowableReuseDuration == 0)
        #expect(context.didInvalidate)
    }

    @Test("Unavailable or locked biometry cannot reach policy evaluation") func unavailableTouchID() async {
        for code in [LAError.Code.biometryNotAvailable, .biometryNotEnrolled, .biometryLockout] {
            let context = StubAuthenticationContext()
            context.availabilityError = LAError(code)

            await #expect(throws: LAError.self) {
                try await DeviceOwnerAuthentication.authenticateWithTouchID("Synthetic action", context: context)
            }

            #expect(context.evaluatedPolicies.isEmpty)
            #expect(context.didInvalidate)
        }
    }

    @Test("Other biometric types cannot substitute for Touch ID") func rejectsOtherBiometry() async {
        for type in [LABiometryType.none, .faceID, .opticID] {
            let context = StubAuthenticationContext()
            context.availableBiometry = type

            await #expect(throws: LAError.self) {
                try await DeviceOwnerAuthentication.authenticateWithTouchID("Synthetic action", context: context)
            }

            #expect(context.evaluatedPolicies.isEmpty)
            #expect(context.didInvalidate)
        }
    }

    @Test("Decline, fallback and a false result never authorize the action") func rejectedEvaluation() async {
        for code in [LAError.Code.userCancel, .userFallback, .authenticationFailed] {
            let context = StubAuthenticationContext()
            context.evaluationError = LAError(code)

            await #expect(throws: LAError.self) {
                try await DeviceOwnerAuthentication.authenticateWithTouchID("Synthetic action", context: context)
            }

            #expect(context.evaluatedPolicies.count == 1)
            #expect(context.didInvalidate)
        }

        let context = StubAuthenticationContext()
        context.evaluationResult = false
        await #expect(throws: LAError.self) {
            try await DeviceOwnerAuthentication.authenticateWithTouchID("Synthetic action", context: context)
        }
        #expect(context.didInvalidate)
    }

    @Test("Bolus UI unlock is deferred only for Catalyst") func manualBolusEntry() async throws {
        let manager = StubUnlockManager()
        let permitted = try await manager.unlockForManualBolusEntry()
        #if targetEnvironment(macCatalyst)
            #expect(permitted)
            #expect(manager.calls == 0)
        #else
            #expect(!permitted)
            #expect(manager.calls == 1)
        #endif
    }
}

private final class StubUnlockManager: UnlockManager {
    var calls = 0

    func unlock() async throws -> Bool {
        calls += 1
        return false
    }
}

private final class StubAuthenticationContext: LAContext {
    var availableBiometry: LABiometryType = .touchID
    var availabilityError: LAError?
    var evaluationError: LAError?
    var evaluationResult = true
    var checkedPolicies: [LAPolicy] = []
    var evaluatedPolicies: [LAPolicy] = []
    var didInvalidate = false

    override var biometryType: LABiometryType { availableBiometry }

    override func canEvaluatePolicy(_ policy: LAPolicy, error: NSErrorPointer) -> Bool {
        checkedPolicies.append(policy)
        error?.pointee = availabilityError.map { $0 as NSError }
        return availabilityError == nil
    }

    override func evaluatePolicy(_ policy: LAPolicy, localizedReason _: String, reply: @escaping (Bool, Error?) -> Void) {
        evaluatedPolicies.append(policy)
        reply(evaluationResult && evaluationError == nil, evaluationError)
    }

    override func invalidate() {
        didInvalidate = true
    }
}
