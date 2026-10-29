import XCTest

/// Open on a key card of the Home canvas: the entry's own page from the Vault comes up over the canvas (its title, the lock
/// that keeps the value away, and the switches for the agent keys that may read it), and closing it leaves the card where it
/// was. An entry that is deleted while the card is still on the page is not there to open, and Open goes to the Vault's list
/// as it did before the card had a page of its own.
@MainActor
final class CanvasKeyCardJourneyTests: HyperVaultUITestCase {
    /// The launch flag that gives the canned vault the entry of the canvas's key card (`UITestWorld.keyCardEntryFlag`). The
    /// plain canned vault has none, which is what the Open of the last step needs and the first steps do not.
    private let withTheKeysEntry = ["-HV_UITEST_KEY_CARD_ENTRY"]

    /// Says something to the canvas and sends it.
    private func say(_ words: String) {
        enter(words, into: textField("canvas.field"), "the canvas field")
        tap(element("canvas.send"), "Send")
    }

    /// The switch for the agent key whose label holds `fragment` ("Claude Code", a key's prefix).
    private func switchFor(_ fragment: String) -> XCUIElement {
        app.switches.matching(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
    }

    /// Opens the key's page with the card's Open and waits for the page to say what the entry is.
    private func openTheKeysPage() {
        tap(button("Open OPENAI_API_KEY"), "Open on the key's card", until: { self.isShowingTitle("OPENAI_API_KEY") })
        // The page opens at half height, and the first drag up takes it to full height, where the rest of it can be reached.
        reveal(shows("The value is encrypted and never shown again."), "the key's page")
    }

    func testOpenOnAKeyCardShowsTheEntrysPageOverThePageAndADeletedEntryFallsBackToTheVault() {
        launch(.signedIn, arguments: withTheKeysEntry)

        step("Showing my keys puts the key on the page, with the agent that may use it") {
            say("show my keys")
            require(button("Open OPENAI_API_KEY"), "Open on the key's card")
            require(shows("Agents allowed"), "the card's list of agents")
            require(shows("Claude Code"), "the agent that may use the key, as a tag on the card")
        }

        step("Open shows the entry's page over the canvas, read for this entry") {
            openTheKeysPage()
            reveal(shows("Allowed keys"), "the section of the keys that may read it")
            let claude = switchFor("Claude Code")
            reveal(claude, "the switch for the Claude Code key")
            waitUntil("Claude Code to be allowed to read it") { (claude.value as? String) == "1" }
            let cursor = switchFor("Paired: Cursor")
            require(cursor, "the switch for the paired Cursor key")
            XCTAssertEqual(cursor.value as? String, "0", "The paired key has not been allowed to read it.")
            reveal(button("Rename"), "Rename, which is in the page and not on the card")
        }

        step("Close puts the page away and leaves the card on the canvas") {
            tap(button("Close"), "Close")
            requireGone(button("Close"), "the page")
            require(button("Open OPENAI_API_KEY"), "the key's card, which stays")
            require(button("Hide OPENAI_API_KEY"), "the card's Hide")
        }

        step("Deleting the entry from its page closes the page and leaves the card behind") {
            openTheKeysPage()
            let delete = button("Delete")
            reveal(delete, "the Delete button")
            tap(delete, "Delete")
            confirm("Delete", whileStill: delete)
            requireWrite("DELETE", "/api/secrets/OPENAI_API_KEY")
            requireGone(button("Close"), "the page, which closes when its entry is gone")
            require(button("Open OPENAI_API_KEY"), "the key's card, which is still on the page")
        }

        step("Open on a key whose entry is gone goes to the Vault's list") {
            tap(button("Open OPENAI_API_KEY"), "Open on the key's card", until: { self.element("vault.row.github.com").exists })
            require(element("vault.row.github.com"), "the Vault's list")
            requireGone(element("vault.row.OPENAI_API_KEY"), "the deleted entry")
            waitUntil("the Vault's title") { isShowingTitle("Vault") }
        }
    }
}
