import LocalAuthentication
import SwiftUI

/// An optional lock for the app: Face ID (or Touch ID, or the passcode) when it opens and after
/// it has been away for a little while. Saved logins, cards and keys never leave the server, so
/// the lock guards what is on screen, not a secret on the phone.
@MainActor
@Observable
final class AppLock {
    private(set) var isLocked = false
    /// True while the app is not frontmost, so the app switcher shows a blank card, not the page.
    private(set) var isShielded = false
    private(set) var failureMessage: String?

    @ObservationIgnored private var leftAt: Date?
    @ObservationIgnored private var isAuthenticating = false
    /// How long the app can be away before it asks again.
    @ObservationIgnored private let grace: TimeInterval = 30

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: PrefKey.biometricLock) }

    init() {
        isLocked = UserDefaults.standard.bool(forKey: PrefKey.biometricLock)
        // The widgets and the Keep intent read the shared copy; refresh it so an update never leaves it behind.
        SharedConfig.isLockOn = isLocked
    }

    /// The lock was turned on or off in Settings. Widgets, Spotlight and Siri cannot be put behind a prompt, so
    /// while the lock is on they hold nothing from the vault: what they showed is taken away now, and the
    /// widgets read the shared copy of the preference the next time they draw.
    func preferenceChanged(to on: Bool) {
        SharedConfig.isLockOn = on
        if on {
            SpotlightIndexer.clear()
            SharedConfig.forgetWidgetCache()
        }
        WidgetRefresh.reload()
    }

    /// "Face ID", "Touch ID" or "your passcode", for the words on screen.
    var methodName: String {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { return "your passcode" }
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "your passcode"
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        guard isEnabled else {
            isShielded = false
            return
        }
        switch phase {
        case .active:
            isShielded = false
            if let leftAt, Date().timeIntervalSince(leftAt) > grace { isLocked = true }
            leftAt = nil
        case .inactive:
            isShielded = true
        case .background:
            isShielded = true
            if leftAt == nil { leftAt = Date() }
        @unknown default:
            break
        }
    }

    /// Asks the system to confirm it is the owner. The passcode is the fallback, so nobody is locked out.
    func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        if await evaluate(reason: "Unlock HyperVault") {
            isLocked = false
            failureMessage = nil
        } else {
            let message = "That did not unlock. Try again."
            failureMessage = message
            AccessibilityNotification.Announcement(message).post()
        }
    }

    /// Turning the lock on or off asks once, so it cannot be switched on with no way back in.
    func confirmChange() async -> Bool {
        await evaluate(reason: "Confirm to change the lock")
    }

    private func evaluate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}

/// What covers the app while it is locked. It is also the only thing VoiceOver, Switch Control and a keyboard can
/// reach then: `RootView` hides and disables the app underneath.
struct LockScreen: View {
    let lock: AppLock

    var body: some View {
        ZStack {
            AuroraBackground()
            VStack(spacing: HV.Space.l) {
                BrandMark(size: 76)
                Text("HyperVault is locked").font(.hvTitle).accessibilityAddTraits(.isHeader)
                Text("Only you can open it.").font(.hvCallout).foregroundStyle(Palette.textSecondary)
                if let message = lock.failureMessage {
                    Text(message).font(.hvFootnote).foregroundStyle(Palette.danger)
                }
                Button {
                    Task { await lock.unlock() }
                } label: {
                    Label("Unlock with \(lock.methodName)", systemImage: "faceid")
                }
                .buttonStyle(.hvPrimary)
                .frame(maxWidth: 300)
            }
            .padding(HV.Space.xl)
        }
        .accessibilityAddTraits(.isModal)
        .task { await lock.unlock() }
        .onAppear { UIAccessibility.post(notification: .screenChanged, argument: nil) }
    }
}

/// A blank card for the app switcher.
struct PrivacyShield: View {
    var body: some View {
        ZStack {
            Palette.background
            BrandMark(size: 64)
        }
        .ignoresSafeArea()
    }
}
