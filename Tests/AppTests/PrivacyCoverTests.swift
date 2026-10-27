import SwiftUI
import UIKit
import XCTest
@testable import HyperVault

/// The Face ID lock and the app-switcher shield live in a window of their own, above every sheet. These try what
/// decides when that window is up, and then the window itself.
@MainActor
final class PrivacyCoverTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SharedState.begin()
    }

    override func tearDown() {
        SharedState.end()
        super.tearDown()
    }

    /// A lock that is on and has not been opened: how the app starts when the person has turned it on.
    private func lockedLock() -> AppLock {
        UserDefaults.standard.set(true, forKey: PrefKey.biometricLock)
        return AppLock()
    }

    /// A lock that is on and has been opened, which only Face ID can do for the real thing.
    private func openLock() -> AppLock {
        let lock = AppLock()
        UserDefaults.standard.set(true, forKey: PrefKey.biometricLock)
        return lock
    }

    // MARK: What is called for

    func testTheLockWinsOverTheShield() {
        let lock = lockedLock()
        XCTAssertEqual(lock.cover, .lock)
        // The Face ID prompt takes the app out of the foreground; the lock must not give way to a blank card then.
        lock.scenePhaseChanged(.inactive)
        XCTAssertEqual(lock.cover, .lock)
        lock.scenePhaseChanged(.background)
        XCTAssertEqual(lock.cover, .lock)
    }

    func testTheShieldIsUpOnlyWhileTheAppIsNotFrontmost() {
        let lock = openLock()
        XCTAssertEqual(lock.cover, .none)
        lock.scenePhaseChanged(.inactive)
        XCTAssertEqual(lock.cover, .shield)
        lock.scenePhaseChanged(.active)
        XCTAssertEqual(lock.cover, .none)
        lock.scenePhaseChanged(.background)
        XCTAssertEqual(lock.cover, .shield)
    }

    func testWithTheLockOffNothingCoversTheApp() {
        let lock = AppLock()
        lock.scenePhaseChanged(.inactive)
        XCTAssertEqual(lock.cover, .none)
    }

    // MARK: A screen that shows or takes a value

    func testASensitiveScreenGetsTheShieldWithTheLockOff() {
        let lock = AppLock()
        let screen = UUID()
        lock.beginSensitive(screen)
        XCTAssertEqual(lock.cover, .none, "nothing covers the screen while the app is in front")
        lock.scenePhaseChanged(.inactive)
        XCTAssertEqual(lock.cover, .shield)
        lock.scenePhaseChanged(.active)
        XCTAssertEqual(lock.cover, .none)
        lock.scenePhaseChanged(.background)
        XCTAssertEqual(lock.cover, .shield)
    }

    func testNothingCoversTheAppOnceTheSensitiveScreenIsGone() {
        let lock = AppLock()
        let screen = UUID()
        lock.beginSensitive(screen)
        lock.scenePhaseChanged(.inactive)
        XCTAssertEqual(lock.cover, .shield)
        lock.endSensitive(screen)
        XCTAssertEqual(lock.cover, .none, "the cover was only up for that screen")
        lock.scenePhaseChanged(.background)
        XCTAssertEqual(lock.cover, .none)
    }

    func testASensitiveScreenNeverLocksSomeoneWhoHasTheLockOff() async {
        let lock = AppLock(grace: 0)
        lock.beginSensitive(UUID())
        lock.scenePhaseChanged(.background)
        try? await Task.sleep(nanoseconds: 20_000_000)
        lock.scenePhaseChanged(.active)
        XCTAssertFalse(lock.isLocked, "away for longer than the grace, and still not locked")
        XCTAssertEqual(lock.cover, .none)
    }

    func testTheLockStillLocksAfterTheGraceWithASensitiveScreenUp() async {
        let lock = AppLock(grace: 0)
        UserDefaults.standard.set(true, forKey: PrefKey.biometricLock)
        lock.beginSensitive(UUID())
        lock.scenePhaseChanged(.background)
        try? await Task.sleep(nanoseconds: 20_000_000)
        lock.scenePhaseChanged(.active)
        XCTAssertTrue(lock.isLocked)
        XCTAssertEqual(lock.cover, .lock)
    }

    func testTheCountOfSensitiveScreensBalances() {
        let lock = AppLock()
        let first = UUID()
        let second = UUID()
        lock.beginSensitive(first)
        lock.beginSensitive(first)
        XCTAssertEqual(lock.sensitiveScreenCount, 1, "a screen that reports twice counts once")
        lock.beginSensitive(second)
        XCTAssertEqual(lock.sensitiveScreenCount, 2)

        lock.endSensitive(first)
        lock.scenePhaseChanged(.inactive)
        XCTAssertEqual(lock.cover, .shield, "the other one is still up")
        lock.endSensitive(second)
        XCTAssertEqual(lock.sensitiveScreenCount, 0)
        XCTAssertEqual(lock.cover, .none)

        lock.endSensitive(second)
        XCTAssertEqual(lock.sensitiveScreenCount, 0, "going twice does not take the count below nothing")
    }

    func testTheControllerPutsTheShieldUpForASensitiveScreenWithTheLockOff() {
        let lock = AppLock()
        lock.beginSensitive(UUID())
        let presenter = CoreFakeCoverPresenter()
        let controller = PrivacyCoverController(lock: lock, presenter: presenter)
        controller.sceneWillDeactivate()
        XCTAssertEqual(presenter.asked, [.shield], "at once, before the app switcher takes its picture")
        lock.scenePhaseChanged(.active)
        controller.sync()
        XCTAssertEqual(presenter.asked, [.shield, .none])
    }

    /// A model for the modifier to ask the lock of, and a screen whose sensitivity can be switched.
    @Observable
    final class Sensitivity {
        var isOn = true
    }

    struct SensitiveProbe: View {
        let sensitivity: Sensitivity
        var body: some View { Color.clear.hvSensitive(sensitivity.isOn) }
    }

    private func host<V: View>(_ view: V) throws -> UIWindow {
        let window = UIWindow(windowScene: try hostScene())
        window.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        return window
    }

    private func eventually(_ condition: () -> Bool) async {
        for _ in 0..<150 where !condition() { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    func testTheModifierReportsAScreenToTheLockWhileItIsOn() async throws {
        let model = AppModel.preview()
        let sensitivity = Sensitivity()
        let window = try host(SensitiveProbe(sensitivity: sensitivity).environment(model))
        defer { window.isHidden = true }

        await eventually { model.lock.sensitiveScreenCount == 1 }
        XCTAssertEqual(model.lock.sensitiveScreenCount, 1)

        sensitivity.isOn = false
        await eventually { model.lock.sensitiveScreenCount == 0 }
        XCTAssertEqual(model.lock.sensitiveScreenCount, 0, "a sheet that has no key any more asks for nothing")

        sensitivity.isOn = true
        await eventually { model.lock.sensitiveScreenCount == 1 }
        XCTAssertEqual(model.lock.sensitiveScreenCount, 1)
    }

    func testTheModifierAsksForNothingWhereThereIsNoAppAround() async throws {
        let window = try host(Color.clear.hvSensitive())
        defer { window.isHidden = true }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(window.isHidden, "drawn without the app's model, as a preview does, and nothing went wrong")
    }

    // MARK: When it is put up

    @MainActor
    private final class CoreFakeCoverPresenter: CoverPresenting {
        private(set) var asked: [PrivacyCover] = []
        var hasScene = true

        func present(_ cover: PrivacyCover) -> Bool {
            asked.append(cover)
            return hasScene
        }
    }

    func testNothingIsPutUpWhileThereIsNothingToCover() {
        let presenter = CoreFakeCoverPresenter()
        let controller = PrivacyCoverController(lock: openLock(), presenter: presenter)
        controller.sync()
        controller.sync()
        XCTAssertTrue(presenter.asked.isEmpty, "no window is made for nothing")
    }

    func testTheLockIsUpFromLaunchWhenItIsOn() {
        let presenter = CoreFakeCoverPresenter()
        let controller = PrivacyCoverController(lock: lockedLock(), presenter: presenter)
        controller.start()
        XCTAssertEqual(presenter.asked, [.lock])
        XCTAssertEqual(controller.shown, .lock)
    }

    func testTheShieldGoesUpAtOnceWhenTheSceneIsAboutToLoseFocus() {
        let presenter = CoreFakeCoverPresenter()
        let controller = PrivacyCoverController(lock: openLock(), presenter: presenter)
        controller.sceneWillDeactivate()
        XCTAssertEqual(presenter.asked, [.shield], "before SwiftUI has been told, since the app switcher's picture is taken after")
    }

    func testTheShieldComesDownWhenTheAppIsFrontmostAgain() {
        let lock = openLock()
        let presenter = CoreFakeCoverPresenter()
        let controller = PrivacyCoverController(lock: lock, presenter: presenter)
        controller.sceneWillDeactivate()
        lock.scenePhaseChanged(.active)
        controller.sync()
        XCTAssertEqual(presenter.asked, [.shield, .none])
        XCTAssertEqual(controller.shown, .none)
    }

    func testTheLockStaysUpThroughTheFaceIDPrompt() {
        let presenter = CoreFakeCoverPresenter()
        let controller = PrivacyCoverController(lock: lockedLock(), presenter: presenter)
        controller.start()
        controller.sceneWillDeactivate()
        XCTAssertEqual(presenter.asked, [.lock], "the prompt takes the app out of the foreground; the lock is not swapped for a blank card")
    }

    func testACoverWithNoSceneToGoInIsAskedForAgain() {
        let presenter = CoreFakeCoverPresenter()
        presenter.hasScene = false
        let controller = PrivacyCoverController(lock: lockedLock(), presenter: presenter)
        controller.sync()
        XCTAssertEqual(controller.shown, .none, "it did not go up")

        presenter.hasScene = true
        controller.sync()
        controller.sync()
        XCTAssertEqual(presenter.asked, [.lock, .lock])
        XCTAssertEqual(controller.shown, .lock)
    }

    func testTheCoverFollowsTheLockWithoutBeingAsked() async {
        let lock = openLock()
        let presenter = CoreFakeCoverPresenter()
        let controller = PrivacyCoverController(lock: lock, presenter: presenter)
        controller.start()
        XCTAssertTrue(presenter.asked.isEmpty)

        lock.scenePhaseChanged(.background)
        for _ in 0..<200 where presenter.asked.isEmpty { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(presenter.asked, [.shield])
    }

    // MARK: The window

    private func hostScene() throws -> UIWindowScene {
        try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "the unit tests are hosted by the app, which has a scene"
        )
    }

    func testTheLockGoesInAWindowAboveEveryPresentationAndHidesTheAppFromVoiceOver() throws {
        let scene = try hostScene()
        let presenter = SceneCoverPresenter(lock: AppLock())
        presenter.fades = false
        defer { _ = presenter.present(.none) }

        XCTAssertTrue(presenter.present(.lock))
        let cover = try XCTUnwrap(presenter.window)
        XCTAssertGreaterThan(cover.windowLevel, UIWindow.Level.alert, "a sheet and an alert both sit below it")
        XCTAssertFalse(cover.isHidden)
        XCTAssertTrue(cover.isUserInteractionEnabled)
        XCTAssertEqual(cover.rootViewController?.view.accessibilityViewIsModal, true)
        XCTAssertEqual(cover.rootViewController?.view.accessibilityElementsHidden, false, "the lock itself stays reachable")
        for other in scene.windows where other !== cover {
            XCTAssertLessThanOrEqual(other.windowLevel, cover.windowLevel)
            XCTAssertTrue(other.accessibilityElementsHidden, "the app's window holds the sheets, so VoiceOver must not read it")
        }

        XCTAssertTrue(presenter.present(.none))
        XCTAssertNil(presenter.window, "the window is let go of when nothing is covered")
        for other in scene.windows {
            XCTAssertFalse(other.accessibilityElementsHidden, "the app is reachable again")
        }
    }

    func testTheShieldIsForTheEyeAndDoesNotTakeTheApp() throws {
        let scene = try hostScene()
        let presenter = SceneCoverPresenter(lock: AppLock())
        presenter.fades = false
        defer { _ = presenter.present(.none) }

        XCTAssertTrue(presenter.present(.shield))
        let cover = try XCTUnwrap(presenter.window)
        XCTAssertGreaterThan(cover.windowLevel, UIWindow.Level.alert)
        XCTAssertFalse(cover.isHidden)
        XCTAssertFalse(cover.isUserInteractionEnabled, "it is up for a moment whenever Control Center is pulled down")
        XCTAssertEqual(cover.rootViewController?.view.accessibilityElementsHidden, true)
        for other in scene.windows where other !== cover {
            XCTAssertFalse(other.accessibilityElementsHidden, "switching the app off would drop the focus of the field being typed in")
        }
    }

    func testTheLockReplacesTheShieldInTheSameWindow() throws {
        _ = try hostScene()
        let presenter = SceneCoverPresenter(lock: AppLock())
        presenter.fades = false
        defer { _ = presenter.present(.none) }

        XCTAssertTrue(presenter.present(.shield))
        let shieldWindow = try XCTUnwrap(presenter.window)
        XCTAssertTrue(presenter.present(.lock))
        XCTAssertTrue(presenter.window === shieldWindow)
        XCTAssertTrue(shieldWindow.isUserInteractionEnabled)
    }
}
