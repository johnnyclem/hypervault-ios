import XCTest

/// The canvas of someone signed in, with a connected model: keeping a pasted note, asking and keeping the reply, hiding a
/// card, saying "show my memories", and the Yours panel over the page.
@MainActor
final class CanvasJourneyTests: HyperVaultUITestCase {
    private let keptLine = "Kept. Here's the link."

    func testKeepAPasteAskAndKeepTheReplyThenHideACard() {
        launch(.signedIn)

        step("The canvas opens with its one line of help") {
            require(element("canvas.hint"), "the line that says to paste anything")
            XCTAssertEqual(element("canvas.hint").label, "Paste anything here to keep it.")
            require(button("Account"), "the avatar, labelled \"Account\" for VoiceOver")
            require(button("Open panel"), "the corner icon, labelled \"Open panel\" for VoiceOver, as the web labels it")
        }

        step("A long paste waits above the field") {
            // The harness left a note on the pasteboard; the canvas offers the system's Paste button for it.
            tapPaste(until: { self.element("canvas.pasted").exists })
            let chip = element("canvas.pasted")
            require(chip, "the chip that says what was pasted")
            XCTAssertTrue(chip.label.hasPrefix("Pasted - "), "The chip says \"\(chip.label)\".")
            require(element("canvas.keep"), "Keep it")
            require(element("canvas.askInstead"), "Ask instead, offered because a model is connected")
        }

        step("Keep it makes a card with its private link") {
            tap(element("canvas.keep"), "Keep it")
            require(text(keptLine), "the card's \"Kept. Here's the link.\"")
            require(text("Only you can open it."), "the line that says the link is private")
            require(text("https://uitest.hypervault.invalid/a/lisbon-trip-checklist-k1"), "the card's link")
            require(button("Hide Lisbon trip checklist"), "the card's Hide button")
            require(button("Copy link"), "the card's Copy link button")
            // At the default text size the four actions share one row, and Share is not broken over two lines
            // ("Shar" over "e" was what a first run of this screen showed).
            let share = button("Share")
            require(share, "the card's Share button")
            XCTAssertLessThan(share.frame.height, 60, "Share is \(share.frame.height) points tall, so its label has wrapped.")
            for name in ["Open Lisbon trip checklist", "Copy link", "Hide Lisbon trip checklist"] {
                XCTAssertEqual(button(name).frame.midY, share.frame.midY, accuracy: 4, "\"\(name)\" should sit on Share's row.")
            }
            requireGone(element("canvas.pasted"), "the chip, now that it is kept")
        }

        step("A typed note is answered by the model") {
            enter("Remember to buy milk on Friday", into: textField("canvas.field"), "the canvas field")
            tap(element("canvas.send"), "Send")
            require(text("You said: Remember to buy milk on Friday"), "the note as it was sent")
            require(text("Reply: Noted: Remember to buy milk on Friday"), "the model's reply")
        }

        step("The reply can be kept too") {
            tap(button("Keep this reply"), "Keep this reply")
            waitUntil("a second kept card") { count(ofText: keptLine) == 2 }
        }

        step("Hide takes a card off the page and nothing else") {
            tap(button("Hide Noted: Remember to buy milk on Friday"), "Hide on the card of the kept reply")
            requireGone(button("Hide Noted: Remember to buy milk on Friday"), "the hidden card")
            XCTAssertEqual(count(ofText: keptLine), 1, "Only the card that was hidden should have gone.")
            require(button("Hide Lisbon trip checklist"), "the other card, which should stay")
        }
    }

    func testShowMyMemoriesPutsThemOnThePageAndYoursOpensOverIt() {
        launch(.signedIn)

        step("Saying \"show my memories\" puts them on the page") {
            enter("show my memories", into: textField("canvas.field"), "the canvas field")
            tap(element("canvas.send"), "Send")
            require(button("Hide Trip to Lisbon: ferry and passports"), "the Lisbon memory's card")
            require(button("Hide Auth decision: passkeys first"), "the auth memory's card")
            require(button("Hide Planning chat with Sam"), "the planning memory's card")
            require(button("Open Planning chat with Sam"), "a card's Open button, labelled with its title")
        }

        step("Hide removes one memory's card") {
            tap(button("Hide Auth decision: passkeys first"), "Hide on the auth card")
            requireGone(button("Hide Auth decision: passkeys first"), "the hidden card")
            require(button("Hide Planning chat with Sam"), "the other cards, which should stay")
        }

        step("The Yours panel opens over the page") {
            tap(button("Open panel"), "Open panel")
            require(button("Done"), "the panel's Done button")
            require(element("yours.row.a1"), "the panel's first row")
        }

        step("Done closes the panel") {
            tap(button("Done"), "Done", until: { !self.button("Done").exists })
            requireGone(button("Done"), "the panel")
            require(button("Hide Planning chat with Sam"), "the page as it was left")
        }
    }
}
