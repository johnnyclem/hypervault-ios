import XCTest

/// What a person does to the session, to their phone's preferences and to their address, end to end: signing out (the app
/// lands on the welcome story and a launch afterwards does not bring the session back), the choices in General that belong
/// to the phone (they stay when the pane is left and entered again, and when the app is closed and opened again), and the
/// look and the home page of a claimed address (sent to the server, and there when the screen is entered again).
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

        step("Sign out in General lands on the welcome story") {
            openPane("general", title: "General")
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
        openPane("general", title: "General")

        step("Haptics are turned off") {
            let haptics = toggle("Haptics")
            reveal(haptics, "the Haptics switch")
            XCTAssertEqual(haptics.value as? String, "1", "Haptics start on.")
            flip(haptics, from: "1", "the Haptics switch")
            XCTAssertEqual(haptics.value as? String, "0", "Haptics should be off.")
        }

        func choicesAreKept(_ when: String) {
            let haptics = toggle("Haptics")
            reveal(haptics, "the Haptics switch \(when)")
            XCTAssertEqual(haptics.value as? String, "0", "Haptics should still be off \(when).")
        }

        step("Leaving General and coming back shows the same choices") {
            goBack(until: { self.isShowingTitle("You") })
            openPane("general", title: "General")
            choicesAreKept("after leaving General")
        }

        step("Nothing was sent to the server: these choices belong to the phone") {
            XCTAssertTrue(recordedWrites().isEmpty, "Preferences are local; the app sent \(recordedWrites()).")
        }

        step("Closing the app and opening it again keeps them") {
            app.terminate()
            launch(.signedIn, resuming: true)
            openPane("general", title: "General")
            choicesAreKept("after closing the app")
            XCTAssertTrue(recordedWrites().isEmpty, "Preferences are local; the app sent \(recordedWrites()).")
        }
    }

    /// A row of a list whose choice is made on a screen of its own (a picker in the navigation-link style): it reads as
    /// a button or as a cell, and says its title and, after it, the choice it holds.
    private func choiceRow(_ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "(elementType == %lu OR elementType == %lu) AND label BEGINSWITH %@",
            XCUIElement.ElementType.button.rawValue, XCUIElement.ElementType.cell.rawValue, title
        )).firstMatch
    }

    func testAnAddressTakesANewLookAndHomePageAndKeepsThem() {
        launch(.signedIn)
        openPane("domain", title: "Domain")

        step("The second address has neither a look nor a home page") {
            tap(element("realms.row.c2"), "the nova.cleon.wiki address", until: { self.isShowingTitle("Address") })
            require(shows("nova.cleon.wiki"), "the address")
            let look = choiceRow("Look")
            require(look, "the Look row")
            XCTAssertFalse((look.label + " " + String(describing: look.value)).contains("Newsprint"), "No look is chosen yet.")
        }

        step("A look is chosen on its own screen and saved") {
            tap(choiceRow("Look"), "the Look row", until: { self.shows("Newsprint (light)").exists })
            tap(shows("Newsprint (light)"), "the Newsprint look")
            waitUntil("the Address screen again") { self.isShowingTitle("Address") && self.choiceRow("Look").exists }
            requireWrite(
                "PATCH", "/api/claim-domain",
                equal: ["subdomain": "nova", "base_domain": "cleon.wiki", "theme": "newsprint"]
            )
            let look = choiceRow("Look")
            waitUntil("the Look row to show the new look") { (look.label + " " + String(describing: look.value)).contains("Newsprint") }
        }

        step("A home page is chosen and saved, and only it changes") {
            let opens = choiceRow("Opens with")
            reveal(opens, "the Opens with row")
            tap(opens, "the Opens with row", until: { self.shows("Bakery landing page").exists })
            tap(shows("Bakery landing page"), "the Bakery landing page")
            waitUntil("the Address screen again") { self.isShowingTitle("Address") && self.choiceRow("Opens with").exists }
            let sent = requireWrite(
                "PATCH", "/api/claim-domain",
                equal: ["subdomain": "nova", "base_domain": "cleon.wiki", "default_artifact": "bakery-landing-page-x1"]
            )
            XCTAssertNil(sent?.fields["theme"], "Choosing a home page leaves the look out of the request.")
            require(button("Preview the page"), "the Preview button of an address that opens to a page")
        }

        step("Leaving the address and coming back shows both") {
            goBack(until: { self.element("realms.row.c2").exists })
            tap(element("realms.row.c2"), "the nova.cleon.wiki address", until: { self.isShowingTitle("Address") })
            let look = choiceRow("Look")
            require(look, "the Look row")
            XCTAssertTrue((look.label + " " + String(describing: look.value)).contains("Newsprint"), "The look is still Newsprint.")
            require(shows("Bakery landing page"), "the home page it opens to")
        }

        step("The other address was not touched") {
            goBack(until: { self.element("realms.row.c1").exists })
            tap(element("realms.row.c1"), "the nova.vault.cool address", until: { self.isShowingTitle("Address") })
            require(shows("Glassmorphism"), "the look it had")
        }
    }
}
