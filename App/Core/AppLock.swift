import LocalAuthentication
import SwiftUI

/// An optional lock for the app: Face ID (or Touch ID, or the passcode) when it opens and after
/// it has been away for a little while. It gates what is on screen and nothing else: the device passcode
/// opens it too, and it encrypts nothing on the phone.
///
/// The cover that blanks the app switcher is not the lock's alone. A screen that shows or takes a value
/// (`hvSensitive()`) asks for the cover while it is up, and gets it with the lock off.
@MainActor
@Observable
final class AppLock {
    private(set) var isLocked = false
    /// True while the app is not frontmost, so the app switcher shows a blank card, not the page.
    private(set) var isShielded = false
    private(set) var failureMessage: String?

    @ObservationIgnored private var leftAt: Date?
    @ObservationIgnored private var isAuthenticating = false
    /// The sensitive screens that are up, each by a token of its own, so one that reports twice still counts once.
    @ObservationIgnored private var sensitiveScreens: Set<UUID> = []
    /// How long the app can be away before it asks again.
    @ObservationIgnored private let grace: TimeInterval

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: PrefKey.biometricLock) }

    init(grace: TimeInterval = 30) {
        self.grace = grace
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

    /// How many sensitive screens are up.
    var sensitiveScreenCount: Int { sensitiveScreens.count }

    /// A screen that shows or takes a value has come up. While any is, the app switcher gets the cover, lock or no lock.
    func beginSensitive(_ screen: UUID) {
        sensitiveScreens.insert(screen)
    }

    /// That screen has gone. Once none is left and the lock is off, nothing calls for the cover any more.
    func endSensitive(_ screen: UUID) {
        sensitiveScreens.remove(screen)
        if sensitiveScreens.isEmpty, !isEnabled { isShielded = false }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        let locking = isEnabled
        guard locking || !sensitiveScreens.isEmpty else {
            isShielded = false
            return
        }
        switch phase {
        case .active:
            isShielded = false
            // Only the lock locks. A sensitive screen with the lock off puts the cover up and nothing more.
            if locking, let leftAt, Date().timeIntervalSince(leftAt) > grace { isLocked = true }
            leftAt = nil
        case .inactive:
            isShielded = true
        case .background:
            isShielded = true
            if locking, leftAt == nil { leftAt = Date() }
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

/// What covers the app while it is locked. It is drawn in a window of its own above every sheet (see
/// `PrivacyCoverController`), and it is the only thing VoiceOver, Switch Control and a keyboard can reach then: the
/// window takes the keyboard's focus and hides the app's windows from VoiceOver, and `RootView` also hides and disables
/// the app underneath.
struct LockScreen: View {
    let lock: AppLock
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ZStack {
            AuroraBackground()
            // Centred when it fits, and scrolls when the text is large enough that it does not: the way back in must
            // never be pushed off the screen.
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: HV.Space.l) {
                        BrandMark(size: 76)
                        Text("HyperVault is locked").font(.hvTitle).multilineTextAlignment(.center).accessibilityAddTraits(.isHeader)
                        Text("Unlock to continue.").font(.hvCallout).foregroundStyle(Palette.textSecondary).multilineTextAlignment(.center)
                        if let message = lock.failureMessage {
                            Text(message).font(.hvFootnote).foregroundStyle(Palette.danger).multilineTextAlignment(.center)
                        }
                        Button {
                            Task { await lock.unlock() }
                        } label: {
                            Label("Unlock with \(lock.methodName)", systemImage: "faceid")
                        }
                        .buttonStyle(.hvPrimary)
                        // At the largest text the words need the whole width, or they wrap one to a line.
                        .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : 300)
                    }
                    .padding(HV.Space.xl)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .accessibilityAddTraits(.isModal)
        .task { await lock.unlock() }
        .onAppear { UIAccessibility.post(notification: .screenChanged, argument: nil) }
    }
}

/// A blank card for the app switcher. It is for the eye only: nothing on it is for VoiceOver.
struct PrivacyShield: View {
    var body: some View {
        ZStack {
            Palette.background
            BrandMark(size: 64)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
