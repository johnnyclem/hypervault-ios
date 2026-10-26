import XCTest

/// The screens the You tab opens, in the dark and at the largest accessibility text size (see `LayoutSweepTests`). They are
/// a class of their own so that CI runs them in a job of their own: there are many, and each is a screenshot and a scroll.
@MainActor
final class LayoutSweepScreensTests: LayoutSweepCase {
    // MARK: What the You tab opens

    func testTheYouScreensInTheDark() { sweepYouScreens(Self.dark) }

    func testTheYouScreensAtAnAccessibilityTextSize() { sweepYouScreens(Self.large) }

    private func sweepYouScreens(_ setting: Mode) {
        let mode = setting.name
        launch(.signedIn, arguments: setting.arguments)
        continueAfterFailure = true

        let screens: [(row: String, title: String, name: String, key: () -> XCUIElement, what: String)] = [
            ("settings", "Settings", "Settings", { self.toggle("Haptics") }, "the Haptics switch"),
            ("library", "Library", "Library", { self.element("library.row.a1") }, "the Bakery landing page row"),
            ("agentsAndKeys", "Account & keys", "Account & keys", { self.element("keys.connect") }, "Connect an agent"),
            ("vaultItems", "Logins, cards & keys", "Logins, cards & keys", { self.element("vault.row.github.com") }, "the github.com entry"),
            ("mail", "Mail", "Mail", { self.element("mail.thread.11111111-1111-4111-8111-111111111111") }, "the Weekly plan thread"),
            ("truth", "Truth", "Truth", { self.element("truth.review") }, "the review row"),
            ("tools", "Tools", "Tools", { self.element("tools.server.s1") }, "the Linear server"),
            ("realms", "Your address", "Your address", { self.element("realms.row.c1") }, "the nova.vault.cool address"),
            ("importHistory", "Import", "Import", { self.element("import.source.chatgpt") }, "the ChatGPT card"),
            ("dreams", "Dreams", "Dreams", { self.shows("Dream every night") }, "the nightly switch"),
            ("digest", "Digest", "Digest", { self.shows("Planning chat with Sam") }, "the memory to split"),
            ("taskBoards", "Task boards", "Task boards", { self.element("taskboards.row.eurorack-choir") }, "the Eurorack Choir board"),
        ]
        for screen in screens {
            openFromYou(screen.row, title: screen.title)
            look(mode, screen.name, key: screen.key(), screen.what)
        }

        // One level further in, where the layouts are different again. (In the dark, the screens above show the palette on
        // every surface the app has; the second level is looked at at the large text size, where the layouts break.)
        guard setting.name == "large" else { return }
        openFromYou("taskBoards", title: "Task boards")
        open(element("taskboards.row.eurorack-choir"), "the Eurorack Choir board")
        look(mode, "a task board", key: element("taskboard.task.t-panels"), "the front panels task")
        open(element("taskboard.task.t-panels"), "the front panels task")
        look(mode, "a task", key: shows("Two quotes in, one to go."), "the agent's note")

        openFromYou("truth", title: "Truth")
        open(element("truth.entry.01M1E6JK8SQAJ8K0JBRHTD10YG"), "the retry cap entry")
        look(mode, "a truth entry", key: shows("The retry budget is 100."), "the premise beneath it")

        openFromYou("mail", title: "Mail")
        open(element("mail.thread.11111111-1111-4111-8111-111111111111"), "the Weekly plan thread")
        look(mode, "a mail thread", key: shows("Done. Friday it is, and I updated the page."), "the newest message")

        openFromYou("vaultItems", title: "Logins, cards & keys")
        open(element("vault.row.github.com"), "the github.com entry")
        look(mode, "a vault entry", key: shows("How an agent reads it"), "the section that says how an agent reads it")

        openFromYou("realms", title: "Your address")
        open(element("realms.row.c1"), "the nova.vault.cool address")
        look(mode, "an address", key: shows("Glassmorphism"), "the look it has")

        openFromYou("agentsAndKeys", title: "Account & keys")
        open(element("keys.row.k1"), "the Claude Code key")
        look(mode, "a key", key: shows("Revoke key"), "the Revoke key row")

        openFromYou("agentsAndKeys", title: "Account & keys")
        open(element("keys.connect"), "Connect an agent")
        look(mode, "Connect your AI", key: shows("Just make a key"), "the way to make a key for anything not listed")
        enter("Cursor", into: searchField("Search apps, like Cursor or curl"), "the app search")
        open(element("connect.client.cursor"), "the Cursor row")
        open(button("Make the key"), "Make the key")
        look(mode, "a key, just made", key: button("Copy key"), "the Copy key button")
    }
}
