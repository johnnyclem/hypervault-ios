import XCTest

/// Launches the real app into every scenario and asserts only that it reaches its first screen: no crash on launch, no
/// launch view that never ends, no "can't reach" screen. It measures nothing. (It is named to run first: the first
/// launches after the simulator boots are the slow ones, and these are the cheap ones to spend that on.)
@MainActor
final class AppLaunchSmokeTests: HyperVaultUITestCase {
    func testEveryScenarioReachesItsFirstScreen() {
        for scenario in Scenario.allCases {
            step("\(scenario.rawValue) reaches \(scenario.firstScreen.description)") {
                // `launch` waits for the scenario's first screen and fails with its name if it never comes.
                launch(scenario)
                XCTAssertEqual(app.state, .runningForeground, "The app should still be running in front after reaching its first screen.")
                XCTAssertFalse(text("Can't reach HyperVault").exists, "The canned server should answer; the app showed its unreachable screen.")
            }
        }
    }
}
