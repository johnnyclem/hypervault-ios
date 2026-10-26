import XCTest

/// Looks for layout bugs: the main screens, launched in the dark appearance and at an accessibility text size (the
/// second-largest the system offers), with a screenshot of each and a note of what its tree says about tap targets and
/// anything drawn off the screen. The test checks only that the key control of each screen is there and can be tapped;
/// what is wrong with the layout is for a person to see in the screenshots (the CI run publishes them), which is how a
/// Share button broken over two lines was found.
///
/// A screen that fails its check does not stop the sweep: the rest are still looked at, and the failures say which.
@MainActor
final class LayoutSweepTests: HyperVaultUITestCase {
    private static let dark = ["-AppleInterfaceStyle", "Dark"]
    private static let large = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

    // MARK: The tabs

    func testTheTabsInTheDark() { sweepTabs("dark", Self.dark) }

    func testTheTabsAtAnAccessibilityTextSize() { sweepTabs("large", Self.large) }

    private func sweepTabs(_ mode: String, _ arguments: [String]) {
        launch(.signedIn, arguments: arguments)
        continueAfterFailure = true

        look(mode, "canvas with its hints", key: element("canvas.field"), "the canvas field", dumpTree: true)

        step("\(mode): the canvas puts memories on the page") {
            enter("show my memories", into: textField("canvas.field"), "the canvas field")
            tap(element("canvas.send"), "Send")
            require(button("Hide Trip to Lisbon: ferry and passports"), "the Lisbon memory's card")
        }
        look(mode, "canvas with cards", key: element("canvas.field"), "the canvas field")

        openTab("Yours")
        look(mode, "Yours", key: element("yours.row.a1"), "the Bakery landing page row")
        openTab("Memory")
        look(mode, "Memory", key: element("memory.row.m1"), "the Lisbon memory row")
        openTab("Chat")
        look(mode, "Chat", key: element("chat.row.c1"), "the Lisbon conversation row")
        choose("Rooms", from: "chat.section")
        look(mode, "Chat, rooms", key: element("chat.room.r1"), "the Features X and Y room row")
        openTab("You")
        look(mode, "You", key: element("you.profile"), "the profile card")
    }

    // MARK: What the You tab opens

    func testTheYouScreensInTheDark() { sweepYouScreens("dark", Self.dark) }

    func testTheYouScreensAtAnAccessibilityTextSize() { sweepYouScreens("large", Self.large) }

    private func sweepYouScreens(_ mode: String, _ arguments: [String]) {
        launch(.signedIn, arguments: arguments)
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

        // One level further in, where the layouts are different again.
        openFromYou("taskBoards", title: "Task boards")
        tap(element("taskboards.row.eurorack-choir"), "the Eurorack Choir board")
        look(mode, "a task board", key: element("taskboard.task.t-panels"), "the front panels task")
        tap(element("taskboard.task.t-panels"), "the front panels task")
        look(mode, "a task", key: shows("Two quotes in, one to go."), "the agent's note")

        openFromYou("truth", title: "Truth")
        tap(element("truth.entry.01M1E6JK8SQAJ8K0JBRHTD10YG"), "the retry cap entry")
        look(mode, "a truth entry", key: shows("The retry budget is 100."), "the premise beneath it")

        openFromYou("mail", title: "Mail")
        tap(element("mail.thread.11111111-1111-4111-8111-111111111111"), "the Weekly plan thread")
        look(mode, "a mail thread", key: shows("Done. Friday it is, and I updated the page."), "the newest message")

        openFromYou("vaultItems", title: "Logins, cards & keys")
        tap(element("vault.row.github.com"), "the github.com entry")
        look(mode, "a vault entry", key: shows("How an agent reads it"), "the section that says how an agent reads it")

        openFromYou("realms", title: "Your address")
        tap(element("realms.row.c1"), "the nova.vault.cool address")
        look(mode, "an address", key: shows("Glassmorphism"), "the look it has")

        openFromYou("agentsAndKeys", title: "Account & keys")
        tap(element("keys.row.k1"), "the Claude Code key")
        look(mode, "a key", key: shows("Revoke key"), "the Revoke key row")

        openFromYou("agentsAndKeys", title: "Account & keys")
        tap(element("keys.connect"), "Connect an agent")
        look(mode, "Connect your AI", key: shows("Just make a key"), "the way to make a key for anything not listed")
        enter("Cursor", into: searchField("Search apps, like Cursor or curl"), "the app search")
        tap(element("connect.client.cursor"), "the Cursor row")
        tap(button("Make the key"), "Make the key")
        look(mode, "a key, just made", key: button("Copy key"), "the Copy key button")
    }

