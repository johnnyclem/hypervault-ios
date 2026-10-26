import XCTest

/// Someone signed in who has kept nothing and connected no model: the canvas teaches, the connect sheet opens, Yours
/// says it is empty.
@MainActor
final class FirstRunJourneyTests: HyperVaultUITestCase {
    func testTheCanvasTeachesConnectOpensItsSheetAndYoursIsEmpty() {
        launch(.signedInEmpty)

        step("The canvas shows the first-run hints") {
            require(element("canvas.hint"), "the line that says to paste anything")
            XCTAssertTrue(button("Show my memories").exists, "The example chips should be offered.")
            XCTAssertTrue(button("Show my files").exists, "The example chips should be offered.")
            require(text("Connect your AI and it keeps things here for you."), "the line that says no model is connected")
            require(element("canvas.connect"), "the Connect your AI button")
        }

        step("An example chip answers that there is nothing yet") {
            tap(button("Show my memories"), "the Show my memories chip")
            require(text("HyperVault: No memories yet."), "the page's own answer")
        }

        step("Connect your AI opens a sheet, and Cancel closes it") {
            tap(element("canvas.connect"), "the Connect your AI button")
            waitUntil("the Connect your AI title") { isShowingTitle("Connect your AI") }
            tap(button("Cancel"), "Cancel")
            requireGone(button("Cancel"), "the sheet")
        }

        step("Yours says it is empty") {
            openTab("Yours")
            require(text("Nothing kept yet."), "Yours' empty state")
            require(text("Ask your AI to keep something, or paste it on the canvas."), "the empty state's hint")
        }
    }
}
