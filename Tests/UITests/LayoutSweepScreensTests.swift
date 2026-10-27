import XCTest

/// The screens the You panes and the Account menu open, and the ones one step beyond them, in the dark and at the largest
/// accessibility text size (see `LayoutSweepTests`). They are a class of their own so that CI runs them in jobs of their own:
/// there are many, and each is a screenshot and a scroll.
@MainActor
final class LayoutSweepScreensTests: LayoutSweepCase {
    /// There are many screens, and every one of them at the large text size is a scroll and a screenshot: in two halves CI can
    /// run them in two jobs. In the dark they are quick, and one test goes through them all.
    enum Part {
        case all
        case keepAndAgents
        case thinkAndAccount
    }

    /// Where a screen is opened from.
    enum Door {
        /// A pane of the You tab, by id; the heading to wait for when the screen names itself the same on every build.
        case pane(String, title: String?)
        /// A row of the Account menu behind the avatar, by id.
        case account(String)
        /// An item of Memory's More menu.
        case memoryMenu(String)
    }

    func testTheYouScreensInTheDark() { sweepYouScreens(Self.dark, .all) }

    func testTheKeepAndAgentScreensAtAnAccessibilityTextSize() { sweepYouScreens(Self.large, .keepAndAgents) }

    func testTheThinkAndAccountScreensAtAnAccessibilityTextSize() { sweepYouScreens(Self.large, .thinkAndAccount) }

    /// Goes through the seven panes and the Account menu's screens the way a person would, each one opened and looked at, then
    /// the screens it leads to.
    private func sweepYouScreens(_ setting: Mode, _ part: Part) {
        launch(.signedIn, arguments: setting.arguments)
        continueAfterFailure = true
        if part != .thinkAndAccount { keepAndAgentScreens(setting.name) }
        if part != .keepAndAgents { thinkAndAccountScreens(setting.name) }
    }

    /// Opens a screen and looks at it; `further` looks at what that screen opens.
    private func visit(_ mode: String, _ door: Door, _ screen: String, title: String? = nil, key: XCUIElement, _ what: String, further: () -> Void = {}) {
        switch door {
        case .pane(let id, let heading): openPane(id, title: heading)
        case .account(let id): openFromAccount(id, title: title ?? screen)
        case .memoryMenu(let item): openFromMemoryMenu(item, title: title ?? screen)
        }
        look(mode, screen, key: key, what)
        further()
    }

