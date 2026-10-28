import XCTest

/// Pages, written to from the Library: a page made from pasted text and kept as a living page, its source edited; and a
/// kept page made public, its link looked at, and then deleted. Each journey checks what the screen shows afterwards and
/// what the app sent to the server.
@MainActor
final class PagesWritesJourneyTests: HyperVaultUITestCase {
    func testAPageIsMadeFromTextAndItsSourceIsEdited() {
        launch(.signedIn)
        openFromAccount("library", title: "Library")
        let slug = "balcony-notes-p1"

        step("New offers a page from text") {
            tap(button("New"), "New")
            tap(button("A page from text or a file"), "A page from text or a file")
            require(element("artifact.new.content"), "the field for the page's text")
            require(button("Keep it"), "the Keep it button")
        }

        step("A living page is asked for") {
            let more = button("More options")
            reveal(more, "More options")
            tap(more, "More options")
            let living = toggle("Keep versions, so it can be rewritten")
            reveal(living, "the Keep versions switch")
            XCTAssertEqual(living.value as? String, "0", "Versions are off until asked for.")
            living.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            waitUntil("the Keep versions switch to turn on") { (living.value as? String) == "1" }
        }

        step("A title and the text are typed") {
            let title = element("artifact.new.title")
            reveal(title, "the title field")
            enter("Balcony notes", into: title, "the title field")
            putTheKeyboardAway()
            let content = element("artifact.new.content")
            reveal(content, "the page's text field")
            enter("<h1>Balcony notes</h1>", into: content, "the page's text field")
        }

        step("Keep it keeps the page and says where it is") {
            tap(button("Keep it"), "Keep it")
            require(button("Open"), "the Open button of the kept page")
            XCTAssertTrue(isShowingTitle("Kept"))
        }

        step("Open shows the page, and the app sent what was typed") {
            tap(button("Open"), "Open")
            waitUntil("the page's title in the navigation bar") { self.isShowingTitle("Balcony notes") }
            require(named("Balcony notes", in: app.webViews.staticTexts), "the page's heading in its web view", timeout: 40)
            // (The record of writes is read with no sheet over the page.)
            requireWrite(
                "POST", "/api/save",
                equal: ["title": "Balcony notes", "mutable": "true", "visibility": "private"],
                contains: ["content": "<h1>Balcony notes</h1>"]
            )
        }

        step("Source opens editable, and the edit is saved as a new version") {
            tap(element("artifact.source"), "Source")
            let edit = button("Edit")
            require(edit, "the Edit button of a living page")
            tap(edit, "Edit")
            append("<p>Water on Fridays.</p>", to: element("artifact.source.text"), "the source")
            tap(button("Save"), "Save")
            require(button("Edit"), "the Edit button again, once the new version is saved")
            tap(button("Done"), "Done")
        }

        step("The page shows its new version, and the app sent it") {
            require(named("Water on Fridays.", in: app.webViews.staticTexts), "the new paragraph in the page", timeout: 40)
            requireWrite("PUT", "/api/artifacts/\(slug)/content", contains: ["content": "<p>Water on Fridays.</p>"])
        }

        step("History lists the new version") {
            tap(button("More"), "the More menu")
            tap(button("History"), "History")
            require(shows("Latest"), "the tag on the latest version")
            tap(button("Done"), "Done")
        }

        step("The Library lists the page") {
            goBack(until: { self.element("library.row.p1").exists })
            require(element("library.row.p1"), "the new page in the Library")
            XCTAssertTrue(element("library.row.p1").label.contains("Balcony notes"), "The row says \"\(element("library.row.p1").label)\".")
        }
    }

