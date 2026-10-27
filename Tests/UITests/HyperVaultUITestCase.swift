import XCTest

/// The states the app can be launched into by the UI-test mode (`App/Core/UITestHarness.swift`).
enum Scenario: String, CaseIterable {
    /// The welcome story and the way in.
    case signedOut
    /// The app, with a few things kept, memories, chats and a connected model.
    case signedIn
    /// The app with nothing kept and no model: the first run.
    case signedInEmpty
    /// Signed in but not let in until the invite code is redeemed.
    case waitlisted
    /// The same vault as `signedIn`, for a person the server knows as an admin.
    case signedInAdmin

    /// What the first screen of the scenario shows, by accessibility identifier.
    var firstScreen: (identifier: String, description: String) {
        switch self {
        case .signedOut: return ("welcome.pages", "the welcome story")
        case .signedIn, .signedInEmpty, .signedInAdmin: return ("canvas.field", "the canvas")
        case .waitlisted: return ("waitlist.code", "the waitlist")
        }
    }
}

/// What every journey shares: launching the app into a scenario, finding things, waiting for them and saying what was
/// missing when they never came, and a screenshot kept with the result at each step that matters.
///
/// A journey launches the real app (a debug build whose network is canned inside it, see the harness), so every wait is
/// generous: CI simulators are slow, and a wait that is too short is a flaky test, not a faster one. A failure stops the
/// journey at once with a line that names what was missing.
@MainActor
class HyperVaultUITestCase: XCTestCase {
    var app = XCUIApplication()

    /// How long to wait for something to appear on a slow simulator.
    let patience: TimeInterval = 30

    // MARK: Launching

