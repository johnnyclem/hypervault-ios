import XCTest

/// Someone signed in who has no agent key: the Home page asks for one thing, a key for an agent. "Connect an agent" opens
/// the Connect sheet, and "I'll look around first" hides the card and tells the profile.
@MainActor
final class ConnectCardJourneyTests: HyperVaultUITestCase {
    func testTheCardAsksForAnAgentOpensTheSheetAndLooksAroundFirst() {
        launch(.signedInNoKeys)

        step("The Home page shows the card under its hints") {
            require(element("canvas.connectCard"), "the connect card")
            require(text("Hand this to your agent"), "the card's title")
            require(button("Connect an agent"), "the card's Connect an agent button")
            require(button("I'll look around first"), "the card's quiet way out")
            require(element("canvas.hint"), "the line that says to paste anything, which the card sits under")
        }

        step("Connect an agent opens the Connect sheet, and Cancel leaves the card where it was") {
            tap(element("canvas.connectCard.connect"), "Connect an agent", until: { self.isShowingTitle("Connect your AI") })
            waitUntil("the Connect your AI title") { isShowingTitle("Connect your AI") }
            tap(button("Cancel"), "Cancel")
            requireGone(button("Cancel"), "the sheet")
            require(element("canvas.connectCard"), "the card, since no key was made")
            requireNoWrite("PATCH", "/api/onboarding")
        }

        step("I'll look around first hides the card and tells the profile") {
            tap(element("canvas.connectCard.dismiss"), "I'll look around first")
            requireGone(element("canvas.connectCard"), "the connect card")
            requireWrite("PATCH", "/api/onboarding", equal: ["connect_dismissed": "true"])
            require(element("canvas.hint"), "the page's hints, which stay")
        }
    }
}
