import XCTest

/// The vault's journeys that write or change what a screen says about who may read an entry: a key allowed and revoked
/// with the switch following the server, a key the server had already revoked, an entry deleted somewhere else, a sheet that
/// asks before it drops what was typed, a taken name, and a card number that is called wrong only once it is left. Each
/// checks what the screen shows and what the app sent (the debug-only record of writes, see `UITestWrites.swift`). The first
/// journeys of the vault (adding a login, renaming it, deleting a card) are in `MemoryAndVaultWritesJourneyTests`.
@MainActor
final class VaultWritesJourneyTests: HyperVaultUITestCase {
    private func openTheVault() {
        openFromYou("vaultItems", title: "Vault")
        require(element("vault.row.github.com"), "the saved logins")
    }

    /// Opens an entry from the list and waits for its sheet: the one that says its value is never shown again. The sheet
    /// opens at half height, and the first drag up takes it to full height, where the rest of it can be reached.
    private func openTheEntry(_ name: String) {
        open(element("vault.row.\(name)"), "the \(name) row", until: { self.isShowingTitle(name) })
        reveal(shows("The value is encrypted and never shown again."), "the screen of \(name)")
    }

    // MARK: Who may read an entry

    /// The switch for the agent key whose label holds `fragment` ("Claude Code", a key's prefix).
    private func switchFor(_ fragment: String) -> XCUIElement {
        app.switches.matching(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
    }

    /// Flips a switch the way a person does: a tap at the right of its row, where the thumb is.
    private func flip(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
    }

    func testAKeyIsAllowedAndRevokedAndTheSwitchFollowsTheServer() {
        launch(.signedIn)
        openTheVault()

        step("The entry's page shows which keys may read it, as the server says") {
            openTheEntry("github.com")
            reveal(switchFor("Claude Code"), "the Claude Code key's switch")
            XCTAssertEqual(switchFor("Claude Code").value as? String, "1", "Claude Code may read it.")
            XCTAssertEqual(switchFor("Paired: Cursor").value as? String, "0", "The paired Cursor key may not.")
        }

        step("Allowing the Cursor key sends the allow, and the switch ends on") {
            let cursor = switchFor("Paired: Cursor")
            reveal(cursor, "the Cursor key's switch")
            flip(cursor)
            requireWrite("POST", "/api/secrets/github.com/grants", equal: ["api_key_id": "k2"])
            waitUntil("the Cursor switch to turn on") { (cursor.value as? String) == "1" }
        }

        step("Revoking it sends the revoke, and the switch ends off") {
            let cursor = switchFor("Paired: Cursor")
            flip(cursor)
            requireWrite("DELETE", "/api/secrets/github.com/grants", equal: ["api_key_id": "k2"])
            waitUntil("the Cursor switch to turn off") { (cursor.value as? String) == "0" }
            XCTAssertEqual(switchFor("Claude Code").value as? String, "1", "The other key is not touched.")
        }
    }

    func testTurningOffAKeyTheServerHadAlreadyRevokedEndsOffAndSaysNothing() {
        launch(.signedIn)
        openTheVault()
        openTheEntry("github.com")

        step("The first read still lists a key that another device revoked") {
            reveal(switchFor("hv_Dd3Ee4Ff"), "the default key's switch")
            XCTAssertEqual(switchFor("hv_Dd3Ee4Ff").value as? String, "1")
        }

        step("Turning it off ends off, and the server's 404 is not shown") {
            let stale = switchFor("hv_Dd3Ee4Ff")
            reveal(stale, "the default key's switch")
            flip(stale)
            requireWrite("DELETE", "/api/secrets/github.com/grants", equal: ["api_key_id": "k3"])
            waitUntil("the switch to end off") { (stale.value as? String) == "0" }
            XCTAssertFalse(shows("No such grant").exists, "'No such grant.' is never shown.")
        }
    }

    func testAnEntryDeletedElsewhereClosesItsPageWhenAKeyIsAllowed() {
        launch(.signedIn)
        openTheVault()
        openTheEntry("stripe-restricted-key")

        step("Allowing a key finds the entry gone, and its page closes") {
            let cursor = switchFor("Paired: Cursor")
            reveal(cursor, "the Cursor key's switch")
            flip(cursor)
            requireWrite("POST", "/api/secrets/stripe-restricted-key/grants", equal: ["api_key_id": "k2"])
            waitUntil("the page to close and the list to lose the entry") {
                self.element("vault.row.github.com").exists && !self.element("vault.row.stripe-restricted-key").exists
            }
            XCTAssertFalse(shows("No such secret").exists, "'No such secret.' is never shown.")
        }
    }

    // MARK: Closing a sheet that holds typed values

    func testClosingTheAddSheetAsksBeforeItDropsWhatWasTyped() {
        launch(.signedIn)
        openTheVault()

        step("A login is started") {
            tap(button("Add to your vault"), "the add button")
            tap(element("vault.add.login"), "the Login tile")
            enter("typed-and-not-saved", into: element("vault.field.username"), "the username field")
            putTheKeyboardAway()
        }

        step("Close asks first, and Keep editing returns to the form") {
            tap(button("Close"), "the Close button")
            require(button("Discard"), "the question about the typed values")
            // The question is a popover on iOS 26, which has no Cancel button: a tap away from it is Keep editing. (Where it is
            // a sheet with a button, the button is tapped.)
            let keep = button("Keep editing")
            if keep.waitForExistence(timeout: 3) {
                keep.tap()
            } else {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.96)).tap()
            }
            requireGone(button("Discard"), "the question")
            XCTAssertEqual(element("vault.field.username").value as? String, "typed-and-not-saved", "What was typed is still there.")
        }

