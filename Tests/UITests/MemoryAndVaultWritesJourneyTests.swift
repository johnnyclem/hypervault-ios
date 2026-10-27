import XCTest

/// Memories and the vault, written to: a memory's title and text edited and saved, a memory forgotten, a login added,
/// renamed and deleted. Each journey checks what the screen shows afterwards and what the app sent to the server (the
/// debug-only record of writes, see `UITestWrites.swift`); a typed secret must be in neither.
@MainActor
final class MemoryAndVaultWritesJourneyTests: HyperVaultUITestCase {
    // MARK: Memory

    func testEditingAMemorySavesItsTitleAndText() {
        launch(.signedIn)
        openTab("Memory")

        step("The Passport checklist memory opens") {
            open(element("memory.row.m6"), "the Passport checklist memory", until: { self.button("Actions").exists })
            require(button("Actions"), "the memory's actions menu")
            require(shows("what the consulate needs"), "the memory's text")
        }

        step("Edit opens the editor with what the memory says") {
            tap(button("Actions"), "the actions menu")
            tap(button("Edit"), "Edit")
            require(element("memory.edit.title"), "the title field")
            XCTAssertEqual(element("memory.edit.title").value as? String, "Passport checklist")
            require(element("memory.edit.content"), "the text field")
            XCTAssertTrue((element("memory.edit.content").value as? String ?? "").contains("what the consulate needs"))
        }

        step("The title and the text are changed and saved") {
            append(" 2026", to: element("memory.edit.title"), "the title field")
            append(" Renew in March.", to: element("memory.edit.content"), "the text field")
            tap(button("Save"), "Save")
            requireGone(element("memory.edit.title"), "the editor")
        }

        step("The memory shows the new title and text") {
            require(shows("Passport checklist 2026"), "the new title")
            require(shows("Renew in March."), "the new text")
        }

        step("The app sent the edit, the changed fields only") {
            let edit = requireWrite(
                "PATCH", "/api/memories/m6",
                equal: ["title": "Passport checklist 2026"], contains: ["content": "Renew in March."]
            )
            XCTAssertNil(edit?.fields["tags"], "The tags were not changed, so they are not sent.")
        }

        step("The list shows the new title") {
            goBack(until: { self.element("memory.row.m6").exists })
            waitUntil("the row to carry the new title") { self.element("memory.row.m6").label.contains("Passport checklist 2026") }
        }
    }

    func testForgettingAMemoryRemovesItFromMemoryAndFromYours() {
        launch(.signedIn)
        openTab("Memory")

        step("The Planning chat memory opens") {
            require(text("7 memories"), "the count line")
            open(element("memory.row.m3"), "the Planning chat memory", until: { self.button("Actions").exists })
            require(button("Actions"), "the memory's actions menu")
        }

        step("Forget asks first, and then forgets") {
            tap(button("Actions"), "the actions menu")
            tap(button("Forget"), "Forget")
            requireGone(button("Edit"), "the actions menu")
            confirm("Forget")
            requireWrite("DELETE", "/api/memories/m3")
        }

        step("The memory is gone from the list, and the count follows") {
            require(element("memory.row.m1"), "the list again")
            requireGone(element("memory.row.m3"), "the forgotten memory")
            require(text("6 memories"), "the new count")
        }

        step("Yours does not list it either") {
            openTab("Yours")
            require(element("yours.row.m1"), "the Yours list")
            requireGone(element("yours.row.m3"), "the forgotten memory in Yours")
        }
    }

    // MARK: Vault

    private func openTheVault() {
        openFromYou("vaultItems", title: "Vault")
        require(element("vault.row.github.com"), "the saved logins")
    }

    /// Opens an entry from the list and waits for its screen: the one that says its value is never shown again.
    private func openTheEntry(_ name: String) {
        open(element("vault.row.\(name)"), "the \(name) row", until: { self.shows("The value is encrypted and never shown again.").exists })
        require(shows("The value is encrypted and never shown again."), "the screen of \(name)")
    }

