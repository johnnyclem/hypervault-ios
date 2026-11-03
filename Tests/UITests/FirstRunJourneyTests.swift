import XCTest

/// Someone signed in who has kept nothing, has no chats and connected no model: Home's starter page offers the first things to
/// do, Start a chat opens an empty conversation, and Keep something opens the canvas, which teaches; the connect sheet opens,
/// an example chip finds nothing, Yours says it is empty.
@MainActor
final class FirstRunJourneyTests: HyperVaultUITestCase {
    func testHomeOffersTheFirstStepsAndStartAChatOpensAnEmptyConversation() {
        launch(.signedInEmpty)

        step("Home is the starter page, with no chats and nothing to search") {
            require(element("home.landing"), "the one line the starter page says")
            require(element("home.startChat"), "the Start a chat button")
            require(element("home.keepSomething"), "the Keep something button")
            require(element("home.starter"), "the Copy a starter prompt button")
            require(element("chat.section"), "the switch between chats and group chats, which stays above the starter page")
            let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.row.")).count
            XCTAssertEqual(rows, 0, "There are no chats to list.")
            XCTAssertEqual(app.searchFields.count, 0, "There is no search field: the starter page has nothing to search.")
            require(button("Keep"), "the Keep button in Home's bar")
            require(button("New chat"), "the New chat button in Home's bar")
        }

        step("Start a chat opens an empty conversation") {
            tap(element("home.startChat"), "Start a chat", until: { self.textField("Message").exists })
            require(textField("Message"), "the message field of a conversation with nothing in it")
        }

        step("Back is the starter page again") {
            goBack(until: { self.element("home.landing").exists })
            require(element("home.startChat"), "the Start a chat button")
        }
    }

    func testKeepSomethingOpensTheCanvasWhichTeachesConnectOpensItsSheetAndYoursIsEmpty() {
        launch(.signedInEmpty)

        step("Keep something opens the canvas, and Back comes home") {
            tap(element("home.keepSomething"), "Keep something", until: { self.element("canvas.field").exists })
            require(element("canvas.field"), "the canvas's field")
            goBack(until: { self.element("home.landing").exists })
            require(element("home.keepSomething"), "the starter page, which Back returns to")
        }

        step("The canvas shows the first-run hints") {
            openCanvas()
            require(element("canvas.hint"), "the line that says to paste anything")
            require(button("Show my memories"), "the Show my memories chip")
            require(button("Show my files"), "the Show my files chip")
            require(text("Connect your AI and it keeps things here for you."), "the line that says no model is connected")
            require(element("canvas.connect"), "the Connect your AI button")
        }

        step("Connect your AI opens a sheet, and Cancel closes it") {
            tap(element("canvas.connect"), "the Connect your AI button")
            waitUntil("the Connect your AI title") { isShowingTitle("Connect your AI") }
            tap(button("Cancel"), "Cancel", until: { !self.button("Cancel").exists })
            requireGone(button("Cancel"), "the sheet")
        }

        step("An example chip answers that there is nothing yet") {
            tap(button("Show my memories"), "the Show my memories chip")
            require(text("HyperVault: No memories yet."), "the page's own answer")
        }

        step("Yours says it is empty") {
            openYours()
            require(text("Nothing kept yet."), "Yours' empty state")
            require(text("Ask your AI to keep something, or paste it on the page."), "the empty state's hint")
        }
    }
}
