import XCTest

/// Looks for layout bugs: the main screens, launched in the dark appearance and at an accessibility text size (the
/// second-largest the system offers), with a screenshot of each and a note of what its tree says about tap targets and
/// anything drawn off the screen. The test checks only that the key control of each screen is there and can be tapped;
/// what is wrong with the layout is for a person to see in the screenshots (the CI run publishes them), which is how a
/// Share button broken over two lines was found.
///
/// A screen that fails its check does not stop the sweep: the rest are still looked at, and the failures say which.
@MainActor
final class LayoutSweepTests: LayoutSweepCase {
    // MARK: The tabs

    func testTheTabsInTheDark() { sweepTabs(Self.dark) }

    func testTheTabsAtAnAccessibilityTextSize() { sweepTabs(Self.large) }

    private func sweepTabs(_ setting: Mode) {
        let mode = setting.name
        launch(.signedIn, arguments: setting.arguments)
        continueAfterFailure = true

        look(mode, "Home with its hints", key: element("canvas.field"), "the canvas field", dumpTree: true)

        openYours()
        // The panel opens at half the height of the screen, and at a large text size its first row is below the fold: it is
        // looked at as it opens, and then at its whole height, where the rows are (scrolling a half-height panel from the
        // page above it would put it away).
        attachScreenshot("\(mode) - Yours, as it opens")
        expandThePanel()
        look(mode, "Yours", key: element("yours.row.a1"), "the Bakery landing page row")
        tap(button("Done"), "Done")
        requireGone(element("yours.filter"), "the Yours panel")
        openTab("Chat")
        look(mode, "Chat", key: element("chat.row.c1"), "the Lisbon conversation row")
        choose("Group chats", from: "chat.section")
        look(mode, "Chat, group chats", key: element("chat.room.r1"), "the Features X and Y room row")
        openTab("Memory")
        look(mode, "Memory", key: element("memory.row.m1"), "the Lisbon memory row")
        openTab("You")
        look(mode, "You, the vault", key: element("vault.row.github.com"), "the github.com entry")
        showPaneList()
        look(mode, "You, the panes", key: element("you.pane.import"), "the Import pane")

        openAccountMenu()
        look(mode, "the Account menu", key: element("account.library"), "the Library row")
        tap(element("account.close"), "Close")
        // A tap on a tab while the menu is still going would land on the menu, which covers the tab bar.
        requireGone(element("account.close"), "the Account menu")

        // Last, because typing brings the keyboard up over the tab bar.
        openTab("Home")
        step("\(mode): the canvas puts memories on the page") {
            enter("show my memories", into: textField("canvas.field"), "the canvas field")
            tap(element("canvas.send"), "Send")
            require(button("Hide Trip to Lisbon: ferry and passports"), "the Lisbon memory's card")
        }
        look(mode, "Home with cards", key: element("canvas.field"), "the canvas field")
    }

    // MARK: Memory, chat and a page

    func testWhatTheTabsOpenInTheDark() { sweepOpened(Self.dark) }

    func testWhatTheTabsOpenAtAnAccessibilityTextSize() { sweepOpened(Self.large) }

    private func sweepOpened(_ setting: Mode) {
        let mode = setting.name
        launch(.signedIn, arguments: setting.arguments)
        continueAfterFailure = true

        openTab("Memory")
        open(element("memory.row.m1"), "the Lisbon memory")
        look(mode, "a memory", key: shows("Lisbon, first weekend"), "the heading inside the memory's text")
        goBack()

        openTab("Chat")
        open(element("chat.row.c1"), "the Lisbon conversation")
        look(mode, "a conversation", key: textField("Message"), "the message field")
        goBack()
        choose("Group chats", from: "chat.section")
        open(element("chat.room.r1"), "the Features X and Y room")
        look(mode, "a room", key: textField("room.field"), "the message field")

        openFromAccount("library", title: "Library")
        open(element("library.row.a1"), "the Bakery landing page row")
        look(mode, "a page", key: element("artifact.share"), "the Share action")
        open(element("artifact.share"), "Share")
        look(mode, "the Share sheet", key: button("Done"), "Done")
        tap(button("Done"), "Done")
    }

    // MARK: Before anyone is in

    func testTheWelcomeAndTheWaitlistInTheDark() { sweepWelcome(Self.dark) }

    func testTheWelcomeAndTheWaitlistAtAnAccessibilityTextSize() { sweepWelcome(Self.large) }

    private func sweepWelcome(_ setting: Mode) {
        let mode = setting.name
        launch(.signedOut, arguments: setting.arguments)
        continueAfterFailure = true

        for page in 1...4 {
            look(mode, "welcome page \(page)", key: element("welcome.continue"), "the Continue button", dumpTree: page == 1)
            if page < 4 { tap(element("welcome.continue"), "Continue") }
        }
        tap(element("welcome.continue"), "Get started")
        look(mode, "the way in", key: element("signin.email"), "Continue with email")
        tap(element("signin.email"), "Continue with email")
        look(mode, "the email sheet", key: element("email.send"), "the Send me a code button")

        launch(.waitlisted, arguments: setting.arguments)
        continueAfterFailure = true
        look(mode, "the waitlist", key: element("waitlist.code"), "the invite code field")
    }
}