    func testAPageIsMadePublicItsLinkIsShownAndThenItIsDeleted() {
        launch(.signedIn)
        openFromAccount("library", title: "Library")

        step("The Trip to Lisbon page opens") {
            open(element("library.row.a2"), "the Trip to Lisbon row", until: { self.isShowingTitle("Trip to Lisbon") })
            require(named("Fresh bread daily", in: app.webViews.staticTexts), "the page in its web view", timeout: 40)
            XCTAssertTrue(element("artifact.access").label.contains("Private"), "The page starts private: \"\(element("artifact.access").label)\".")
        }

        step("Making it public asks first, and then sends the change") {
            tap(element("artifact.access"), "the access menu")
            let publicOption = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Public")).firstMatch
            tap(publicOption, "the Public choice")
            confirm("Make public")
            requireWrite("PATCH", "/api/artifacts", equal: ["slug": "trip-to-lisbon-q7", "visibility": "public"])
            waitUntil("the access button to say Public") { self.element("artifact.access").label.contains("Public") }
        }

        step("Share shows the link anyone can open it with") {
            tap(element("artifact.share"), "Share")
            require(shows("trip-to-lisbon-q7"), "the link of the page")
            require(button("Copy link"), "the Copy link button")
            tap(button("Done"), "Done")
        }

        step("Delete asks first, and then deletes the page") {
            tap(button("More"), "the More menu")
            tap(button("Delete"), "Delete")
            requireGone(button("Connections"), "the More menu")
            confirm("Delete")
            requireWrite("DELETE", "/api/artifacts", equal: ["slug": "trip-to-lisbon-q7"])
        }

        step("The Library no longer lists it") {
            require(element("library.row.a1"), "the Library again")
            requireGone(element("library.row.a2"), "the deleted page")
        }
    }
    func testAPageIsSharedWithAPersonAndTheyAreRemoved() {
        launch(.signedIn)
        openFromAccount("library", title: "Library")
        let email = "sam@home.invalid"
        // The sheet opens at half height, which shows the link and not the people under it: its handle is pulled up to full
        // height. (Scrolling it would not do: a drag that goes down on a sheet closes it.)
        func pullTheSheetUp() {
            let handle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.475))
            let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
            handle.press(forDuration: 0.05, thenDragTo: top, withVelocity: XCUIGestureVelocity(rawValue: 500), thenHoldForDuration: 0.2)
        }
        // A person in the list is known by their Remove button, a button of its own (labelled "Remove <address>") beside the
        // row that reads as one. (The row is not asked about: it is a button that covers the same width, and it is not
        // reported as hittable. The toasts that name the address are static text, not buttons.)
        let remove = button("Remove \(email)")

        step("The Trip to Lisbon page opens, and Share has nobody on it yet") {
            open(element("library.row.a2"), "the Trip to Lisbon row", until: { self.isShowingTitle("Trip to Lisbon") })
            tap(element("artifact.share"), "Share")
            require(element("artifact.share.email"), "the field for an email address")
            XCTAssertFalse(remove.exists, "Nobody has the page yet.")
            pullTheSheetUp()
            require(element("artifact.share.email"), "the sheet at full height")
        }

        step("An address and Return give the person a view of the page") {
            enter("\(email)\n", into: element("artifact.share.email"), "the email field")
            requireWrite("POST", "/api/shares", equal: ["artifact": "trip-to-lisbon-q7", "email": email, "role": "view"])
            require(remove, "the person in the list of who has the page (their Remove button)")
        }

        step("Remove asks first, and then ends the share") {
            // (If the sheet went back to half height while the keyboard came and went, the person is below it again.)
            if !(remove.exists && remove.isHittable) { pullTheSheetUp() }
            revealAboveTheKeyboard(remove, "the Remove button of \(email)")
            // The button is tapped where it is on the screen when XCUITest does not call it hittable: the row that reads as one
            // is a button over the same width, and what the finger meets is the Remove button on top of it.
            if remove.isHittable {
                remove.tap()
            } else {
                remove.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            confirm("Remove")
            requireWrite("DELETE", "/api/shares", equal: ["share_id": "sh-1"])
            requireGone(remove, "the person who was removed")
            tap(button("Done"), "Done")
        }
    }
}
