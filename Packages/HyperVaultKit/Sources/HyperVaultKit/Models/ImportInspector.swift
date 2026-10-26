import Foundation

// Reading an export before sending it: which service it came from, how many
// conversations it holds, and how to cut it into requests the server will
// take. This mirrors `lib/imports/index.ts` (and its `looksLike*` checks) on
// the web, but works on bytes: a ChatGPT history can be a few hundred
// megabytes of JSON, so it is scanned for the edges of its conversations
// rather than parsed whole, and only a handful of them are decoded.

/// One batch of an import: which conversations go in a single request.
public struct ImportBatch: Sendable, Equatable {
    /// Indices into the document's elements, in the order they are sent.
    public let indices: [Int]
    /// How many indices travel together (a Gemini day is several entries that
    /// must not be split). Empty for a pasted transcript.
    let units: [Int]
    public let conversationCount: Int
    public let byteCount: Int

    /// Splits into two smaller batches, or nil when it cannot be split.
    func halves(sizes: [Int]) -> (ImportBatch, ImportBatch)? {
        guard units.count > 1 else { return nil }
        let middle = units.count / 2
        let cut = units[..<middle].reduce(0, +)
        func make(_ range: Range<Int>, units slice: ArraySlice<Int>) -> ImportBatch {
            let ids = Array(indices[range])
            let bytes = ids.reduce(2) { $0 + sizes[$1] + 1 }
            return ImportBatch(indices: ids, units: Array(slice), conversationCount: slice.count, byteCount: bytes)
        }
        return (
            make(0..<cut, units: units[..<middle]),
            make(cut..<indices.count, units: units[middle...])
        )
    }
}

/// An export (or a pasted transcript), read and ready to send.
public struct ImportDocument: Sendable {
    public enum Kind: Sendable, Equatable { case json, transcript }

    public let name: String
    public let kind: Kind
    /// The service the data looks like, if it looks like any.
    public let detected: ImportPlatform?
    /// What the person said it was, when they said.
    public let chosen: ImportPlatform?
    /// What is sent as the `platform` hint: what the data is, whatever was chosen.
    public var platform: ImportPlatform { detected ?? .other }
    /// What the server will find: conversations (a Gemini day counts as one).
    public let conversationCount: Int
    /// Known for a transcript only.
    public let messageCount: Int?
    /// The first few conversation titles, to show the person it is the right file.
    public let sampleTitles: [String]
    public let byteCount: Int

    let data: Data
    /// JSON: the byte range of each conversation in `data`.
    let spans: [Range<Int>]
    /// Gemini: entry indices grouped by day. Nil otherwise.
    let groups: [[Int]]?

    public var isImportable: Bool { conversationCount > 0 }

    /// The person chose one service and the file looks like another.
    public var disagrees: Bool {
        guard let chosen, let detected else { return false }
        return chosen != detected
    }

    // MARK: Batches

    /// Cuts the document into requests of at most `maxBytes` and
    /// `maxConversations` each (a conversation bigger than `maxBytes` goes
    /// alone). A transcript is a single batch.
    public func batches(
        maxBytes: Int = ImportInspector.defaultBatchBytes,
        maxConversations: Int = ImportInspector.defaultBatchConversations
    ) -> [ImportBatch] {
        if kind == .transcript {
            return conversationCount == 0 ? [] : [ImportBatch(indices: [], units: [], conversationCount: 1, byteCount: byteCount)]
        }
        let units: [[Int]] = groups ?? spans.indices.map { [$0] }
        var result: [ImportBatch] = []
        var ids: [Int] = []
        var sizes: [Int] = []
        var bytes = 2

        func flush() {
            guard !ids.isEmpty else { return }
            result.append(ImportBatch(indices: ids, units: sizes, conversationCount: sizes.count, byteCount: bytes))
            ids = []
            sizes = []
            bytes = 2
        }

        for unit in units {
            let unitBytes = unit.reduce(0) { $0 + spans[$1].count + 1 }
            if !ids.isEmpty, bytes + unitBytes > maxBytes || sizes.count >= maxConversations { flush() }
            ids.append(contentsOf: unit)
            sizes.append(unit.count)
            bytes += unitBytes
        }
        flush()
        return result
    }

    /// The two halves of a batch the server found too heavy, or nil.
    public func split(_ batch: ImportBatch) -> (ImportBatch, ImportBatch)? {
        batch.halves(sizes: spans.map(\.count))
    }

