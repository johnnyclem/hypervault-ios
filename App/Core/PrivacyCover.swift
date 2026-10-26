import SwiftUI
import UIKit

/// What stands between the screen and the app right now.
enum PrivacyCover: Equatable {
    case none
    /// The app is not frontmost: a blank card for the app switcher.
    case shield
    /// Face ID is asked for before anything shows.
    case lock
}

extension AppLock {
    /// The lock wins over the shield: the Face ID prompt itself takes the app out of the foreground, and the lock
    /// screen must not be swapped for a blank card while it is up.
    var cover: PrivacyCover {
        if isLocked { return .lock }
        return isShielded ? .shield : .none
    }
}

/// What the cover window draws. It is a hierarchy of its own, so it takes the person's look and accent from their
/// preferences the way the app's root does.
struct PrivacyCoverView: View {
    let cover: PrivacyCover
    let lock: AppLock

    @AppStorage(PrefKey.appearance) private var appearance = AppearanceChoice.system
    @AppStorage(PrefKey.accent) private var accent = AccentChoice.blue

    var body: some View {
        Group {
            switch cover {
            case .lock: LockScreen(lock: lock)
            case .shield: PrivacyShield()
            case .none: Color.clear
            }
        }
        .tint(accent.color)
        .preferredColorScheme(appearance.colorScheme)
    }
}

/// Where a cover goes up. The window system is behind this so what decides when to cover can be tried without one.
@MainActor
protocol CoverPresenting: AnyObject {
    /// Puts the cover up, changes it, or (for `.none`) takes it down. False when there is no scene to put it in yet,
    /// so the caller asks again.
    func present(_ cover: PrivacyCover) -> Bool
}

/// Keeps the cover in step with the lock.
///
/// A sheet is presented by UIKit above everything in the SwiftUI hierarchy, so a lock screen or a shield drawn inside
/// that hierarchy sits under it: the one-time key or the card number in a form stays readable over the lock and in the
/// app switcher. The cover therefore goes in a window of its own, above every presentation, and only while it is
/// needed. Nothing is dismissed: a shield is up for a moment whenever Control Center is pulled down, and a sheet that
/// shows a key once cannot be brought back.
@MainActor
final class PrivacyCoverController {
    private let lock: AppLock
    private let presenter: CoverPresenting
    private var following = false
    /// What the presenter was last asked for and agreed to. It stays behind when there was no scene to put the cover in,
    /// so the next `sync()` tries again.
    private(set) var shown: PrivacyCover = .none

    init(lock: AppLock, presenter: CoverPresenting) {
        self.lock = lock
        self.presenter = presenter
    }

    /// Starts following the lock, and puts up whatever it already calls for (the lock is on from launch).
    func start() {
        guard !following else { return }
        following = true
        NotificationCenter.default.addObserver(forName: UIScene.willDeactivateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sceneWillDeactivate() }
        }
        follow()
        sync()
    }

    /// The scene is about to stop being frontmost. The app switcher's picture is taken after this, so the shield goes up
    /// now and not once SwiftUI has passed the news on.
    func sceneWillDeactivate() {
        lock.scenePhaseChanged(.inactive)
        sync()
    }

    func sync() {
        let wanted = lock.cover
        guard wanted != shown else { return }
        if presenter.present(wanted) { shown = wanted }
    }

    private func follow() {
        withObservationTracking {
            _ = lock.cover
        } onChange: { [weak self] in
            // Called just before the change lands; the change is there once this task runs.
            Task { @MainActor in
                self?.sync()
                self?.follow()
            }
        }
    }
}

/// Puts the cover in a window of its own, in the app's scene, above every presentation and alert. The window exists only
/// while there is something to cover.
@MainActor
final class SceneCoverPresenter: CoverPresenting {
    /// Above the alert level, where an alert's own window and every sheet sit below.
    static let level = UIWindow.Level.alert + 1

    private let lock: AppLock
    private(set) var window: UIWindow?
    private var host: UIHostingController<PrivacyCoverView>?
    private var current: PrivacyCover = .none
    /// The windows VoiceOver could reach before the lock hid them, and whether each one was already hidden.
    private var covered: [(window: UIWindow, wasHidden: Bool)] = []
    private weak var keyBeforeLock: UIWindow?
    /// Counts takedowns, so a fade that a new cover has interrupted does not remove the window.
    private var generation = 0
    /// The lock gives way with a short fade unless the person asked for less motion.
    var fades = true

    init(lock: AppLock) {
        self.lock = lock
    }

    func present(_ cover: PrivacyCover) -> Bool {
        guard cover != .none else {
            takeDown()
            return true
        }
        guard let scene = window?.windowScene ?? Self.scene() else { return false }
        generation += 1
        let window = self.window ?? makeWindow(for: cover, in: scene)
        window.layer.removeAllAnimations()
        window.alpha = 1
        host?.rootView = PrivacyCoverView(cover: cover, lock: lock)

        let locking = cover == .lock
        // The shield is for the eye and is not interactive; the lock is the one thing the person can reach.
        window.isUserInteractionEnabled = locking
        host?.view.accessibilityViewIsModal = locking
        host?.view.accessibilityElementsHidden = !locking

        if locking, current != .lock {
            takeOver(from: scene, with: window)
        } else if !locking, current == .lock {
            giveBack()
        }
        window.isHidden = false
        current = cover
        return true
    }

    private func makeWindow(for cover: PrivacyCover, in scene: UIWindowScene) -> UIWindow {
        let host = UIHostingController(rootView: PrivacyCoverView(cover: cover, lock: lock))
        host.view.backgroundColor = .clear
        let window = UIWindow(windowScene: scene)
        window.windowLevel = Self.level
        window.rootViewController = host
        self.host = host
        self.window = window
        return window
    }

    /// The lock goes up. Whatever is being typed is put away first (the keyboard has a window of its own, above this
    /// one), the rest of the app is taken out of reach of VoiceOver, sheets included, since they live in the app's window,
    /// and the lock takes the keyboard's focus so keys and Switch Control reach it and not what is behind.
    private func takeOver(from scene: UIWindowScene, with cover: UIWindow) {
        let others = scene.windows.filter { $0 !== cover }
        for other in others { other.endEditing(true) }
        covered = others.map { (window: $0, wasHidden: $0.accessibilityElementsHidden) }
        for other in others { other.accessibilityElementsHidden = true }
        keyBeforeLock = scene.keyWindow
        cover.makeKeyAndVisible()
    }

    /// The lock comes down: the app is reachable again, and VoiceOver is told the screen has changed.
    private func giveBack() {
        for (other, wasHidden) in covered { other.accessibilityElementsHidden = wasHidden }
        covered = []
        keyBeforeLock?.makeKey()
        keyBeforeLock = nil
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }

    private func takeDown() {
        guard let window else { return }
        if current == .lock { giveBack() }
        current = .none
        generation += 1
        window.isUserInteractionEnabled = false
        let mine = generation
        if fades, !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.2, animations: { window.alpha = 0 }, completion: { [weak self] _ in
                MainActor.assumeIsolated { self?.finishTakeDown(of: window, generation: mine) }
            })
        } else {
            finishTakeDown(of: window, generation: mine)
        }
    }

    private func finishTakeDown(of window: UIWindow, generation mine: Int) {
        guard generation == mine, self.window === window else { return }
        window.isHidden = true
        window.rootViewController = nil
        self.window = nil
        host = nil
    }

    private static func scene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
            ?? scenes.first
    }
}
