import Foundation

/// Reads the accessibility tree of a screen (what `XCUIApplication.debugDescription` prints, frames included) and notes what
/// a layout bug usually looks like in it: a control smaller than the 44 point target Apple asks for, and anything drawn
/// outside the screen. It only describes; a person reads the notes beside the screenshot of the same screen.
///
/// It is plain Foundation so it can be checked without a simulator.
enum LayoutReport {
    struct Item: Equatable {
        let kind: String
        let label: String
        let identifier: String
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        let indent: Int

        var name: String {
            var parts = ["\(kind)"]
            if !label.isEmpty { parts.append("\"\(label.prefix(60))\"") }
            if !identifier.isEmpty { parts.append("(\(identifier.prefix(40)))") }
            return parts.joined(separator: " ")
        }

        var frame: String { String(format: "%.0f,%.0f %.0fx%.0f", x, y, width, height) }
    }

    /// The controls whose size matters for a finger.
    static let targets: Set<String> = ["Button", "Switch", "Link", "TextField", "SecureTextField", "SearchField", "Toggle", "Slider", "Stepper"]
    /// What can be cut off by the edge of the screen.
    static let drawn: Set<String> = ["Button", "StaticText", "TextField", "SecureTextField", "SearchField", "Switch", "Image", "Link"]
    static let minimumTarget = 44.0

    private static let pattern = try! NSRegularExpression(
        pattern: #"^(\s*)(?:→)?([A-Za-z]+)(?: \([^)]*\))?, 0x[0-9a-fA-F]+,(?: pid: \d+,)? \{\{(-?[0-9.]+), (-?[0-9.]+)\}, \{(-?[0-9.]+), (-?[0-9.]+)\}\}(.*)$"#
    )

    static func parse(_ description: String) -> [Item] {
        var items: [Item] = []
        var keyboardIndent: Int?
        for rawLine in description.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            let range = NSRange(line.startIndex..., in: line)
            guard let match = pattern.firstMatch(in: line, range: range) else { continue }
            func group(_ index: Int) -> String {
                Range(match.range(at: index), in: line).map { String(line[$0]) } ?? ""
            }
            let indent = group(1).count
            let kind = group(2)
            if let skipping = keyboardIndent {
                if indent > skipping { continue }
                keyboardIndent = nil
            }
            if kind == "Keyboard" || kind == "Key" {
                keyboardIndent = indent
                continue
            }
            let rest = group(7)
            items.append(Item(
                kind: kind, label: quoted("label", in: rest), identifier: quoted("identifier", in: rest),
                x: Double(group(3)) ?? 0, y: Double(group(4)) ?? 0, width: Double(group(5)) ?? 0, height: Double(group(6)) ?? 0,
                indent: indent
            ))
        }
        return items
    }

    private static func quoted(_ key: String, in text: String) -> String {
        guard let start = text.range(of: "\(key): '") else { return "" }
        let after = text[start.upperBound...]
        guard let end = after.range(of: "'") else { return String(after) }
        return String(after[..<end.lowerBound])
    }

    /// One line a person can read for each thing worth a look.
    static func notes(from description: String, screenWidth: Double? = nil) -> [String] {
        let items = parse(description)
        let width = screenWidth ?? items.first(where: { $0.kind == "Window" })?.width ?? items.map { $0.x + $0.width }.max() ?? 0
        var notes: [String] = []
        for item in items {
            if targets.contains(item.kind), item.width > 0, item.height > 0, min(item.width, item.height) < minimumTarget {
                notes.append("small target  \(item.name)  \(item.frame)")
            }
            if drawn.contains(item.kind), item.width > 0, item.x < -0.5 || item.x + item.width > width + 0.5 {
                notes.append("off screen    \(item.name)  \(item.frame)")
            }
        }
        return notes
    }
}
