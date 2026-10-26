import XCTest

/// What the layout sweeps share: how the app is launched (dark, or at the largest accessibility text size), and how a screen
/// is looked at (a screenshot, a note of what its tree says about the layout, a check that its key control can be tapped).
@MainActor
class LayoutSweepCase: HyperVaultUITestCase {
    /// How a sweep launches the app. Dark is what Settings' Appearance choice stores (`pref.appearance`), given as a launch
    /// argument: neither `-AppleInterfaceStyle Dark` nor the device's `appearance` turned the app dark on CI. The large
    /// text size is the system's own launch argument.
    struct Mode {
        let name: String
        let arguments: [String]
    }

    static let dark = Mode(name: "dark", arguments: ["-pref.appearance", "dark"])
    static let large = Mode(
        name: "large", arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
    )

    // MARK: Looking

    /// Keeps a screenshot of the screen as it opens (its top, which is where most layout bugs show), writes down what its
    /// tree says about the layout, then makes sure the key control is there and can be tapped, scrolling to it if the
    /// text size has pushed it below the fold (and keeping a second screenshot if it had to).
    func look(_ mode: String, _ screen: String, key: XCUIElement, _ what: String, dumpTree: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
        let started = Date()
        XCTContext.runActivity(named: "\(mode): \(screen)") { _ in
            // What the screen is for has to be there before it is looked at (not a skeleton, not the launch splash fading).
            // A key below the fold of a large text size is not in the tree yet, so this waits only a few seconds for it.
            if !key.exists { _ = key.waitForExistence(timeout: 4) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.7))
            attachScreenshot("\(mode) - \(screen)")
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

            if !(key.exists && key.isHittable) {
                reveal(key, what, file: file, line: line)
                if key.exists { attachScreenshot("\(mode) - \(screen) - scrolled to \(what)") }
            }
            if key.exists {
                XCTAssertTrue(key.isHittable, "\(what) is on the \(screen) screen (\(mode)) but cannot be tapped.", file: file, line: line)
            }
        }
        print(String(format: "[journey] %6.1f s  %@ / %@ - %@", Date().timeIntervalSince(started), String(describing: type(of: self)), mode, screen))
    }
}
