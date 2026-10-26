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
    @discardableResult
    func launch(_ scenario: Scenario, arguments extra: [String] = [], file: StaticString = #filePath, line: UInt = #line) -> XCUIApplication {
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
        ] + extra
        start(application)
        app = application
        let first = scenario.firstScreen
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

    /// Opens a row of the You tab, scrolling to it first, and waits for the screen to name itself.
    func openFromYou(_ id: String, title: String, file: StaticString = #filePath, line: UInt = #line) {
        openTab("You", file: file, line: line)
        // Choosing the tab again takes the person back to its first screen; if it has not, go back until it is.
        var goneBack = 0
        while !isShowingTitle("You"), goneBack < 4 {
            goBack(file: file, line: line)
            goneBack += 1
        }
        let row = element("you.\(id)")
        reveal(row, "the \(id) row of the You tab", file: file, line: line)
        // The list can still be settling from the screen that was just popped off it, and a tap on it then comes to nothing.
        tap(row, "the \(id) row", until: { isShowingTitle(title) }, file: file, line: line)
        waitUntil("the \(title) screen", file: file, line: line) { isShowingTitle(title) }
    }

    /// Goes back one screen with the navigation bar's back button.
    func goBack(file: StaticString = #filePath, line: UInt = #line) {
        let identified = named("BackButton", in: app.navigationBars.buttons)
        let back = identified.waitForExistence(timeout: 5) ? identified : app.navigationBars.buttons.element(boundBy: 0)
        tap(back, "the back button", file: file, line: line)
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
