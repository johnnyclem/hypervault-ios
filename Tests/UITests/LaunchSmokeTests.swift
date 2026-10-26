import XCTest

/// Launches the real app into every scenario and asserts only that it reaches its first screen: no crash on launch, no
/// launch view that never ends, no "can't reach" screen. It measures nothing.
@MainActor
final class LaunchSmokeTests: HyperVaultUITestCase {
    func testSignedOutReachesTheWelcomeStory() {
        reachesFirstScreen(.signedOut)
    }

    func testSignedInReachesTheCanvas() {
        reachesFirstScreen(.signedIn)
    }

    func testSignedInWithNothingKeptReachesTheCanvas() {
        reachesFirstScreen(.signedInEmpty)
    }

    func testWaitlistedReachesTheWaitlist() {
        reachesFirstScreen(.waitlisted)
    }

    private func reachesFirstScreen(_ scenario: Scenario) {
        // `launch` waits for the scenario's first screen and fails with its name if it never comes.
        launch(scenario)
        XCTAssertEqual(app.state, .runningForeground, "The app should still be running in front after reaching its first screen.")
        XCTAssertFalse(text("Can't reach HyperVault").exists, "The canned server should answer; the app showed its unreachable screen.")
        attachScreenshot("First screen, \(scenario.rawValue)")
    }
}
