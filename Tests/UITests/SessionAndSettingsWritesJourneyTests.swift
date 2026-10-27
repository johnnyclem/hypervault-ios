import XCTest

/// What a person does to the session and to their phone's preferences, end to end: signing out (the app lands on the
/// welcome story and a launch afterwards does not bring the session back) and the choices in Settings (they stay when the
/// screen is left and entered again, and when the app is closed and opened again).
///
/// A journey that closes the app and opens it again launches with `resuming`, which makes the debug-only canned world carry
/// on from the launch before it (the session, which the app keeps in a secure store, and the preferences) instead of
/// starting like a first run.
@MainActor
final class SessionAndSettingsWritesJourneyTests: HyperVaultUITestCase {
    private let welcome = (identifier: "welcome.pages", description: "the welcome story")

    func testSigningOutEndsTheSessionAndTheNextLaunchDoesNotRestoreIt() {
        launch(.signedIn)

        step("Closing the app and opening it again keeps the session") {
            app.terminate()
            launch(.signedIn, resuming: true)
            require(element("canvas.field"), "the canvas, which a kept session opens on")
        }

        step("Sign out in the You tab lands on the welcome story") {
            openTab("You")
            let signOut = element("you.signOut")
            reveal(signOut, "the Sign out row")
            tap(signOut, "Sign out")
            require(element(welcome.identifier), "the welcome story after signing out")
            XCTAssertFalse(element("canvas.field").exists, "The canvas should be gone once the session has ended.")
        }

        step("The app told the auth server the session is over") {
            let logout = requireWrite("POST", "/auth/v1/logout")
            XCTAssertEqual(logout?.query, "scope=local", "Signing out ends this phone's session and no other.")
        }

        step("The next launch does not restore the session") {
            app.terminate()
            launch(.signedIn, resuming: true, reaching: welcome)
            XCTAssertFalse(element("canvas.field").exists, "A launch after signing out should not open the canvas.")
            XCTAssertFalse(tab("You").exists, "A launch after signing out should not show the tab bar.")
        }
    }

    func testTheChoicesInSettingsStayAfterLeavingAndAfterClosingTheApp() {
        launch(.signedIn)
        openFromYou("settings", title: "Settings")

        step("Appearance, the accent and haptics are changed") {
            choose("Dark", from: "settings.appearance")
            waitUntil("Dark to be the chosen appearance") { self.segment("Dark").isSelected }
            let violet = button("Violet")
            reveal(violet, "the Violet swatch")
            tap(violet, "the Violet accent")
            waitUntil("Violet to be the chosen accent") { violet.isSelected }
            let haptics = toggle("Haptics")
            reveal(haptics, "the Haptics switch")
            XCTAssertEqual(haptics.value as? String, "1", "Haptics start on.")
            haptics.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            waitUntil("the Haptics switch to turn off") { (haptics.value as? String) == "0" }
        }

        func choicesAreKept(_ when: String) {
            require(element("settings.appearance"), "the appearance choice \(when)")
            XCTAssertTrue(segment("Dark").isSelected, "Dark should still be the appearance \(when).")
            let violet = button("Violet")
            reveal(violet, "the Violet swatch \(when)")
            XCTAssertTrue(violet.isSelected, "Violet should still be the accent \(when).")
            XCTAssertFalse(button("Blue").isSelected, "Blue should no longer be the accent \(when).")
            let haptics = toggle("Haptics")
            reveal(haptics, "the Haptics switch \(when)")
            XCTAssertEqual(haptics.value as? String, "0", "Haptics should still be off \(when).")
        }

        step("Leaving Settings and coming back shows the same choices") {
            goBack(until: { self.isShowingTitle("You") })
            openFromYou("settings", title: "Settings")
            choicesAreKept("after leaving Settings")
        }

        step("Nothing was sent to the server: these choices belong to the phone") {
            XCTAssertTrue(recordedWrites().isEmpty, "Preferences are local; the app sent \(recordedWrites()).")
        }

        step("Closing the app and opening it again keeps them") {
            app.terminate()
            launch(.signedIn, resuming: true)
            openFromYou("settings", title: "Settings")
            choicesAreKept("after closing the app")
            XCTAssertTrue(recordedWrites().isEmpty, "Preferences are local; the app sent \(recordedWrites()).")
        }
    }
}