    /// Launches the app into `scenario` and waits for its first screen. Every journey starts here, so this is also
    /// where the rules of a journey are set: the first failure ends it, and a system alert that appears over the app
    /// (a permission, a save-password offer) is dismissed rather than left to swallow the next tap.
    ///
    /// `resuming` is for a launch that carries on from the one before it (a journey that closes the app and opens it
    /// again): the app keeps what that launch left, the session and the preferences, instead of starting like a first
    /// run. `reaching` names the screen to wait for when it is not the scenario's first (a session that was ended opens
    /// on the welcome story, whatever the scenario says).
    @discardableResult
    func launch(
        _ scenario: Scenario, arguments extra: [String] = [], resuming: Bool = false,
        reaching screen: (identifier: String, description: String)? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) -> XCUIApplication {
        continueAfterFailure = false
        _ = addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for title in ["Not Now", "Don\u{2019}t Allow", "Don't Allow", "OK", "Cancel"] {
                let candidate = alert.buttons[title]
                if candidate.exists {
                    candidate.tap()
                    return true
                }
            }
            return false
        }
        let application = XCUIApplication()
        application.launchArguments = [
            "-HV_UITEST", "-HV_UITEST_SCENARIO", scenario.rawValue,
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ] + (resuming ? ["-HV_UITEST_RESUME"] : []) + extra
        start(application)
        app = application
        let first = screen ?? scenario.firstScreen
        require(element(first.identifier), "\(first.description) (\(first.identifier)) after launching \(scenario.rawValue)", file: file, line: line)
        return application
    }

    /// Starts the app, and starts it once more if the first start did not take: a simulator that has only just booted
    /// now and then loses the very first launch of a job ("does not have a process ID"), which is the simulator's
    /// trouble and not the app's. The first try's failure is recorded as an expected one (so it does not fail the
    /// test), and a second try that fails too is a failure like any other.
    private func start(_ application: XCUIApplication) {
        let continuedBefore = continueAfterFailure
        continueAfterFailure = true
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("The simulator can lose the first launch of a run.", options: options) {
            application.launch()
        }
        continueAfterFailure = continuedBefore
        if application.state == .runningForeground || application.state == .runningBackground { return }
        print("[journey] the app did not start; starting it again")
        application.terminate()
        application.launch()
    }

    // MARK: Finding

    /// An element anywhere on screen, by accessibility identifier, whatever kind of control it is.
    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// The first element of `query` whose label or identifier is `name`. (A bare subscript fails the test when two
    /// elements answer to the name; the first match is what a journey means.)
    func named(_ name: String, in query: XCUIElementQuery) -> XCUIElement {
        query.matching(NSPredicate(format: "label == %@ OR identifier == %@", name, name)).firstMatch
    }

    /// A text field, by identifier or label. (SwiftUI's fields that grow with their text, like the canvas's, are text
    /// fields to XCUITest too.)
    func textField(_ name: String) -> XCUIElement {
        // A field that grows with its text has no label of its own: it is known by its identifier or its placeholder.
        app.textFields.matching(NSPredicate(format: "label == %@ OR identifier == %@ OR placeholderValue == %@", name, name, name)).firstMatch
    }

    /// A search field, by its placeholder.
    func searchField(_ name: String) -> XCUIElement {
        named(name, in: app.searchFields)
    }

    /// A button by its label.
    func button(_ label: String) -> XCUIElement {
        named(label, in: app.buttons)
    }

    /// A switch by its label.
    func toggle(_ label: String) -> XCUIElement {
        named(label, in: app.switches)
    }

    /// Static text by its exact label.
    func text(_ label: String) -> XCUIElement {
        named(label, in: app.staticTexts)
    }

    /// Static text whose label contains `fragment`.
    func text(containing fragment: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
    }

    /// Anything on screen whose label contains `fragment`: a text, or a row or button that reads its texts as one. (Rows
    /// that combine their words have no static texts of their own, so a journey that checks what a screen says asks this.)
    func shows(_ fragment: String) -> XCUIElement {
        // A picker or a field keeps its words in its value, and a row that combines its words in its label.
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", fragment, fragment)).firstMatch
    }

    /// How many static texts carry exactly this label.
    func count(ofText label: String) -> Int {
        app.staticTexts.matching(NSPredicate(format: "label == %@", label)).count
    }

    /// A tab in the tab bar, by its title.
    func tab(_ title: String) -> XCUIElement {
        named(title, in: app.tabBars.buttons)
    }

    /// A segment of a segmented control, by its title.
    func segment(_ title: String) -> XCUIElement {
        named(title, in: app.segmentedControls.buttons)
    }

    /// A screen's title in the navigation bar.
    func isShowingTitle(_ title: String) -> Bool {
        named(title, in: app.navigationBars).exists || named(title, in: app.navigationBars.staticTexts).exists
    }

    func isOnScreen(_ element: XCUIElement) -> Bool {
        let window = app.windows.firstMatch.frame
        let frame = element.frame
        return element.exists && !frame.isEmpty && window.contains(CGPoint(x: frame.midX, y: frame.midY))
    }

    // MARK: Waiting

    /// Waits for `condition`, polling, and fails with `what` if it never holds.
    func waitUntil(_ what: String, timeout: TimeInterval? = nil, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout ?? patience)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        if condition() { return }
        attachScreenshot("Never happened - \(what)")
        XCTFail("Gave up waiting for: \(what).", file: file, line: line)
    }

    /// Waits for the element to appear. (Looking first matters: `waitForExistence` always takes about a second, and a
    /// journey asks hundreds of times for things that are already there.)
    func require(_ element: XCUIElement, _ what: String, timeout: TimeInterval? = nil, file: StaticString = #filePath, line: UInt = #line) {
        if element.exists { return }
        if element.waitForExistence(timeout: timeout ?? patience) { return }
        attachScreenshot("Missing - \(what)")
        XCTFail("Never saw \(what).", file: file, line: line)
    }

    /// Waits for the element to go away.
    func requireGone(_ element: XCUIElement, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        waitUntil("\(what) to go away", file: file, line: line) { !element.exists }
    }

    // MARK: Doing

    /// Waits for the element, gives it a moment to stop moving, then taps it. An element that is on the page but
    /// scrolled out of view is tapped anyway: XCUITest scrolls it into view first.
    func tap(_ element: XCUIElement, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        require(element, what, file: file, line: line)
        let settled = Date().addingTimeInterval(4)
        while Date() < settled, !(element.exists && element.isHittable) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        element.tap()
    }

    /// Taps an element and waits for what it should lead to, tapping again (up to three times) if nothing came of it:
    /// a tap that lands while a list is still settling is lost, and a person would just tap again.
    func tap(_ element: XCUIElement, _ what: String, until reached: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        for attempt in 1...3 {
            // A tap that was slow to take is not repeated on a screen that has already moved on (what it was aimed at is gone).
            if attempt > 1, reached() || !element.exists { return }
            tap(element, what, file: file, line: line)
            let deadline = Date().addingTimeInterval(6)
            while Date() < deadline {
                if reached() { return }
                RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            }
            print("[journey] tapping \(what) did not get anywhere (attempt \(attempt))")
        }
    }

    /// Taps a field and types into it.
    func enter(_ text: String, into field: XCUIElement, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        tap(field, what, file: file, line: line)
        field.typeText(text)
    }

    /// Taps the system's Paste control. It draws itself outside the app's own view tree, so it is tapped as soon as it
    /// exists rather than waited on to be hittable.
    func tapPaste(file: StaticString = #filePath, line: UInt = #line) {
        let paste = button("Paste")
        require(paste, "the Paste button", file: file, line: line)
        paste.tap()
    }

    /// Clears a field the way a person does: by deleting what is in it.
    func clear(_ field: XCUIElement) {
        guard let current = field.value as? String, !current.isEmpty else { return }
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
    }

    /// Scrolls until `element` is on screen, can be tapped, and is clear of the bars that float over a list: down the
    /// page first, then back up it. A drag stops where the finger stops (a swipe flings, and at a large text size a fling
    /// carries a row past the screen without ever letting it be seen), and moves the page by about three fifths of its
    /// height. A row that is only just in view sits under the tab bar, and a tap on it would land on the tab bar.
    func reveal(_ element: XCUIElement, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        func hittable() -> Bool { element.exists && element.isHittable }
        if !hittable() {
            for _ in 0..<14 where !hittable() { drag(towardsEnd: true) }
        }
        if !hittable() {
            for _ in 0..<20 where !hittable() { drag(towardsEnd: false) }
        }
        require(element, what, timeout: 5, file: file, line: line)
        moveClearOfTheBars(element)
    }

    /// Moves the page until the middle of `element` is between the navigation bar and the tab bar, if the page can
    /// be moved that far: a tap lands in the middle of an element. (A page that does not move, a sheet's fixed button
    /// for one, is left as it is.)
    private func moveClearOfTheBars(_ element: XCUIElement) {
        let window = app.windows.firstMatch.frame
        // The status and navigation bars take about 110 points of an iPhone's top, the floating tab bar and the home
        // indicator about 90 of its bottom.
        let top = window.minY + 112
        let bottom = window.maxY - 92
        var previous: CGFloat?
        for _ in 0..<4 {
            guard element.exists else { return }
            let middle = element.frame.midY
            if middle >= top && middle <= bottom { return }
            if let previous, abs(previous - middle) < 2 { return }
            previous = middle
            drag(towardsEnd: middle > bottom)
        }
    }

    /// Moves the page: towards its end (the content goes up) or back towards its start. The finger goes down in the gutter
    /// at the right of the page, where no row is, so that a row's own long-press menu or swipe is never started.
    private func drag(towardsEnd: Bool) {
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: towardsEnd ? 0.82 : 0.22))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: towardsEnd ? 0.22 : 0.82))
        // The finger holds still before it lifts, so the page stops where the finger does and keeps no momentum; the speed
        // is the finger's, 500 points a second (the system's .slow is 100, and takes five seconds to move a page).
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: XCUIGestureVelocity(rawValue: 500), thenHoldForDuration: 0.2)
    }

    /// Scrolls to an element, clear of the bars, then taps it: for rows that a larger text size has pushed below the fold.
    /// With `reached`, a tap that comes to nothing (a list that was still settling after a screen was popped) is repeated, as
    /// `tap(_:_:until:)` does.
    func open(_ element: XCUIElement, _ what: String, until reached: (() -> Bool)? = nil, file: StaticString = #filePath, line: UInt = #line) {
        reveal(element, what, file: file, line: line)
        if let reached {
            tap(element, what, until: reached, file: file, line: line)
        } else {
            tap(element, what, file: file, line: line)
        }
    }

    /// Turns a switch the way a person does: a tap on its knob, at the trailing edge of its row, and again (up to three
    /// times) while it has not moved, because a tap that lands while the list is still settling is lost.
    func flip(_ control: XCUIElement, from value: String, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 1...3 {
            guard (control.value as? String) == value else { return }
            control.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            let deadline = Date().addingTimeInterval(4)
            while Date() < deadline, (control.value as? String) == value {
                RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            }
        }
        waitUntil("\(what) to change", file: file, line: line) { (control.value as? String) != value }
    }

    /// Opens a tab. What it shows is for the journey to wait for.
    func openTab(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        tap(tab(title), "the \(title) tab", file: file, line: line)
    }

    /// Picks an option of a choice the app draws as segments, or as a menu at accessibility text sizes.
    func choose(_ option: String, from identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let asSegment = segment(option)
        if asSegment.exists {
            tap(asSegment, "the \(option) segment", file: file, line: line)
            return
        }
        tap(element(identifier), "the menu that holds \(option)", file: file, line: line)
        tap(button(option), "the \(option) choice", file: file, line: line)
    }

    /// Opens a pane of the You tab by its id (`general`, `vault`, `keys`, `backends`, `domain`, `appearance`, `import`):
    /// back to the list the tab opens on a phone, then the pane's row. A row of the list that is already open still
    /// opens, which is what going back and choosing the same pane again checks.
    ///
    /// With a `title` it waits for the pane's heading. Without one it waits for the list to go, which is enough for a
    /// pane whose screen names itself (the caller then looks for what the pane holds).
    func openPane(_ id: String, title: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        showPaneList(file: file, line: line)
        let row = element("you.pane.\(id)")
        // (At a large text size the last panes are below the fold.)
        reveal(row, "the \(id) pane", file: file, line: line)
        // The list can still be settling from the screen that was just popped off it, and a tap on it then comes to nothing.
        tap(row, "the \(id) pane", until: { title.map { isShowingTitle($0) } ?? !row.exists }, file: file, line: line)
        if let title {
            waitUntil("the \(title) pane", file: file, line: line) { isShowingTitle(title) }
        } else {
            requireGone(row, "the list of panes, once \(id) is open", file: file, line: line)
        }
    }

    /// The list of panes the You tab opens on a phone one step behind the pane: opens the tab, and goes back until the
    /// list shows (choosing the tab again takes the person back to the first screen of the pane that is open).
    func showPaneList(file: StaticString = #filePath, line: UInt = #line) {
        openTab("You", file: file, line: line)
        var goneBack = 0
        while !element("you.pane.general").exists, goneBack < 5 {
            goBack(file: file, line: line)
            goneBack += 1
        }
        require(element("you.pane.general"), "the list of panes", file: file, line: line)
    }

    /// Opens a row of the Account menu behind the avatar on Home (`library`, `mail`, `taskBoards`, `accountAndKeys`,
    /// `groupChats`, `tools`, `import`, `dreams`, `truth`, `admin`), scrolling to it first, and waits for the screen it goes
    /// to to name itself.
    func openFromAccount(_ id: String, title: String, file: StaticString = #filePath, line: UInt = #line) {
        openAccountMenu(file: file, line: line)
        let row = element("account.\(id)")
        reveal(row, "the \(id) row of the Account menu", file: file, line: line)
        tap(row, "the \(id) row", until: { isShowingTitle(title) }, file: file, line: line)
        waitUntil("the \(title) screen", file: file, line: line) { isShowingTitle(title) }
    }

    /// Opens the Account menu with the avatar on Home, from wherever the person is.
    func openAccountMenu(file: StaticString = #filePath, line: UInt = #line) {
        showHome(file: file, line: line)
        // A tap that lands while the page is still settling (after the launch, or as the tab changes) is lost, and a person
        // would tap again.
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        tap(element("canvas.account"), "the Account button", until: { element("account.close").exists }, file: file, line: line)
        require(element("account.close"), "the Account menu", file: file, line: line)
    }

    /// Opens an item of the More menu of Memory (`Dreams`, `Truth`, `Digest`) or of Chat (`Tools`, `Import your AI history`),
    /// from the first screen of that tab, and waits for the screen it goes to to name itself.
    func openFromMoreMenu(of tabTitle: String, _ item: String, title: String, file: StaticString = #filePath, line: UInt = #line) {
        let more = element(tabTitle == "Memory" ? "memory.more" : "chat.more")
        openTab(tabTitle, file: file, line: line)
        var goneBack = 0
        while !more.exists, goneBack < 5 {
            goBack(file: file, line: line)
            goneBack += 1
        }
        tap(more, "the More menu of \(tabTitle)", file: file, line: line)
        // At the largest text sizes every item of the menu is over a hundred points tall, and the card the menu is drawn in
        // ends about two thirds of the way down the screen: the items below its fold are not drawn until the menu is scrolled,
        // and the ones just past it exist but sit under the card's edge, where a tap would land on the page and put the menu
        // away. The finger goes down inside the card (a drag that starts outside it puts the menu away too) and is drawn up.
        let window = app.windows.firstMatch.frame
        func reachable() -> Bool {
            let target = button(item)
            guard target.exists else { return false }
            return target.frame.height < 90 || target.frame.midY < window.height * 0.55
        }
        var scrolled = 0
        while !reachable(), scrolled < 8 {
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.17))
            from.press(forDuration: 0.01, thenDragTo: to, withVelocity: XCUIGestureVelocity(rawValue: 400), thenHoldForDuration: 0)
            scrolled += 1
        }
        tap(button(item), "\(item) in the More menu", until: { isShowingTitle(title) }, file: file, line: line)
        waitUntil("the \(title) screen", file: file, line: line) { isShowingTitle(title) }
    }

    /// Opens an item of Memory's More menu.
    func openFromMemoryMenu(_ item: String, title: String, file: StaticString = #filePath, line: UInt = #line) {
        openFromMoreMenu(of: "Memory", item, title: title, file: file, line: line)
    }

    /// Opens the Yours panel over Home with the button in the corner.
    func openYours(file: StaticString = #filePath, line: UInt = #line) {
        showHome(file: file, line: line)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        tap(element("canvas.yours"), "the panel button", until: { element("yours.filter").exists }, file: file, line: line)
        require(element("yours.filter"), "the Yours panel", file: file, line: line)
    }

    /// Takes the Yours panel from half the height of the screen to the whole of it, the way a person does: a finger on its
    /// navigation bar, drawn up. (A drag on the rows would scroll them, and a drag back down that starts above a panel of half
    /// the height lands on Home and puts the panel away.)
    func expandThePanel(file: StaticString = #filePath, line: UInt = #line) {
        let more = element("yours.more")
        require(more, "the panel's More menu", file: file, line: line)
        let height = max(app.windows.firstMatch.frame.height, 1)
        let filter = element("yours.filter")
        // The panel has moved when the filter at the top of its list is in the upper third of the screen. (A drag that
        // comes to nothing is made again; what the journey looks for next says whether the rows can be seen.)
        for _ in 1...2 {
            if filter.exists, filter.frame.minY < height * 0.33 { return }
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: more.frame.midY / height))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08))
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: XCUIGestureVelocity(rawValue: 500), thenHoldForDuration: 0.2)
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline, !(filter.exists && filter.frame.minY < height * 0.33) {
                RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            }
        }
    }

    /// Home, on its first screen: the tab, and back from anything pushed on it.
    func showHome(file: StaticString = #filePath, line: UInt = #line) {
        openTab("Home", file: file, line: line)
        var goneBack = 0
        while !element("canvas.account").exists, goneBack < 5 {
            goBack(file: file, line: line)
            goneBack += 1
        }
        require(element("canvas.account"), "Home, on its first screen", file: file, line: line)
    }

    /// Goes back one screen with the navigation bar's back button.
    func goBack(file: StaticString = #filePath, line: UInt = #line) {
        tap(backButton(), "the back button", file: file, line: line)
    }

    /// Goes back one screen and waits for `reached` to be true of the screen behind, tapping back again (up to three
    /// times) if nothing came of it: a tap that lands while the list behind is still settling after a push is lost, and a
    /// person would just tap again. A tap is not repeated once the screen has moved on.
    func goBack(until reached: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        tap(backButton(), "the back button", until: reached, file: file, line: line)
    }

    private func backButton() -> XCUIElement {
        let identified = named("BackButton", in: app.navigationBars.buttons)
        return identified.waitForExistence(timeout: 5) ? identified : app.navigationBars.buttons.element(boundBy: 0)
    }

    // MARK: Typing

    /// Types after what a field already holds: the finger goes down at the far right of the field, which puts the caret at
    /// the end of a text shorter than the field is wide (or, for a tall field, below its last line). Typing at the middle
    /// of a field, where a plain tap lands, would split the text.
    func append(_ text: String, to field: XCUIElement, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        require(field, what, file: file, line: line)
        let settled = Date().addingTimeInterval(4)
        while Date() < settled, !(field.exists && field.isHittable) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.9)).tap()
        field.typeText(text)
    }

    /// Puts the keyboard away with its Return (or Done, Go) key, which a single-line field answers by letting go of the
    /// keyboard. Not for a field that grows with its text: its Return key starts a new line.
    func putTheKeyboardAway() {
        guard app.keyboards.count > 0 else { return }
        for name in ["Return", "return", "Done", "done", "Go", "go", "Next", "next", "Continue", "continue"] {
            let key = app.keyboards.buttons[name]
            if key.exists {
                key.tap()
                break
            }
        }
        // (Not a failure if it stays: the next step finds out whether it was in the way.)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, app.keyboards.count > 0 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
    }

    /// Scrolls a form that has the keyboard up until `element` is clear of the keyboard, for a form whose fields grow with their
    /// text (their Return key is a new line, so there is no putting the keyboard away). The finger goes up the gutter at the
    /// right of the page, in the part the keyboard leaves: the page moves with it, and a sheet is not pulled down (a drag
    /// down would be).
    func revealAboveTheKeyboard(_ element: XCUIElement, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<6 where !(element.exists && element.isHittable) {
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.55))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.15))
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: XCUIGestureVelocity(rawValue: 500), thenHoldForDuration: 0.2)
        }
        require(element, what, timeout: 5, file: file, line: line)
    }

    /// Answers a confirmation the app asks for a destructive choice. On a phone the dialog is an action sheet, or a popover
    /// that holds only the destructive button; either way the button is the one by this label that is not the control that
    /// asked (`asked` is that control, when it is still on screen under the same label).
    func confirm(_ label: String, whileStill asked: XCUIElement? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let inPopover = app.popovers.buttons[label]
        let sameLabel = app.buttons.matching(NSPredicate(format: "label == %@", label))
        let others = { (asked?.exists == true) ? 2 : 1 }
        waitUntil("the confirmation asking for \(label)", file: file, line: line) { inPopover.exists || sameLabel.count >= others() }
        let target = inPopover.exists ? inPopover : sameLabel.element(boundBy: max(sameLabel.count - 1, 0))
        tap(target, "the \(label) confirmation", file: file, line: line)
    }

    // MARK: What the app sent

    /// A write the app made, as the canned server received it (see `UITestWrites.swift`): the method, the path, and the
    /// names of the body's fields with their values (a secret's value is `<redacted>`).
    struct RecordedWrite: CustomStringConvertible {
        let method: String
        let path: String
        let query: String
        let fields: [String: String]

        var description: String {
            let shown = fields.keys.sorted().map { "\($0)=\(fields[$0] ?? "")" }.joined(separator: ", ")
            return "\(method) \(path)\(query.isEmpty ? "" : "?" + query) {\(shown)}"
        }

        /// True when this write is what was asked for: the method, the path (a trailing `*` matches any ending), and
        /// each field `equal` to the value given, or for `contains` holding the text.
        func matches(_ method: String, _ path: String, equal: [String: String], contains: [String: String]) -> Bool {
            guard self.method == method else { return false }
            if path.hasSuffix("*") {
                guard self.path.hasPrefix(String(path.dropLast())) else { return false }
            } else if self.path != path {
                return false
            }
            for (name, value) in equal where fields[name] != value { return false }
            for (name, part) in contains where !(fields[name] ?? "").contains(part) { return false }
            return true
        }
    }

    /// Every write the app has sent since it was launched, oldest first. (Opening the You tab sends one on its own: the
    /// check whether this person is an admin is a write to an invite that does not exist, answered 403 for everyone else.
    /// It is not something a journey did, so it is left out.)
    func recordedWrites() -> [RecordedWrite] {
        let beacon = element("uitest.writes")
        guard beacon.exists else { return [] }
        return beacon.label.components(separatedBy: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let entry = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let method = entry["method"] as? String, let path = entry["path"] as? String
            else { return nil }
            if method == "PATCH", path == "/api/admin/invites/00000000-0000-0000-0000-000000000000" { return nil }
            return RecordedWrite(
                method: method, path: path, query: entry["query"] as? String ?? "",
                fields: (entry["fields"] as? [String: String]) ?? [:]
            )
        }
    }

    /// Waits until the app has sent this write, and fails with everything it did send if it never does.
    @discardableResult
    func requireWrite(
        _ method: String, _ path: String, equal: [String: String] = [:], contains: [String: String] = [:],
        file: StaticString = #filePath, line: UInt = #line
    ) -> RecordedWrite? {
        var found: RecordedWrite?
        let deadline = Date().addingTimeInterval(patience)
        while Date() < deadline {
            found = recordedWrites().first { $0.matches(method, path, equal: equal, contains: contains) }
            if found != nil { return found }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        let sent = recordedWrites().map(\.description).joined(separator: "\n  ")
        attachScreenshot("Never sent - \(method) \(path)")
        XCTFail("The app never sent \(method) \(path) with \(equal) \(contains). It sent:\n  \(sent.isEmpty ? "nothing" : sent)", file: file, line: line)
        return nil
    }

    /// Fails if the app sent a write matching this (a secret that was typed must never be in one, a cancelled edit must not send one).
    func requireNoWrite(
        _ method: String, _ path: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let sent = recordedWrites().filter { $0.matches(method, path, equal: [:], contains: [:]) }
        XCTAssertTrue(sent.isEmpty, "The app sent \(method) \(path) when it should not have: \(sent)", file: file, line: line)
    }

    /// The whole record as one text, for a check that something is nowhere in it.
    func writeRecordText() -> String {
        element("uitest.writes").label
    }

    // MARK: Showing what happened

    /// Runs one step of a journey as a named activity, and keeps a screenshot of how it ended with the result.
    func step(_ name: String, _ body: () -> Void) {
        let started = Date()
        XCTContext.runActivity(named: name) { _ in
            body()
            attachScreenshot(name)
        }
        // In the build log, so a slow journey can be read without opening the result bundle.
        print(String(format: "[journey] %6.1f s  %@ / %@", Date().timeIntervalSince(started), String(describing: type(of: self)), name))
    }

    /// Keeps a screenshot with the result, and hands it back.
    @discardableResult
    func attachScreenshot(_ name: String) -> XCUIScreenshot {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return screenshot
    }
}
