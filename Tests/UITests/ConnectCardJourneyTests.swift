import XCTest

/// Someone signed in who has no agent key (and no chats): Home's starter page asks for one thing, a key for an agent. "Connect
/// an agent" opens the Connect sheet, and "I'll look around first" hides the card and tells the profile. (The canvas, which
/// Keep something opens, shows the same card under its hints.)
@MainActor
final class ConnectCardJourneyTests: HyperVaultUITestCase {
    func testTheCardAsksForAnAgentOpensTheSheetAndLooksAroundFirst() {
        launch(.signedInNoKeys)

        step("Home's starter page shows the card under its buttons") {
            require(element("canvas.connectCard"), "the connect card")
            require(text("Hand this to your agent"), "the card's title")
            require(button("Connect an agent"), "the card's Connect an agent button")
            require(button("I'll look around first"), "the card's quiet way out")
            require(element("home.landing"), "the line the starter page says, which the card sits under")
        }

        step("Connect an agent opens the Connect sheet, and Cancel leaves the card where it was") {
            // (The card sits under the buttons, a scroll away on a phone: it is brought clear of the bars first.)
            open(element("canvas.connectCard.connect"), "Connect an agent", until: { self.isShowingTitle("Connect your AI") })
            waitUntil("the Connect your AI title") { isShowingTitle("Connect your AI") }
            tap(button("Cancel"), "Cancel", until: { !self.button("Cancel").exists })
            requireGone(button("Cancel"), "the sheet")
            require(element("canvas.connectCard"), "the card, since no key was made")
            requireNoWrite("PATCH", "/api/onboarding")
        }

        step("I'll look around first hides the card and tells the profile") {
            open(element("canvas.connectCard.dismiss"), "I'll look around first")
            requireGone(element("canvas.connectCard"), "the connect card")
            requireWrite("PATCH", "/api/onboarding", equal: ["connect_dismissed": "true"])
            require(element("home.landing"), "the starter page, which stays")
        }
    }
}
