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

    /// What the first screen of the scenario shows, by accessibility identifier.
    var firstScreen: (identifier: String, description: String) {
        switch self {
        case .signedOut: return ("welcome.pages", "the welcome story")
        case .signedIn, .signedInEmpty: return ("canvas.field", "the canvas")
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
    func launch(_ scenario: Scenario, file: StaticString = #filePath, line: UInt = #line) -> XCUIApplication {
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
        ]
        application.launch()
        app = application
        let first = scenario.firstScreen
        require(element(first.identifier), "\(first.description) (\(first.identifier)) after launching \(scenario.rawValue)", file: file, line: line)
        return application
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

    /// A text field, text view or search field, by identifier or label. SwiftUI makes a multi-line field a text view
    /// and a one-line field a text field, so this looks for whichever the screen has.
    func field(_ name: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let candidates = [
            named(name, in: app.textViews), named(name, in: app.textFields),
            named(name, in: app.secureTextFields), named(name, in: app.searchFields),
        ]
        waitUntil("the field \(name)", file: file, line: line) { candidates.contains { $0.exists } }
        return candidates.first { $0.exists } ?? element(name)
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

    /// Waits for the element to appear.
    func require(_ element: XCUIElement, _ what: String, timeout: TimeInterval? = nil, file: StaticString = #filePath, line: UInt = #line) {
        if element.waitForExistence(timeout: timeout ?? patience) { return }
        attachScreenshot("Missing - \(what)")
        XCTFail("Never saw \(what).", file: file, line: line)
    }

    /// Waits for the element to go away.
    func requireGone(_ element: XCUIElement, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        waitUntil("\(what) to go away", file: file, line: line) { !element.exists }
    }

    // MARK: Doing

    /// Waits for the element, then taps it. A system control that draws itself outside the app's own view tree (the
    /// Paste button) is not reported as hittable, so it is tapped as soon as it exists.
    func tap(_ element: XCUIElement, _ what: String, whenHittable: Bool = true, file: StaticString = #filePath, line: UInt = #line) {
        require(element, what, file: file, line: line)
        if whenHittable {
            waitUntil("\(what) to be tappable", file: file, line: line) { element.exists && element.isHittable }
        }
        element.tap()
    }

    /// Taps a field and types into it.
    func enter(_ text: String, into field: XCUIElement, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        tap(field, what, file: file, line: line)
        field.typeText(text)
    }

    /// Clears a field the way a person does: by deleting what is in it.
    func clear(_ field: XCUIElement) {
        guard let current = field.value as? String, !current.isEmpty else { return }
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
    }

    /// Scrolls the screen up until `element` is on it, for rows below the fold of a long list.
    func reveal(_ element: XCUIElement, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            app.swipeUp()
        }
        require(element, what, timeout: 5, file: file, line: line)
    }

    /// Opens a tab. What it shows is for the journey to wait for.
    func openTab(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        tap(tab(title), "the \(title) tab", file: file, line: line)
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
        XCTContext.runActivity(named: name) { _ in
            body()
            attachScreenshot(name)
        }
    }

    func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