    // MARK: Memory, chat and a page

    func testWhatTheTabsOpenInTheDark() { sweepOpened("dark", Self.dark) }

    func testWhatTheTabsOpenAtAnAccessibilityTextSize() { sweepOpened("large", Self.large) }

    private func sweepOpened(_ mode: String, _ arguments: [String]) {
        launch(.signedIn, arguments: arguments)
        continueAfterFailure = true

        openTab("Memory")
        tap(element("memory.row.m1"), "the Lisbon memory")
        look(mode, "a memory", key: shows("Lisbon, first weekend"), "the heading inside the memory's text")
        goBack()

        openTab("Chat")
        tap(element("chat.row.c1"), "the Lisbon conversation")
        look(mode, "a conversation", key: textField("Message"), "the message field")
        goBack()
        choose("Rooms", from: "chat.section")
        tap(element("chat.room.r1"), "the Features X and Y room")
        look(mode, "a room", key: textField("Message"), "the message field")

        openFromYou("library", title: "Library")
        tap(element("library.row.a1"), "the Bakery landing page row")
        look(mode, "a page", key: element("artifact.share"), "the Share action")
        tap(element("artifact.share"), "Share")
        look(mode, "the Share sheet", key: button("Done"), "Done")
        tap(button("Done"), "Done")
    }

    // MARK: Before anyone is in

    func testTheWelcomeAndTheWaitlistInTheDark() { sweepWelcome("dark", Self.dark) }

    func testTheWelcomeAndTheWaitlistAtAnAccessibilityTextSize() { sweepWelcome("large", Self.large) }

    private func sweepWelcome(_ mode: String, _ arguments: [String]) {
        launch(.signedOut, arguments: arguments)
        continueAfterFailure = true

        for page in 1...4 {
            look(mode, "welcome page \(page)", key: element("welcome.continue"), "the Continue button", dumpTree: page == 1)
            if page < 4 { tap(element("welcome.continue"), "Continue") }
        }
        tap(element("welcome.continue"), "Get started")
        look(mode, "the way in", key: element("signin.email"), "Continue with email")
        tap(element("signin.email"), "Continue with email")
        look(mode, "the email sheet", key: element("email.send"), "the Send me a code button")

        launch(.waitlisted, arguments: arguments)
        continueAfterFailure = true
        look(mode, "the waitlist", key: element("waitlist.code"), "the invite code field")
    }

    // MARK: Looking

    /// Checks the key control of a screen is there and can be tapped, writes down what its tree says about the layout, and
    /// keeps a screenshot named for the mode and the screen.
    private func look(_ mode: String, _ screen: String, key: XCUIElement, _ what: String, dumpTree: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
        step("\(mode): \(screen)") {
            require(key, what, file: file, line: line)
            if key.exists {
                XCTAssertTrue(key.isHittable, "\(what) is on the \(screen) screen (\(mode)) but cannot be tapped.", file: file, line: line)
            }
            let tree = app.debugDescription
            let notes = LayoutReport.notes(from: tree)
            let report = notes.isEmpty ? "Nothing to note: every control is at least 44 points and nothing is off the screen." : notes.joined(separator: "\n")
            print("[layout] \(mode) / \(screen): \(notes.count) notes\n\(report)")
            let attachment = XCTAttachment(string: "\(mode) / \(screen)\n\n\(report)\n")
            attachment.name = "Layout notes - \(mode) - \(screen)"
            attachment.lifetime = .keepAlways
            add(attachment)
            if dumpTree {
                let raw = XCTAttachment(string: String(tree.prefix(30_000)))
                raw.name = "Tree - \(mode) - \(screen)"
                raw.lifetime = .keepAlways
                add(raw)
            }
        }
    }
}
