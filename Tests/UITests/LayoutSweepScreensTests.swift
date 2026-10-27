import XCTest

/// The screens the You tab opens, and the ones one step beyond them, in the dark and at the largest accessibility text size
/// (see `LayoutSweepTests`). They are a class of their own so that CI runs them in jobs of their own: there are many, and each
/// is a screenshot and a scroll.
@MainActor
final class LayoutSweepScreensTests: LayoutSweepCase {
    /// The You tab is long, and every screen of it at the large text size is a scroll and a screenshot: in two halves CI can run
    /// them in two jobs. In the dark they are quick, and one test goes through them all.
    enum Part {
        case all
        case keepAndAgents
        case thinkAndAccount
    }

    func testTheYouScreensInTheDark() { sweepYouScreens(Self.dark, .all) }

    func testTheKeepAndAgentScreensAtAnAccessibilityTextSize() { sweepYouScreens(Self.large, .keepAndAgents) }

    func testTheThinkAndAccountScreensAtAnAccessibilityTextSize() { sweepYouScreens(Self.large, .thinkAndAccount) }

    /// Goes down the You tab the way a person would, top to bottom, so that its list is scrolled once and not once per
    /// screen: each row is opened and looked at, then the screens it leads to, then the way is made back to the list.
    private func sweepYouScreens(_ setting: Mode, _ part: Part) {
        launch(.signedIn, arguments: setting.arguments)
        continueAfterFailure = true
        if part != .thinkAndAccount { keepAndAgentScreens(setting.name) }
        if part != .keepAndAgents { thinkAndAccountScreens(setting.name) }
    }

    /// Opens a row of the You tab and looks at the screen; `further` looks at what that screen opens.
    private func visit(_ mode: String, _ row: String, _ title: String, key: XCUIElement, _ what: String, further: () -> Void = {}) {
        openFromYou(row, title: title)
        look(mode, title, key: key, what)
        further()
    }

    private func keepAndAgentScreens(_ mode: String) {
        visit(mode, "library", "Library", key: element("library.row.a1"), "the Bakery landing page row")

        visit(mode, "vaultItems", "Logins, cards & keys", key: element("vault.row.github.com"), "the github.com entry") {
            open(element("vault.row.github.com"), "the github.com entry", until: { self.isShowingTitle("github.com") })
            look(mode, "a vault entry", key: shows("How an agent reads it"), "the section that says how an agent reads it")
        }

        visit(mode, "taskBoards", "Task boards", key: element("taskboards.row.eurorack-choir"), "the Eurorack Choir board") {
            open(element("taskboards.row.eurorack-choir"), "the Eurorack Choir board", until: { self.isShowingTitle("Eurorack Choir Module") })
            look(mode, "a task board", key: element("taskboard.task.t-panels"), "the front panels task")
            open(element("taskboard.task.t-panels"), "the front panels task", until: { self.isShowingTitle("Task") })
            look(mode, "a task", key: shows("Two quotes in, one to go."), "the agent's note")
        }

        visit(mode, "agentsAndKeys", "Agent keys", key: element("keys.connect"), "Connect an agent") {
            open(element("keys.row.k1"), "the Claude Code key", until: { self.isShowingTitle("Key") })
            look(mode, "a key", key: button("Revoke"), "the Revoke button")
            goBack()

            open(element("keys.connect"), "Connect an agent", until: { self.isShowingTitle("Connect your AI") })
            look(mode, "Connect your AI", key: shows("Just make a key"), "the way to make a key for anything not listed")
            open(element("connect.client.cursor"), "the Cursor row", until: { self.isShowingTitle("Cursor") })
            attachScreenshot("\(mode) - the Cursor screen")
            open(button("Make the key"), "Make the key")
            look(mode, "a key, just made", key: button("Copy key"), "the Copy key button")
            // A key that was never copied is not let go of without asking, so it is copied first, as a person would; then
            // the sheet is closed the way a person closes it, so that the next screen is the list again.
            open(button("Copy key"), "Copy key")
            let back = app.navigationBars.buttons.matching(NSPredicate(format: "label == %@", "Connect your AI")).firstMatch
            if back.exists { tap(back, "the back button to Connect your AI") }
            tap(button("Done"), "Done")
        }

        visit(mode, "tools", "Tools", key: element("tools.server.s1"), "the Linear server") {
            open(element("tools.server.s1"), "the Linear server", until: { self.isShowingTitle("Linear") })
            look(mode, "a tool server", key: shows("list_issues"), "the list_issues tool")
        }

        visit(mode, "mail", "Mail", key: element("mail.thread.11111111-1111-4111-8111-111111111111"), "the Weekly plan thread") {
            open(element("mail.thread.11111111-1111-4111-8111-111111111111"), "the Weekly plan thread", until: { self.isShowingTitle("Weekly plan") })
            look(mode, "a mail thread", key: shows("Done. Friday it is, and I updated the page."), "the newest message")
        }
    }

    private func thinkAndAccountScreens(_ mode: String) {
        visit(mode, "dreams", "Dreams", key: shows("Dream every night"), "the nightly switch")

        visit(mode, "digest", "Digest", key: shows("Planning chat with Sam"), "the memory to split")

        visit(mode, "truth", "Truth", key: element("truth.review"), "the review row") {
            open(element("truth.entry.01M1E6JK8SQAJ8K0JBRHTD10YG"), "the retry cap entry", until: { self.isShowingTitle("Signed truth") })
            look(mode, "a truth entry", key: shows("The retry budget is 100."), "the premise beneath it")
        }

        visit(mode, "realms", "Your address", key: element("realms.row.c1"), "the nova.vault.cool address") {
            open(element("realms.row.c1"), "the nova.vault.cool address", until: { self.isShowingTitle("Address") })
            look(mode, "an address", key: shows("Glassmorphism"), "the look it has")
        }

        visit(mode, "importHistory", "Import", key: element("import.source.chatgpt"), "the ChatGPT card") {
            open(element("import.source.other"), "the Something else card")
            look(mode, "the paste box", key: app.textViews["Pasted conversation"], "the paste box")
        }

        visit(mode, "settings", "Settings", key: toggle("Haptics"), "the Haptics switch")
    }
}
