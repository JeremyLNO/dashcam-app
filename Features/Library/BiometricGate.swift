import LocalAuthentication
import SwiftUI

/// Face ID / Touch ID in front of the video library.
///
/// Optional and off by default — a lock the driver did not ask for is a lock between them
/// and their own evidence. When it is on, it guards the library only: recording, stopping
/// and protecting all stay reachable without authenticating, because those are the things
/// someone may need to do in a hurry.
@MainActor
final class BiometricGate: ObservableObject {
    @Published private(set) var isUnlocked = false
    @Published private(set) var lastError: String?

    /// Nil when the device has no biometry enrolled, in which case the setting is hidden
    /// rather than offered and then failing.
    var availableBiometry: LABiometryType? {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return nil }
        return context.biometryType == .none ? nil : context.biometryType
    }

    var isAvailable: Bool { availableBiometry != nil }

    func reset() {
        isUnlocked = false
        lastError = nil
    }

    func unlock() async {
        let context = LAContext()
        context.localizedCancelTitle = L10n.t("common.cancel")

        var error: NSError?
        // `.deviceOwnerAuthentication`, not `...WithBiometrics`: falling back to the
        // passcode is what stops a failed Face ID from locking someone out of their own
        // footage after an accident.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            isUnlocked = true   // nothing to authenticate against; do not lock the user out
            return
        }

        do {
            isUnlocked = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: L10n.t("biometric.reason")
            )
            lastError = nil
        } catch {
            isUnlocked = false
            lastError = error.localizedDescription
        }
    }
}

/// The screen shown instead of the library while it is locked.
struct BiometricLockView: View {
    let onUnlock: () -> Void
    var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(Theme.accent)
            Text(key: "biometric.locked.title")
                .font(Theme.headline)
                .foregroundStyle(Theme.textPrimary)
            Text(key: "biometric.locked.subtitle")
                .font(Theme.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 40)

            Button(action: onUnlock) {
                Text(key: "biometric.unlock")
            }
            .buttonStyle(DriverButtonStyle(fill: Theme.accent))
            .padding(.horizontal, 40)
            .padding(.top, 6)
            .accessibilityIdentifier("unlockLibrary")

            if let errorMessage {
                Text(verbatim: errorMessage)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}
