import XCTest

/// The You tab of someone signed in and what it opens: the Library and its two views, Settings, and Account & keys.
@MainActor
final class YouJourneyTests: HyperVaultUITestCase {
    func testTheAvatarOpensYouAndLibraryTogglesBetweenListAndGraph() {
        launch(.signedIn)

        step("The avatar on the canvas opens the You tab") {
            tap(button("Account"), "the Account button")
            let profile = element("you.profile")
            require(profile, "the profile card")
            XCTAssertTrue(profile.label.contains("Sam Rivers"), "The profile card says \"\(profile.label)\".")
            XCTAssertTrue(profile.label.contains("sam@example.com"), "The profile card says \"\(profile.label)\".")
        }

        step("You lists its rows") {
            for id in ["library", "vaultItems", "taskBoards", "agentsAndKeys"] {
                require(element("you.\(id)"), "the \(id) row")
            }
        }

        step("Library opens with what is kept") {
            tap(element("you.library"), "the Library row")
            waitUntil("the Library title") { isShowingTitle("Library") }
            require(element("library.row.a1"), "the Bakery landing page row")
            XCTAssertTrue(element("library.view").label == "Show as a graph", "The view button says \"\(element("library.view").label)\".")
        }

        step("The graph view draws the map") {
            tap(element("library.view"), "the view button")
            require(button("Passport checklist"), "the graph's node for the Passport checklist memory")
            require(button("Fit the whole graph"), "the graph's Fit button")
            XCTAssertEqual(element("library.view").label, "Show as a list")
        }

        step("The list view comes back") {
            tap(element("library.view"), "the view button")
            require(element("library.row.a1"), "the list again")
            XCTAssertEqual(element("library.view").label, "Show as a graph")
        }
    }

    func testSettingsFlipsAToggleAndTheAppearancePicker() {
        launch(.signedIn)
        openTab("You")

        step("Settings opens from the You tab") {
            reveal(element("you.settings"), "the Settings row")
            tap(element("you.settings"), "the Settings row")
            waitUntil("the Settings title") { isShowingTitle("Settings") }
        }

        step("A toggle flips") {
            let haptics = toggle("Haptics")
            require(haptics, "the Haptics switch")
            XCTAssertEqual(haptics.value as? String, "1", "Haptics start on.")
            // The knob is at the row's trailing edge.
            haptics.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            waitUntil("the Haptics switch to turn off") { (haptics.value as? String) == "0" }
        }

        step("The appearance picker changes the whole app") {
            let dark = segment("Dark")
            tap(dark, "the Dark appearance")
            waitUntil("Dark to be the chosen appearance") { dark.isSelected }
            attachScreenshot("Settings in the dark appearance")
            tap(segment("System"), "the System appearance")
            waitUntil("System to be the chosen appearance") { segment("System").isSelected }
            XCTAssertFalse(segment("Dark").isSelected)
        }
    }

    func testAccountAndKeysOpensWithItsKeys() {
        launch(.signedIn)
        openTab("You")

        step("Account & keys opens with the keys") {
            reveal(element("you.agentsAndKeys"), "the Account & keys row")
            tap(element("you.agentsAndKeys"), "the Account & keys row")
            waitUntil("the Account & keys title") { isShowingTitle("Account & keys") }
            require(element("keys.row.k1"), "the Claude Code key")
            XCTAssertTrue(element("keys.row.k1").label.contains("Claude Code"), "The key row says \"\(element("keys.row.k1").label)\".")
            require(element("keys.connect"), "Connect an agent")
        }
    }
}
