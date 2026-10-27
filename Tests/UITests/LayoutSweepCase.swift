import UIKit
import XCTest

/// What the layout sweeps share: how the app is launched (dark, or at the largest accessibility text size), and how a screen
/// is looked at (a screenshot, a note of what its tree says about the layout, a check that its key control can be tapped).
@MainActor
class LayoutSweepCase: HyperVaultUITestCase {
    /// How a sweep launches the app. The app is dark whatever the phone is set to (Info.plist declares
    /// `UIUserInterfaceStyle = Dark`), so the dark sweep needs no argument: it is the one that proves, screen by screen,
    /// that the declaration reaches every screen. The large text size is the system's own launch argument.
    struct Mode {
        let name: String
        let arguments: [String]
    }

    static let dark = Mode(name: "dark", arguments: [])
    static let large = Mode(
        name: "large", arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
    )

    // MARK: Looking

    /// How bright the page is, 0 (black) to 1 (white): the middle one of 64 samples taken down a strip 12 points in from
    /// the left edge, which is the page's own background on every screen (rows and cards start 16 points in) and, on a
    /// sheet, the sheet's. The middle one, not the average: a sheet over a web page has the page, dimmed but white, above it.
    func edgeBrightness(of screenshot: XCUIScreenshot) -> Double? {
        guard let image = screenshot.image.cgImage else { return nil }
        let scale = Int(screenshot.image.scale)
        let strip = CGRect(x: 12 * scale, y: image.height / 8, width: 4 * scale, height: image.height * 6 / 8)
        guard let edge = image.cropping(to: strip) else { return nil }
        let samples = 64
        var pixels = [UInt8](repeating: 0, count: samples * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: 1, height: samples, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(edge, in: CGRect(x: 0, y: 0, width: 1, height: samples))
            return true
        }
        guard drawn else { return nil }
        let brightness = (0..<samples).map { row -> Double in
            let red = Double(pixels[row * 4]), green = Double(pixels[row * 4 + 1]), blue = Double(pixels[row * 4 + 2])
            return (0.2126 * red + 0.7152 * green + 0.0722 * blue) / 255
        }
        return brightness.sorted()[samples / 2]
    }

    /// Fails when a screen of the dark sweep is drawn light (the declared dark style never reached it, say).
    func requireDark(_ screenshot: XCUIScreenshot, _ screen: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let brightness = edgeBrightness(of: screenshot) else {
            XCTFail("Could not read the pixels of the screenshot of the \(screen) screen.", file: file, line: line)
            return
        }
        print(String(format: "[layout] dark / %@: the page is %.2f bright", screen, brightness))
        XCTAssertLessThan(brightness, 0.4, "The \(screen) screen is meant to be dark but is drawn light (the page is \(String(format: "%.2f", brightness)) bright).", file: file, line: line)
    }

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
            let screenshot = attachScreenshot("\(mode) - \(screen)")
            // A sweep of the dark appearance that is looking at light screens proves nothing, so each screen first
            // proves it is dark.
            if mode == Self.dark.name { requireDark(screenshot, screen, file: file, line: line) }
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