    func testAddingALoginSavesItAndNeverShowsItsPassword() {
        launch(.signedIn)
        openTheVault()
        let password = "pw-Zk7-ui-test"

        step("Add to your vault offers the kinds of entry") {
            tap(button("Add to your vault"), "the add button")
            require(element("vault.add.login"), "the Login tile")
            require(element("vault.add.card"), "the Card tile")
        }

        step("A login is typed, and Save stays off until it is complete") {
            tap(element("vault.add.login"), "the Login tile")
            enter("ui-login", into: element("vault.field.username"), "the username field")
            if button("Save").exists { XCTAssertFalse(button("Save").isEnabled, "Save should wait for the password.") }
            enter(password, into: element("vault.field.password"), "the password field")
            putTheKeyboardAway()
            XCTAssertEqual(element("vault.add.name").value as? String, "ui-login", "The name is suggested from the username.")
        }

        step("Saving closes the sheet and lists the login") {
            open(button("Save"), "Save")
            requireGone(element("vault.add.name"), "the add sheet")
            require(element("vault.row.ui-login"), "the new login in the list")
        }

        step("The list line is masked and the password is nowhere on screen") {
            let row = element("vault.row.ui-login")
            XCTAssertFalse(row.label.contains(password), "The row says \"\(row.label)\".")
            XCTAssertFalse(shows(password).exists, "A saved password is never shown again.")
        }

        step("The app sent the entry, and the password was not in what the record keeps") {
            requireWrite("POST", "/api/secrets", equal: ["name": "ui-login", "kind": "login", "value": "<redacted>"])
            XCTAssertFalse(writeRecordText().contains(password), "The record of writes must not hold a typed secret.")
        }
    }

    func testRenamingALoginKeepsItsScreenAndRenamesTheRow() {
        launch(.signedIn)
        openTheVault()

        step("The github.com login opens") {
            openTheEntry("github.com")
        }

        step("Rename opens with the current name and takes a new one") {
            // (The entry's screen is a long list; the button is below the fold until it is scrolled to.)
            let rename = button("Rename")
            reveal(rename, "the rename button")
            tap(rename, "Rename")
            require(element("vault.edit.name"), "the name field")
            XCTAssertEqual(element("vault.edit.name").value as? String, "github.com")
            append("-work", to: element("vault.edit.name"), "the name field")
            tap(button("Save"), "Save")
            requireGone(element("vault.edit.name"), "the rename sheet")
        }

        step("The app sent the new name") {
            requireWrite("PATCH", "/api/secrets/github.com", equal: ["new_name": "github.com-work"])
        }

        step("The entry's screen is still the entry, under its new name") {
            // The screen was opened under the old name; it must follow the entry, not go looking for the old name.
            waitUntil("the screen to settle") { self.isShowingTitle("github.com-work") || self.shows("This entry is gone").exists }
            attachScreenshot("The entry's screen after the rename")
            XCTAssertFalse(shows("This entry is gone").exists, "Renaming an entry left its own screen saying it is gone.")
            require(button("Rename"), "the entry's screen after the rename")
            XCTAssertTrue(isShowingTitle("github.com-work"), "The screen should carry the new name.")
        }

        step("The list has the new name and not the old") {
            goBack(until: { self.element("vault.row.github.com-work").exists })
            require(element("vault.row.github.com-work"), "the renamed login in the list")
            XCTAssertFalse(element("vault.row.github.com").exists, "The old name should be gone from the list.")
        }
    }

    func testDeletingACardRemovesItAndNeverShowsItsNumber() {
        launch(.signedIn)
        openTheVault()

        step("The card opens, masked") {
            openTheEntry("visa-4242")
            XCTAssertTrue(shows("Visa").exists)
            XCTAssertFalse(shows("4242 4242").exists, "A card number is never shown whole.")
        }

        step("Delete asks first, and then deletes") {
            let delete = button("Delete")
            reveal(delete, "the Delete button")
            tap(delete, "Delete")
            confirm("Delete", whileStill: delete)
            requireWrite("DELETE", "/api/secrets/visa-4242")
        }

        step("The card is gone from the list") {
            require(element("vault.row.github.com"), "the list again")
            requireGone(element("vault.row.visa-4242"), "the deleted card")
            require(element("vault.row.amex-0005"), "the other card, which stays")
        }
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
            waitUntil("the switches to appear") { self.switchFor("Claude Code").exists }
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
            waitUntil("the switches to appear") { self.switchFor("hv_Dd3Ee4Ff").exists }
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
            waitUntil("the switches to appear") { self.switchFor("Paired: Cursor").exists }
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
            tap(button("Keep editing"), "Keep editing")
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
}
