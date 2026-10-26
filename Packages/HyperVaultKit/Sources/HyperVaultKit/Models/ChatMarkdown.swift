import Foundation

/// One block of a reply. Inline marks (bold, links, `code`) stay inside the
/// text for the view to render; the Kit only decides the blocks, because the
/// block structure is what needs tests and what a view cannot get from
/// `AttributedString(markdown:)` without much ceremony.
public indirect enum ChatMarkdownBlock: Sendable, Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    /// A fenced code block. An unclosed fence runs to the end of the text, which
    /// is what a reply that is still being written looks like.
    case code(language: String?, code: String)
    case list([ChatMarkdownListItem])
    case quote([ChatMarkdownBlock])
    case table(header: [String], rows: [[String]])
    case rule
}

public struct ChatMarkdownListItem: Sendable, Equatable {
    /// `\u{2022}` for a bullet, `1.` for a numbered item.
    public let marker: String
    public let depth: Int
    public let text: String
    /// Set for a `- [ ]` / `- [x]` task item.
    public let checked: Bool?

    public init(marker: String, depth: Int, text: String, checked: Bool? = nil) {
        self.marker = marker
        self.depth = depth
        self.text = text
        self.checked = checked
    }
}

/// A forgiving, line-based reader for the markdown chat models write: fenced
/// code, headings, lists, quotes, tables, rules and paragraphs. Anything it
/// does not recognise is a paragraph, so nothing a model says is ever lost.
public enum ChatMarkdown {
    public static func parse(_ text: String) -> [ChatMarkdownBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var blocks: [ChatMarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let fence = fenceOpening(line) {
                flushParagraph()
                var body: [String] = []
                index += 1
                while index < lines.count, !isFenceClosing(lines[index], marker: fence.marker, length: fence.length) {
                    body.append(lines[index])
                    index += 1
                }
                index += 1  // the closing fence, or past the end
                blocks.append(.code(language: fence.language, code: body.joined(separator: "\n")))
                continue
            }

            if let heading = headingLine(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var inner: [String] = []
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    guard current.hasPrefix(">") else { break }
                    var stripped = String(current.dropFirst())
                    if stripped.hasPrefix(" ") { stripped.removeFirst() }
                    inner.append(stripped)
                    index += 1
                }
                blocks.append(.quote(parse(inner.joined(separator: "\n"))))
                continue
            }

            if index + 1 < lines.count, trimmed.contains("|"), isTableDelimiter(lines[index + 1]) {
                flushParagraph()
                let header = tableCells(trimmed)
                index += 2
                var rows: [[String]] = []
                while index < lines.count {
                    let row = lines[index].trimmingCharacters(in: .whitespaces)
                    guard !row.isEmpty, row.contains("|") else { break }
                    rows.append(tableCells(row))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            if listMarker(line) != nil {
                flushParagraph()
                let (items, next) = readList(lines, from: index)
                blocks.append(.list(items))
                index = next
                continue
            }

            paragraph.append(line)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    /// The words of a reply with the marks taken off, for reading aloud or
    /// copying without markup. Code blocks are not spoken.
    public static func plainText(_ text: String, codePlaceholder: String = "Code block.") -> String {
        var parts: [String] = []
        for block in parse(text) {
            switch block {
            case .paragraph(let text): parts.append(plainInline(text))
            case .heading(_, let text): parts.append(plainInline(text))
            case .code: parts.append(codePlaceholder)
            case .list(let items): parts.append(items.map { plainInline($0.text) }.joined(separator: "\n"))
            case .quote(let inner): parts.append(plainText(inner.map(plainBlockSource).joined(separator: "\n\n"), codePlaceholder: codePlaceholder))
            case .table(let header, let rows):
                parts.append(([header] + rows).map { $0.map(plainInline).joined(separator: ", ") }.joined(separator: "\n"))
            case .rule: break
            }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Inline marks removed: `**bold**`, `_em_`, `` `code` ``, `[text](url)`, `![alt](url)`.
    public static func plainInline(_ text: String) -> String {
        var result = text
        let rules: [(String, String)] = [
            (#"!\[([^\]]*)\]\([^)]*\)"#, "$1"),
            (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),
            (#"`+([^`]+)`+"#, "$1"),
            (#"\*\*([^*]+)\*\*"#, "$1"),
            (#"__([^_]+)__"#, "$1"),
            (#"~~([^~]+)~~"#, "$1"),
            (#"(?<![\w*])\*([^*\n]+)\*(?![\w*])"#, "$1"),
            (#"(?<![\w_])_([^_\n]+)_(?![\w_])"#, "$1"),
        ]
        for (pattern, template) in rules {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            result = expression.stringByReplacingMatches(
                in: result, range: NSRange(location: 0, length: (result as NSString).length), withTemplate: template
            )
        }
        return result
    }

    private static func plainBlockSource(_ block: ChatMarkdownBlock) -> String {
        switch block {
        case .paragraph(let text), .heading(_, let text): return text
        case .code(_, let code): return "```\n\(code)\n```"
        case .list(let items): return items.map(\.text).joined(separator: "\n")
        case .quote(let inner): return inner.map(plainBlockSource).joined(separator: "\n\n")
        case .table(let header, let rows): return ([header] + rows).map { $0.joined(separator: ", ") }.joined(separator: "\n")
        case .rule: return ""
        }
    }

    // MARK: Pieces

    private struct Fence {
        let marker: Character
        let length: Int
        let language: String?
    }

    private static func fenceOpening(_ line: String) -> Fence? {
        let stripped = line.drop { $0 == " " }
        guard line.count - stripped.count <= 3, let marker = stripped.first, marker == "`" || marker == "~" else { return nil }
        let run = stripped.prefix { $0 == marker }
        guard run.count >= 3 else { return nil }
        let info = stripped.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
        // A backtick fence's info string cannot hold a backtick: that is inline code.
        if marker == "`", info.contains("`") { return nil }
        let language = info.split(separator: " ").first.map(String.init)
        return Fence(marker: marker, length: run.count, language: language?.isEmpty == false ? language : nil)
    }

    private static func isFenceClosing(_ line: String, marker: Character, length: Int) -> Bool {
        let stripped = line.trimmingCharacters(in: .whitespaces)
        guard let first = stripped.first, first == marker else { return false }
        return stripped.allSatisfy { $0 == marker } && stripped.count >= length
    }

    private static func headingLine(_ trimmed: String) -> (level: Int, text: String)? {
        let hashes = trimmed.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return (hashes.count, text.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.filter { $0 != " " }
        guard compact.count >= 3, let first = compact.first, first == "-" || first == "*" || first == "_" else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func isTableDelimiter(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-") else { return false }
        let cells = tableCells(trimmed)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let core = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return core.count >= 1 && core.allSatisfy { $0 == "-" }
        }
    }

    private static func tableCells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|"), !trimmed.hasSuffix("\\|") { trimmed.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in trimmed {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private struct Marker {
        let indent: Int
        let label: String
        let text: String
        let ordered: Bool
    }

    private static func listMarker(_ line: String) -> Marker? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let rest = line.drop { $0 == " " || $0 == "\t" }
        guard let first = rest.first else { return nil }
        if first == "-" || first == "*" || first == "+" {
            let after = rest.dropFirst()
            guard after.first == " " else { return nil }
            // `* * *` and `- - -` are rules, not bullets.
            if isRule(rest.trimmingCharacters(in: .whitespaces)) { return nil }
            return Marker(indent: indent, label: "\u{2022}", text: after.trimmingCharacters(in: .whitespaces), ordered: false)
        }
        let digits = rest.prefix { $0.isNumber && $0.isASCII }
        guard (1...9).contains(digits.count) else { return nil }
        let afterDigits = rest.dropFirst(digits.count)
        guard let delimiter = afterDigits.first, delimiter == "." || delimiter == ")" else { return nil }
        let after = afterDigits.dropFirst()
        guard after.first == " " else { return nil }
        return Marker(indent: indent, label: "\(digits).", text: after.trimmingCharacters(in: .whitespaces), ordered: true)
    }

    private static func readList(_ lines: [String], from start: Int) -> ([ChatMarkdownListItem], Int) {
        var items: [ChatMarkdownListItem] = []
        var indents: [Int] = []
        var index = start

        while index < lines.count {
            let line = lines[index]
            if let marker = listMarker(line) {
                while let last = indents.last, marker.indent < last { indents.removeLast() }
                if indents.last.map({ marker.indent > $0 }) ?? true { indents.append(marker.indent) }
                let depth = min(max(indents.count - 1, 0), 3)
                var text = marker.text
                var checked: Bool?
                if text.hasPrefix("[ ] ") {
                    checked = false
                    text.removeFirst(4)
                } else if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") {
                    checked = true
                    text.removeFirst(4)
                }
                items.append(ChatMarkdownListItem(marker: marker.label, depth: depth, text: text, checked: checked))
                index += 1
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                // A blank line ends the list unless another item follows it.
                var look = index + 1
                while look < lines.count, lines[look].trimmingCharacters(in: .whitespaces).isEmpty { look += 1 }
                if look < lines.count, listMarker(lines[look]) != nil {
                    index = look
                    continue
                }
                break
            }
            // An indented line under an item continues it.
            let leading = line.prefix { $0 == " " || $0 == "\t" }.count
            if leading > 0, let last = items.last, fenceOpening(line) == nil, headingLine(trimmed) == nil {
                items[items.count - 1] = ChatMarkdownListItem(
                    marker: last.marker, depth: last.depth, text: last.text + "\n" + trimmed, checked: last.checked
                )
                index += 1
                continue
            }
            break
        }
        return (items, index)
    }
}