        step("Discard closes the sheet and sends nothing") {
            tap(button("Close"), "the Close button")
            confirm("Discard")
            requireGone(element("vault.add.name"), "the add sheet")
            require(element("vault.row.github.com"), "the list")
            requireNoWrite("POST", "/api/secrets")
        }
    }

    func testATakenNamePutsTheServersWordsUnderNameAndMovesTheCursorThere() {
        launch(.signedIn)
        openTheVault()

        step("A login is typed with a name that is already used") {
            tap(button("Add to your vault"), "the add button")
            tap(element("vault.add.login"), "the Login tile")
            enter("ui-dup", into: element("vault.field.username"), "the username field")
            enter("pw-dup-1", into: element("vault.field.password"), "the password field")
            let name = element("vault.add.name")
            tap(name, "the name field")
            clear(name)
            name.typeText("github.com")
            putTheKeyboardAway()
        }

        step("Save puts the server's words under Name and the cursor in the Name field") {
            open(button("Save"), "Save")
            requireWrite("POST", "/api/secrets", equal: ["name": "github.com", "kind": "login", "value": "<redacted>"])
            require(shows("already exists"), "the server's line about the name")
            waitUntil("the cursor to be in the Name field") {
                (self.element("vault.add.name").value(forKey: "hasKeyboardFocus") as? Bool) == true
            }
            require(element("vault.add.name"), "the form, still open with what was typed")
        }
    }

    func testACardNumberSaysItIsWrongOnlyOnceTheFieldIsLeft() {
        launch(.signedIn)
        openTheVault()

        step("A short card number is typed") {
            tap(button("Add to your vault"), "the add button")
            tap(element("vault.add.card"), "the Card tile")
            enter("4242", into: element("vault.field.card-number"), "the card number field")
            XCTAssertFalse(shows("must be 12 to 19 digits").exists, "The field says nothing while it is being typed in.")
        }

        step("Leaving the field says what is wrong with it") {
            tap(textField("Cardholder (optional)"), "the cardholder field")
            waitUntil("the card number's own line") { self.shows("The card number must be 12 to 19 digits.").exists }
        }
    }
}
