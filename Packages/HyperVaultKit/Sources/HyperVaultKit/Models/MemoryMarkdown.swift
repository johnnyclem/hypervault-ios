import Foundation

/// A block of a memory's text, for showing it as the document it is. Memories
/// are mostly notes and transcripts with a little Markdown in them, so this
/// reads the handful of block forms that matter and leaves the rest to the
/// text's own inline styling (bold, italics, code, links).
public enum MarkdownBlock: Sendable, Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list(items: [MarkdownListItem], ordered: Bool)
    case quote(String)
    case code(language: String?, text: String)
    case rule
}

public struct MarkdownListItem: Sendable, Equatable {
    public let text: String
    /// 0 for a top-level item, 1 for one nested under it, and so on (at most 3).
    public let depth: Int
    /// The number an ordered item was written with.
    public let number: Int?

    public init(text: String, depth: Int = 0, number: Int? = nil) {
        self.text = text
        self.depth = depth
        self.number = number
    }
}

public enum MarkdownBlocks {
    public static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var list: [MarkdownListItem] = []
        var listOrdered = false
        var quote: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }
        func flushList() {
            guard !list.isEmpty else { return }
            blocks.append(.list(items: list, ordered: listOrdered))
            list = []
        }
        func flushQuote() {
            guard !quote.isEmpty else { return }
            blocks.append(.quote(quote.joined(separator: "\n")))
            quote = []
        }
        func flushAll() {
            flushParagraph()
            flushList()
            flushQuote()
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            index += 1

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushAll()
                let fence = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    body.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }  // the closing fence
                blocks.append(.code(language: language.isEmpty ? nil : language, text: body.joined(separator: "\n")))
                continue
            }
            if trimmed.isEmpty {
                flushAll()
                continue
            }
            if let heading = heading(trimmed) {
                flushAll()
                blocks.append(heading)
                continue
            }
            if isRule(trimmed) {
                flushAll()
                blocks.append(.rule)
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                flushList()
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            if let item = listItem(line) {
                flushParagraph()
                flushQuote()
                if !list.isEmpty, listOrdered != (item.number != nil) { flushList() }
                listOrdered = item.number != nil
                list.append(item)
                continue
            }
            // A line that follows a list item and is indented belongs to it.
            if !list.isEmpty, line.hasPrefix("  ") || line.hasPrefix("\t") {
                let last = list.removeLast()
                list.append(MarkdownListItem(text: last.text + " " + trimmed, depth: last.depth, number: last.number))
                continue
            }
            flushList()
            flushQuote()
            paragraph.append(trimmedTrailing(line))
        }
        flushAll()
        return blocks
    }

    private static func trimmedTrailing(_ line: String) -> String {
        var text = line
        while text.last == " " || text.last == "\t" { text.removeLast() }
        return text
    }

    private static func heading(_ trimmed: String) -> MarkdownBlock? {
        guard trimmed.hasPrefix("#") else { return nil }
        let hashes = trimmed.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.first == " " || rest.first == "\t" else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // "## Title ##"
        while text.hasSuffix("#") { text.removeLast() }
        return .heading(level: hashes.count, text: text.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.filter { $0 != " " }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func listItem(_ line: String) -> MarkdownListItem? {
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
        let width = indent.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let depth = min(width / 2, 3)
        let body = line.dropFirst(indent.count)
        if let marker = body.first, "-*+•".contains(marker), body.dropFirst().first == " " {
            // "**bold**" and "* * *" are not bullets.
            let text = body.dropFirst(2).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, !isRule(String(body)) else { return nil }
            return MarkdownListItem(text: text, depth: depth)
        }
        let digits = body.prefix(while: { $0.isNumber })
        // "2026. A year." is a sentence, not item 2026.
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let after = body.dropFirst(digits.count)
        guard let punctuation = after.first, punctuation == "." || punctuation == ")", after.dropFirst().first == " " else { return nil }
        let text = after.dropFirst(2).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let number = Int(digits) else { return nil }
        return MarkdownListItem(text: text, depth: depth, number: number)
    }
}
