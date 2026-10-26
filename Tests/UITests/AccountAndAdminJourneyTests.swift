import XCTest

/// Account & keys end to end (connecting an agent mints a key that is shown once; revoking a key removes it) and the
/// Admin screen of a person the server knows as an admin (minting an invite code and managing it).
@MainActor
final class AccountAndAdminJourneyTests: HyperVaultUITestCase {
    func testConnectingAnAgentMintsAKeyShownOnceAndRevokingAKeyRemovesIt() {
        launch(.signedIn)
        openFromYou("agentsAndKeys", title: "Account & keys")

        step("Account & keys lists the keys the person has") {
            for id in ["k1", "k2", "k3"] { require(element("keys.row.\(id)"), "the key \(id)") }
            // The server names a key nobody named "default", and the list calls it what a person would.
            XCTAssertTrue(element("keys.row.k3").label.contains("Untitled key"), "The third key says \"\(element("keys.row.k3").label)\".")
            XCTAssertTrue(element("keys.row.k1").label.contains("Agent connected"), "The first key says \"\(element("keys.row.k1").label)\".")
        }

        step("Connect your AI offers the apps an agent lives in") {
            tap(element("keys.connect"), "Connect an agent")
            require(shows("Just make a key"), "the way to make a key for anything not listed")
            let search = searchField("Search apps, like Cursor or curl")
            enter("Cursor", into: search, "the app search")
            require(element("connect.client.cursor"), "the Cursor row")
        }

        step("Making the key shows it once, with a copy button") {
            tap(element("connect.client.cursor"), "the Cursor row")
            require(button("Make the key"), "the Make the key button")
            tap(button("Make the key"), "Make the key")
            require(shows("Your key, shown once"), "the key, shown once")
            let copy = button("Copy key")
            require(copy, "the Copy key button")
            tap(copy, "Copy key")
            require(button("Copied"), "the Copy key button saying it copied")
            require(button("Copy the prompt"), "the prompt for the AI, which holds the key")
        }

        step("The steps for the app come with the key filled in") {
            require(shows("Steps"), "the steps heading")
            require(shows("Cursor"), "the app's name")
        }

        step("Closing the sheet lists the new key, without its value") {
            let back = app.navigationBars.buttons.matching(NSPredicate(format: "label == %@", "Connect your AI")).firstMatch
            tap(back, "the back button to Connect your AI")
            require(shows("Your key is ready"), "the banner that keeps the key until the sheet closes")
            // The search is still open (it was used to find the app), and while it is open its own close button
            // stands where Done is.
            if !button("Done").exists { tap(button("Close"), "the search's close button") }
            tap(button("Done"), "Done")
            require(element("keys.row.k4"), "the key that was just made")
            let made = element("keys.row.k4")
            XCTAssertTrue(made.label.contains("Cursor"), "The new key says \"\(made.label)\".")
            XCTAssertTrue(made.label.contains("hv_Qm7TnB41"), "The new key says \"\(made.label)\".")
            XCTAssertFalse(made.label.contains("V2cLp9Rs"), "The key's value is never shown again.")
        }

        step("Revoking a key removes it from the list") {
            tap(element("keys.row.k3"), "the key nobody named")
            waitUntil("the key's screen") { isShowingTitle("Key") }
            tap(button("Revoke key"), "Revoke key")
            require(button("Keep it"), "the confirmation")
            let confirm = app.buttons.matching(NSPredicate(format: "label == %@", "Revoke key"))
            tap(confirm.element(boundBy: max(confirm.count - 1, 0)), "the Revoke key confirmation")
            requireGone(element("keys.row.k3"), "the revoked key")
            require(element("keys.row.k1"), "the keys that were not revoked")
            require(element("keys.row.k4"), "the key that was made")
        }
    }

    func testAnAdminMintsAnInviteCodeAndManagesIt() {
        launch(.signedInAdmin)
        openFromYou("admin", title: "Admin")

        step("Admin says what it can and cannot list") {
            require(shows("About the lists"), "the notice about the lists")
            require(shows("Nothing yet."), "the empty list of codes minted on this phone")
            require(button("Create code"), "the Create code button")
        }

        step("A code is minted with a number of uses and a note") {
            let uses = textField("admin.uses")
            let usesValue = uses.value as? String
            XCTAssertEqual(usesValue, "1", "One use is the default.")
            tap(uses, "the uses field")
            clear(uses)
            uses.typeText("5")
            enter("Launch batch", into: textField("admin.note"), "the note field")
            tap(button("Create code"), "Create code")
            require(shows("Just minted"), "the card of the code just minted")
            require(shows("Invite code H V"), "the code, spelt out for VoiceOver")
            require(shows("Copy code"), "the Copy code button")
        }

        let row = element("admin.invite.3f1c1a2e-0000-4000-8000-000000000001")
        step("The code is listed with how many have used it") {
            reveal(row, "the code in the list")
            XCTAssertTrue(row.label.contains("HV-UIT1-K7QM"), "The row says \"\(row.label)\".")
            XCTAssertTrue(row.label.contains("0 of 5 used"), "The row says \"\(row.label)\".")
            XCTAssertTrue(row.label.contains("Launch batch"), "The row says \"\(row.label)\".")
        }

        step("The code opens to be switched off") {
            tap(row, "the code in the list")
            waitUntil("the code's screen") { isShowingTitle("Invite code") }
            let accepting = toggle("Accepting new sign-ups")
            require(accepting, "the switch for accepting sign-ups")
            XCTAssertEqual(accepting.value as? String, "1", "A new code accepts sign-ups.")
            accepting.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            waitUntil("the code to be switched off") { (accepting.value as? String) == "0" }
        }

        step("The list shows the code as off") {
            goBack()
            require(row, "the code in the list")
            waitUntil("the row to say the code is off") { row.label.contains("Off") }
        }

        step("Accounts & waitlist opens to act on an account by its ID") {
            let accounts = shows("Accounts & waitlist")
            reveal(accounts, "the Accounts & waitlist row")
            tap(accounts, "Accounts & waitlist")
            waitUntil("the Accounts title") { isShowingTitle("Accounts") }
            require(shows("Open the web dashboard, copy the account's ID"), "the line that says where the IDs are")
            require(textField("3f1c1a2e-…"), "the field for an account ID")
        }
    }
}