    /// The request text for a batch: a JSON array of the batch's conversations,
    /// or the transcript itself.
    public func text(for batch: ImportBatch) -> String {
        if kind == .transcript { return String(decoding: data, as: UTF8.self) }
        var body = Data()
        body.reserveCapacity(batch.byteCount)
        body.append(UInt8(ascii: "["))
        for (position, index) in batch.indices.enumerated() {
            if position > 0 { body.append(UInt8(ascii: ",")) }
            body.append(data[spans[index]])
        }
        body.append(UInt8(ascii: "]"))
        return String(decoding: body, as: UTF8.self)
    }
}

public enum ImportInspector {
    /// The server's own sentence when it finds nothing (app/api/import/route.ts).
    public static let nothingFoundMessage =
        "Couldn't find any conversations in that data. Upload the conversations.json from your platform's export, or paste a transcript with User:/Assistant: labels."

    /// A request carries about this much of the export. The JSON text is then
    /// escaped into a string, which grows it by a fifth or so; hosts commonly
    /// stop a request body at 4.5 MB.
    public static let defaultBatchBytes = 2_500_000
    public static let defaultBatchConversations = 50

    /// Reads the bytes of a file. JSON that is an array of conversations (or
    /// an object holding a `conversations` array, or one conversation) is
    /// scanned; anything else is read as a transcript, which is what the
    /// server does too.
    public static func inspect(_ input: Data, name: String = "", hint: ImportPlatform? = nil) -> ImportDocument {
        let data = input.startIndex == 0 ? input : Data(input)
        let start = leadingOffset(in: data)
        if start < data.count, data[start] == UInt8(ascii: "[") || data[start] == UInt8(ascii: "{"),
           let document = inspectJSON(data, start: start, name: name, hint: hint) {
            return document
        }
        return inspectTranscript(data.dropFirst(start), name: name)
    }

    /// Pasted text.
    public static func inspect(text: String, name: String = "Pasted text", hint: ImportPlatform? = nil) -> ImportDocument {
        inspect(Data(text.utf8), name: name, hint: hint)
    }

    // MARK: JSON

    private static func leadingOffset(in data: Data) -> Int {
        var i = 0
        if data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF { i = 3 }
        while i < data.count, isSpace(data[i]) { i += 1 }
        return i
    }

    private static func inspectJSON(_ data: Data, start: Int, name: String, hint: ImportPlatform?) -> ImportDocument? {
        let spans: [Range<Int>]? = data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            if bytes[start] == UInt8(ascii: "[") {
                return JSONScanner.elements(of: bytes, arrayAt: start)
            }
            if let wrapped = JSONScanner.elements(of: bytes, arrayNamed: "conversations", inObjectAt: start) {
                return wrapped
            }
            // A single conversation object: the route wraps it in an array too.
            guard let end = JSONScanner.skipValue(bytes, from: start) else { return nil }
            return [start..<end]
        }
        guard let spans, !spans.isEmpty else { return nil }

        let samples = sampleIndices(spans.count).compactMap { index -> [String: Any]? in
            (try? JSONSerialization.jsonObject(with: data.subdata(in: spans[index]))) as? [String: Any]
        }
        // JSON that matches no known export holds nothing the route can use
        // (an account or billing file, say): it is read, and found empty.
        guard let detected = detect(samples) else {
            return ImportDocument(
                name: name, kind: .json, detected: nil, chosen: hint, conversationCount: 0, messageCount: nil,
                sampleTitles: [], byteCount: data.count, data: data, spans: [], groups: nil
            )
        }

        var groups: [[Int]]?
        var count = spans.count
        if detected == .gemini {
            let days = geminiDays(data, spanCount: spans.count)
            groups = days
            count = days.count
        }

