import Foundation
import LocalAuthentication

/// Optional Face ID / Touch ID gate in front of private records.
@MainActor
@Observable
final class BiometricLock {
    private(set) var isUnlocked: Bool
    private(set) var lastError: String?

    /// When false the app is always unlocked (the user hasn't opted in).
    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.defaultsKey)
            if !isEnabled { isUnlocked = true }
        }
    }

    private static let defaultsKey = "ataru.applock.enabled"

    init() {
        let enabled = UserDefaults.standard.bool(forKey: Self.defaultsKey)
        self.isEnabled = enabled
        self.isUnlocked = !enabled
    }

    /// True when the device can actually evaluate biometrics or a passcode.
    var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    var biometryLabel: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return "Device passcode"
        }
    }

    func lock() {
        guard isEnabled else { return }
        isUnlocked = false
    }

    func authenticate() async {
        guard isEnabled else { isUnlocked = true; return }
        let context = LAContext()
        context.localizedFallbackTitle = "Use passcode"
        do {
            let ok = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock ATARU to view your private records."
            )
            isUnlocked = ok
            lastError = ok ? nil : "Authentication was not completed."
        } catch {
            isUnlocked = false
            lastError = SecretRedactor.redact(error)
        }
    }
}