    private func keepAndAgentScreens(_ mode: String) {
        visit(mode, .account("library"), "Library", key: element("library.row.a1"), "the Bakery landing page row")

        visit(mode, .pane("vault", title: "Vault"), "Vault", key: element("vault.row.github.com"), "the github.com entry") {
            open(element("vault.row.github.com"), "the github.com entry", until: { self.isShowingTitle("github.com") })
            look(mode, "a vault entry", key: shows("How an agent reads it"), "the section that says how an agent reads it")
            // The entry is a sheet over the list: close it, so the next screen starts from the You tab.
            tap(button("Close"), "the entry's Close button")
        }

        visit(mode, .account("taskBoards"), "Task boards", key: element("taskboards.row.eurorack-choir"), "the Eurorack Choir board") {
            open(element("taskboards.row.eurorack-choir"), "the Eurorack Choir board", until: { self.isShowingTitle("Eurorack Choir Module") })
            look(mode, "a task board", key: element("taskboard.task.t-panels"), "the front panels task")
            open(element("taskboard.task.t-panels"), "the front panels task", until: { self.isShowingTitle("Task") })
            look(mode, "a task", key: shows("Two quotes in, one to go."), "the agent's note")
        }

        visit(mode, .pane("keys", title: nil), "Agent keys", key: element("keys.connect"), "Connect an agent") {
            open(element("keys.row.k1"), "the Claude Code key", until: { self.isShowingTitle("Key") })
            look(mode, "a key", key: button("Revoke"), "the Revoke button")
            goBack(until: { self.isShowingTitle("Agent keys") })

            open(element("keys.connect"), "Connect an agent", until: { self.isShowingTitle("Connect your AI") })
            look(mode, "Connect your AI", key: shows("Just make a key"), "the way to make a key for anything not listed")
            // The app is found the way a person finds one in a long list, by its name: the sheet's search field floats over the
            // list, and scrolling a row out from under it (and from the sheet's own pull-down to close) is not reliable.
            enter("Cursor", into: searchField("Search apps, like Cursor or curl"), "the app search")
            // The keyboard goes away before the page is scrolled: a drag that starts on the keyboard types, and the list that was
            // searched for is lost.
            putTheKeyboardAway()
            open(element("connect.client.cursor"), "the Cursor row", until: { self.isShowingTitle("Cursor") }, clearOfSearch: true)
            attachScreenshot("\(mode) - the Cursor screen")
            open(button("Make the key"), "Make the key")
            look(mode, "a key, just made", key: button("Copy key"), "the Copy key button")
            // A key that was never copied is not let go of without asking, so it is copied first, as a person would; then
            // the sheet is closed the way a person closes it, so that the next screen is the list again.
            open(button("Copy key"), "Copy key")
            let back = app.navigationBars.buttons.matching(NSPredicate(format: "label == %@", "Connect your AI")).firstMatch
            if back.exists { tap(back, "the back button to Connect your AI") }
            // The search is still open, and while it is open its own close button stands where Done is.
            if !button("Done").exists, button("Close").exists { tap(button("Close"), "the search's close button") }
            tap(button("Done"), "Done")
        }

        visit(mode, .pane("backends", title: "Models"), "Models", key: shows("What answers when you ask something"), "the pane's description")

        visit(mode, .account("tools"), "Tools", key: element("tools.server.s1"), "the Linear server") {
            open(element("tools.server.s1"), "the Linear server", until: { self.isShowingTitle("Linear") })
            look(mode, "a tool server", key: shows("list_issues"), "the list_issues tool")
        }

        visit(mode, .account("mail"), "Mail", key: element("mail.thread.11111111-1111-4111-8111-111111111111"), "the Weekly plan thread") {
            open(element("mail.thread.11111111-1111-4111-8111-111111111111"), "the Weekly plan thread", until: { self.isShowingTitle("Weekly plan") })
            look(mode, "a mail thread", key: shows("Done. Friday it is, and I updated the page."), "the newest message")
        }
    }

    private func thinkAndAccountScreens(_ mode: String) {
        visit(mode, .account("dreams"), "Dreams", key: shows("Dream every night"), "the nightly switch")

        visit(mode, .memoryMenu("Digest"), "Digest", key: shows("Planning chat with Sam"), "the memory to split")

        visit(mode, .account("truth"), "Truth", key: element("truth.review"), "the review row") {
            open(element("truth.entry.01M1E6JK8SQAJ8K0JBRHTD10YG"), "the retry cap entry", until: { self.isShowingTitle("Signed truth") })
            look(mode, "a truth entry", key: shows("The retry budget is 100."), "the premise beneath it")
        }

        visit(mode, .pane("domain", title: "Domain"), "Domain", key: element("realms.row.c1"), "the nova.vault.cool address") {
            open(element("realms.row.c1"), "the nova.vault.cool address", until: { self.isShowingTitle("Address") })
            look(mode, "an address", key: shows("Glassmorphism"), "the look it has")
        }

        visit(mode, .pane("import", title: "Import"), "Import", key: element("import.history"), "the history button") {
            open(element("import.history"), "Import your AI history", until: { self.element("import.source.chatgpt").exists })
            look(mode, "the history importer", key: element("import.source.chatgpt"), "the ChatGPT card")
            open(element("import.source.other"), "the Something else card")
            look(mode, "the paste box", key: app.textViews["Pasted conversation"], "the paste box")
        }

        visit(mode, .pane("appearance", title: "Appearance"), "Appearance", key: element("appearance.theme"), "the theme picker")

        visit(mode, .pane("general", title: "General"), "General", key: toggle("Haptics"), "the Haptics switch")
    }
}