        let titles = samples.compactMap(title(of:)).prefix(3).map { String($0.prefix(80)) }
        return ImportDocument(
            name: name, kind: .json, detected: detected, chosen: hint,
            conversationCount: count, messageCount: nil, sampleTitles: Array(titles),
            byteCount: data.count, data: data, spans: spans, groups: groups
        )
    }

    private static func sampleIndices(_ count: Int) -> [Int] {
        guard count > 5 else { return Array(0..<count) }
        return Array(Set([0, count / 4, count / 2, 3 * count / 4, count - 1])).sorted()
    }

    /// `looksLikeChatGptExport` and its siblings (lib/imports/*.ts), tried in
    /// the route's order. Each requires every sampled entry to fit.
    static func detect(_ samples: [[String: Any]]) -> ImportPlatform? {
        guard !samples.isEmpty else { return nil }
        if samples.allSatisfy({ $0["mapping"] != nil }) { return .chatgpt }
        if samples.allSatisfy({ $0["chat_messages"] != nil }) { return .claude }
        if samples.allSatisfy({ $0["responses"] != nil }) { return .grok }
        if samples.allSatisfy(looksLikeGeminiEntry) { return .gemini }
        if samples.allSatisfy({ $0["messages"] is [Any] }) { return .other }
        return nil
    }

    private static func looksLikeGeminiEntry(_ item: [String: Any]) -> Bool {
        if let header = item["header"], "\(header)".range(of: "gemini|bard", options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        return (item["title"] as? String)?.hasPrefix("Prompted ") ?? false
    }

    private static func title(of item: [String: Any]) -> String? {
        // Gemini's activity entries are titled "Prompted <what you asked>".
        ["title", "name"]
            .compactMap { key -> String? in
                guard var text = item[key] as? String else { return nil }
                if text.hasPrefix("Prompted ") { text = String(text.dropFirst("Prompted ".count)) }
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }
            .first
    }

    /// Gemini's Takeout is one entry per prompt; the route turns them into one
    /// conversation per UTC day, so a day is never split across requests.
    private static func geminiDays(_ data: Data, spanCount: Int) -> [[Int]] {
        guard let parsed = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var entries: [Any]?
        if let array = parsed as? [Any] {
            entries = array
        } else if let object = parsed as? [String: Any] {
            entries = object["conversations"] as? [Any] ?? [object]
        }
        guard let entries, entries.count == spanCount else { return [] }

        var order: [String] = []
        var byDay: [String: [Int]] = [:]
        for (index, entry) in entries.enumerated() {
            guard let item = entry as? [String: Any],
                  let title = item["title"] as? String,
                  !title.replacingOccurrences(of: "^Prompted\\s+", with: "", options: [.regularExpression, .caseInsensitive])
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            let day = dayKey(item["time"])
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(index)
        }
        return order.compactMap { byDay[$0] }
    }

    private static func dayKey(_ time: Any?) -> String {
        guard let text = time as? String, let date = HVDate.parse(text) else { return "unknown" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: Transcript

    private static func inspectTranscript(_ bytes: Data, name: String) -> ImportDocument {
        let text = String(decoding: bytes, as: UTF8.self)
        let messages = ImportTranscript.messages(in: text)
        let data = Data(text.utf8)
        return ImportDocument(
            name: name, kind: .transcript, detected: nil, chosen: nil,
            conversationCount: messages.isEmpty ? 0 : 1, messageCount: messages.count,
            sampleTitles: messages.first.map { [String($0.content.prefix(60))] } ?? [],
            byteCount: data.count, data: data, spans: [], groups: nil
        )
    }

    fileprivate static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09
    }
}

// MARK: - Transcripts

/// The paste fallback (lib/imports/markdown.ts): lines that start with a
/// speaker label begin a message, and lines under it belong to it.
public enum ImportTranscript {
    public struct Message: Sendable, Equatable {
        public let role: String
        public let content: String
    }

    private static let aliases: [String: String] = [
        "user": "user", "human": "user", "me": "user", "you": "user", "prompt": "user",
        "assistant": "assistant", "ai": "assistant", "chatgpt": "assistant", "gpt": "assistant",
        "claude": "assistant", "gemini": "assistant", "bard": "assistant", "grok": "assistant", "model": "assistant",
        "system": "system",
    ]

    public static func messages(in text: String) -> [Message] {
        var messages: [Message] = []
        var role: String?
        var content = ""

        func finish() {
            guard let role else { return }
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { messages.append(Message(role: role, content: trimmed)) }
        }

        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if let (speaker, rest) = speakerLine(line) {
                finish()
                role = speaker
                content = rest
            } else if role != nil {
                content += "\n" + line
            }
            // Text before the first label is page chrome; the route ignores it too.
        }
        finish()
        return messages
    }

    /// `^(?:#+\s*)?(?:\*\*)?(label)(?:\*\*)?\s*[:：]\s*(.*)$`, case-insensitive.
    private static func speakerLine(_ line: Substring) -> (String, String)? {
        var rest = line
        if rest.first == "#" {
            rest = rest.drop(while: { $0 == "#" }).drop(while: { $0.isWhitespace })
        }
        if rest.hasPrefix("**") { rest = rest.dropFirst(2) }
        let word = rest.prefix(while: { $0.isASCII && $0.isLetter })
        guard !word.isEmpty, let role = aliases[word.lowercased()] else { return nil }
        rest = rest.dropFirst(word.count)
        if rest.hasPrefix("**") { rest = rest.dropFirst(2) }
        rest = rest.drop(while: { $0.isWhitespace })
        guard let colon = rest.first, colon == ":" || colon == "\u{FF1A}" else { return nil }
        return (role, String(rest.dropFirst()))
    }
}

