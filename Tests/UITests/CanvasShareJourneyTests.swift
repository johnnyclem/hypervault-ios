import XCTest

/// Share on a card of the Home canvas: a page, a file or a group offers it, and it opens the sheet of the people who can open the
/// page, over the canvas. A memory and a key have none.
@MainActor
final class CanvasShareJourneyTests: HyperVaultUITestCase {
    /// Every Share button on the page. (Each is labelled "Share <title>", as Open and Hide are.)
    private var shareButtons: XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Share "))
    }

    /// Says something to the canvas and sends it.
    private func say(_ words: String) {
        enter(words, into: textField("canvas.field"), "the canvas field")
        tap(element("canvas.send"), "Send")
    }

    func testAPageAndAGroupOfferShareAndItOpensThePeopleSheetOverThePage() {
        launch(.signedIn)

        step("Showing my files puts pages and a group on the page, each with Share") {
            say("show my files")
            for title in ["Bakery landing page", "Trip to Lisbon", "Portfolio site"] {
                require(button("Open \(title)"), "the card of \(title)")
                require(button("Share \(title)"), "Share on the card of \(title)")
            }
            require(element("canvas.share.bakery-landing-page-x1"), "Share on the Bakery card, by its identifier")
            // Open, Share and Hide share one row at the default text size, and Share is not broken over two lines.
            let share = button("Share Bakery landing page")
            XCTAssertLessThan(share.frame.height, 60, "Share is \(share.frame.height) points tall, so its label has wrapped.")
            for name in ["Open Bakery landing page", "Hide Bakery landing page"] {
                XCTAssertEqual(button(name).frame.midY, share.frame.midY, accuracy: 4, "\"\(name)\" should sit on Share's row.")
            }
        }

        step("Share opens the sheet of who has the page, read for this page") {
            tap(button("Share Bakery landing page"), "Share on the Bakery card", until: { self.element("artifact.share.email").exists })
            require(element("artifact.share.email"), "the field for an email address")
            require(shows("maya@example.com"), "Maya, who has the Bakery page (the sheet read who has it)")
            require(shows("/a/bakery-landing-page-x1"), "the page's link")
        }

        step("Done goes back to the cards as they were") {
            tap(button("Done"), "Done", until: { !self.element("artifact.share.email").exists })
            requireGone(element("artifact.share.email"), "the sheet")
            require(button("Share Bakery landing page"), "the card Share was tapped on")
            require(button("Share Trip to Lisbon"), "the other cards, which stay")
        }

        step("A group's card opens the same sheet, with the link on the group's address") {
            tap(button("Share Portfolio site"), "Share on the Portfolio card", until: { self.element("artifact.share.email").exists })
            require(element("artifact.share.email"), "the field for an email address")
            require(shows("/g/portfolio-site"), "the group's link")
            tap(button("Done"), "Done", until: { !self.element("artifact.share.email").exists })
            requireGone(element("artifact.share.email"), "the sheet")
        }
    }

    func testAMemoryAndAKeyHaveNoShare() {
        launch(.signedIn)

        step("A memory's card has Open and Hide and no Share") {
            say("show my memories")
            require(button("Open Trip to Lisbon: ferry and passports"), "the Lisbon memory's Open")
            require(button("Hide Trip to Lisbon: ferry and passports"), "the Lisbon memory's Hide")
            require(button("Hide Planning chat with Sam"), "the other memories' cards")
            XCTAssertEqual(shareButtons.count, 0, "A memory has no people to share with, and no Share button.")
        }

        step("A key's card has none either") {
            say("show my keys")
            require(button("Open OPENAI_API_KEY"), "the key's Open")
            require(button("Hide OPENAI_API_KEY"), "the key's Hide")
            XCTAssertEqual(shareButtons.count, 0, "A key is never shared, and no Share button was drawn for it.")
        }
    }
}
