import XCTest

/// The screens the You tab opens, and the ones one step beyond them, in the dark and at the largest accessibility text size
/// (see `LayoutSweepTests`). They are a class of their own so that CI runs them in jobs of their own: there are many, and each
/// is a screenshot and a scroll.
@MainActor
final class LayoutSweepScreensTests: LayoutSweepCase {
    func testTheYouScreensInTheDark() { sweepYouScreens(Self.dark) }

    func testTheYouScreensAtAnAccessibilityTextSize() { sweepYouScreens(Self.large) }

    /// Goes down the You tab the way a person would, top to bottom, so that its list is scrolled once and not once per
    /// screen: each row is opened and looked at, then the screens it leads to, then the way is made back to the list.
    private func sweepYouScreens(_ setting: Mode) {
        let mode = setting.name
        launch(.signedIn, arguments: setting.arguments)
        continueAfterFailure = true

        /// Opens a row of the You tab and looks at the screen; `further` looks at what that screen opens.
        func visit(_ row: String, _ title: String, key: XCUIElement, _ what: String, further: () -> Void = {}) {
            openFromYou(row, title: title)
            look(mode, title, key: key, what)
            further()
        }

        // Keep
        visit("library", "Library", key: element("library.row.a1"), "the Bakery landing page row")

        visit("vaultItems", "Logins, cards & keys", key: element("vault.row.github.com"), "the github.com entry") {
            open(element("vault.row.github.com"), "the github.com entry")
            look(mode, "a vault entry", key: shows("How an agent reads it"), "the section that says how an agent reads it")
        }

        visit("taskBoards", "Task boards", key: element("taskboards.row.eurorack-choir"), "the Eurorack Choir board") {
            open(element("taskboards.row.eurorack-choir"), "the Eurorack Choir board")
            look(mode, "a task board", key: element("taskboard.task.t-panels"), "the front panels task")
            open(element("taskboard.task.t-panels"), "the front panels task")
            look(mode, "a task", key: shows("Two quotes in, one to go."), "the agent's note")
        }

        // Agents
        visit("agentsAndKeys", "Account & keys", key: element("keys.connect"), "Connect an agent") {
            open(element("keys.row.k1"), "the Claude Code key")
            look(mode, "a key", key: shows("Revoke key"), "the Revoke key row")
            goBack()

            open(element("keys.connect"), "Connect an agent")
            look(mode, "Connect your AI", key: shows("Just make a key"), "the way to make a key for anything not listed")
            open(element("connect.client.cursor"), "the Cursor row")
            open(button("Make the key"), "Make the key")
            look(mode, "a key, just made", key: button("Copy key"), "the Copy key button")
            // A key that was never copied is not let go of without asking, so it is copied first, as a person would; then
            // the sheet is closed the way a person closes it, so that the next screen is the list again.
            open(button("Copy key"), "Copy key")
            let back = app.navigationBars.buttons.matching(NSPredicate(format: "label == %@", "Connect your AI")).firstMatch
            if back.exists { tap(back, "the back button to Connect your AI") }
            tap(button("Done"), "Done")
        }

        visit("tools", "Tools", key: element("tools.server.s1"), "the Linear server") {
            open(element("tools.server.s1"), "the Linear server")
            look(mode, "a tool server", key: shows("list_issues"), "the list_issues tool")
        }

        visit("mail", "Mail", key: element("mail.thread.11111111-1111-4111-8111-111111111111"), "the Weekly plan thread") {
            open(element("mail.thread.11111111-1111-4111-8111-111111111111"), "the Weekly plan thread")
            look(mode, "a mail thread", key: shows("Done. Friday it is, and I updated the page."), "the newest message")
        }

        // Think
        visit("dreams", "Dreams", key: shows("Dream every night"), "the nightly switch")

        visit("digest", "Digest", key: shows("Planning chat with Sam"), "the memory to split")

        visit("truth", "Truth", key: element("truth.review"), "the review row") {
            open(element("truth.entry.01M1E6JK8SQAJ8K0JBRHTD10YG"), "the retry cap entry")
            look(mode, "a truth entry", key: shows("The retry budget is 100."), "the premise beneath it")
        }

        // Account
        visit("realms", "Your address", key: element("realms.row.c1"), "the nova.vault.cool address") {
            open(element("realms.row.c1"), "the nova.vault.cool address")
            look(mode, "an address", key: shows("Glassmorphism"), "the look it has")
        }

        visit("importHistory", "Import", key: element("import.source.chatgpt"), "the ChatGPT card") {
            open(element("import.source.other"), "the Something else card")
            look(mode, "the paste box", key: app.textViews["Pasted conversation"], "the paste box")
        }

        visit("settings", "Settings", key: toggle("Haptics"), "the Haptics switch")
    }
}