// MARK: - Scanning

/// Finds where values begin and end in JSON text without decoding it. It
/// trusts the text to be well formed JSON and returns nil when the text
/// ends before a value does.
enum JSONScanner {
    static func skipWhitespace(_ b: UnsafeBufferPointer<UInt8>, _ from: Int) -> Int {
        var i = from
        while i < b.count, ImportInspector.isSpace(b[i]) { i += 1 }
        return i
    }

    /// The index just after the string that opens at `from`.
    static func skipString(_ b: UnsafeBufferPointer<UInt8>, from: Int) -> Int? {
        var i = from + 1
        while i < b.count {
            let c = b[i]
            if c == UInt8(ascii: "\\") {
                i += 2
            } else if c == UInt8(ascii: "\"") {
                return i + 1
            } else {
                i += 1
            }
        }
        return nil
    }

    /// The index just after the value that begins at `from`.
    static func skipValue(_ b: UnsafeBufferPointer<UInt8>, from: Int) -> Int? {
        guard from < b.count else { return nil }
        let first = b[from]
        if first == UInt8(ascii: "\"") { return skipString(b, from: from) }
        if first == UInt8(ascii: "{") || first == UInt8(ascii: "[") {
            var depth = 0
            var i = from
            while i < b.count {
                let c = b[i]
                if c == UInt8(ascii: "\"") {
                    guard let after = skipString(b, from: i) else { return nil }
                    i = after
                    continue
                }
                if c == UInt8(ascii: "{") || c == UInt8(ascii: "[") {
                    depth += 1
                } else if c == UInt8(ascii: "}") || c == UInt8(ascii: "]") {
                    depth -= 1
                    if depth == 0 { return i + 1 }
                }
                i += 1
            }
            return nil
        }
        // A number, true, false or null.
        var i = from
        while i < b.count {
            let c = b[i]
            if c == UInt8(ascii: ",") || c == UInt8(ascii: "]") || c == UInt8(ascii: "}") || ImportInspector.isSpace(c) { break }
            i += 1
        }
        return i == from ? nil : i
    }

    /// The byte range of each element of the array that opens at `open`.
    static func elements(of b: UnsafeBufferPointer<UInt8>, arrayAt open: Int) -> [Range<Int>]? {
        var result: [Range<Int>] = []
        var i = open + 1
        while true {
            i = skipWhitespace(b, i)
            guard i < b.count else { return nil }
            if b[i] == UInt8(ascii: "]") { return result }
            guard let end = skipValue(b, from: i) else { return nil }
            result.append(i..<end)
            i = skipWhitespace(b, end)
            guard i < b.count else { return nil }
            if b[i] == UInt8(ascii: ",") {
                i += 1
            } else if b[i] == UInt8(ascii: "]") {
                return result
            } else {
                return nil
            }
        }
    }

    /// The elements of `key`'s array, when the object that opens at `open`
    /// has one at its top level.
    static func elements(of b: UnsafeBufferPointer<UInt8>, arrayNamed key: String, inObjectAt open: Int) -> [Range<Int>]? {
        var i = open + 1
        while true {
            i = skipWhitespace(b, i)
            guard i < b.count, b[i] == UInt8(ascii: "\"") else { return nil }
            guard let keyEnd = skipString(b, from: i) else { return nil }
            let name = String(decoding: UnsafeBufferPointer(rebasing: b[(i + 1)..<(keyEnd - 1)]), as: UTF8.self)
            i = skipWhitespace(b, keyEnd)
            guard i < b.count, b[i] == UInt8(ascii: ":") else { return nil }
            i = skipWhitespace(b, i + 1)
            guard i < b.count else { return nil }
            if name == key {
                return b[i] == UInt8(ascii: "[") ? elements(of: b, arrayAt: i) : nil
            }
            guard let end = skipValue(b, from: i) else { return nil }
            i = skipWhitespace(b, end)
            guard i < b.count else { return nil }
            if b[i] == UInt8(ascii: ",") { i += 1 } else { return nil }
        }
    }
}
