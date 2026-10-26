import Foundation

// Reading what models write: tool requests and tool results. A port of the
// parsing half of lib/smallchat/intent.ts, kept to the same behaviour so a
// thread reads the same on the web and here. Reasoning traces are
// `Thinking.strip` (lib/chat/thinking.ts), which the lead's Kit owns.

/// The fenced blocks tool use travels in. A model ends a reply with
/// ```` ```tool ```` and a JSON request; the server answers with a
/// ```` ```tool-result ```` turn. Saved history holds both as plain messages.
public enum ChatToolProtocol {
    public struct IntentCall: Sendable, Equatable {
        public let intent: String
        public let args: JSONValue
        /// The words before the block.
        public let visibleText: String
    }

    private static let maxIntentChars = 500
    private static let maxPreviewChars = 2_000

    /// The first ```` ```tool ```` request in a reply, or nil when there is none
    /// or it is malformed (a malformed block is just text).
    public static func parseIntentCall(_ text: String) -> IntentCall? {
        guard let found = extractFencedJSON(text, fence: "tool"),
              let value = try? JSONDecoder().decode(JSONValue.self, from: Data(found.json.utf8)),
              case .object(let object) = value
        else { return nil }
        let intent = (object["intent"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !intent.isEmpty, intent.count <= maxIntentChars else { return nil }
        var args: JSONValue = [:]
        if let given = object["args"] {
            guard case .object = given else { return nil }
            args = given
        }
        let visible = String(decoding: Array(text.utf8)[0..<found.fenceIndex], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return IntentCall(intent: intent, args: args, visibleText: visible)
    }

    /// A saved ```` ```tool-result ```` message as one step.
    public static func parseToolResult(_ text: String) -> ChatToolTurn? {
        guard let found = extractFencedJSON(text, fence: "tool-result"),
              let value = try? JSONDecoder().decode(JSONValue.self, from: Data(found.json.utf8)),
              case .object(let object) = value,
              let intent = object["intent"]?.string
        else { return nil }

        var preview: String?
        if let content = object["content"], !content.isNull {
            let text = content.string ?? content.jsonString()
            preview = String(text.prefix(maxPreviewChars))
        }
        var refinement: ChatToolTurn.Refinement?
        if let raw = object["refinement"], let question = raw["question"]?.string {
            let options = (raw["options"]?.array ?? []).compactMap { option -> ChatToolTurn.Refinement.Option? in
                guard let label = option["label"]?.string else { return nil }
                return .init(label: label, intent: option["intent"]?.string ?? label, canonical: option["canonical"]?.string)
            }
            refinement = .init(question: question, options: options)
        }
        return ChatToolTurn(
            intent: intent,
            tool: object["tool"]?.string,
            ok: object["ok"]?.bool ?? true,
            confidence: object["confidence"]?.double,
            tier: object["tier"]?.string,
            preview: preview,
            error: object["error"]?.string,
            refinement: refinement
        )
    }

    /// Pulls the balanced JSON object out of a fenced block. The payload can
    /// not be delimited by the closing fence: the JSON itself may hold ```` ``` ````
    /// inside string values (a page whose markdown embeds a code fence), so
    /// this finds the opening fence and then walks the first `{...}` tracking
    /// string and escape state. `fenceIndex` is a UTF-8 offset.
    static func extractFencedJSON(_ text: String, fence name: String) -> (json: String, fenceIndex: Int)? {
        let bytes = Array(text.utf8)
        let opener = Array("```\(name)".utf8)
        guard bytes.count >= opener.count else { return nil }

        var searchFrom = 0
        var bodyStart: Int?
        var fenceIndex = 0
        while searchFrom + opener.count <= bytes.count {
            guard let hit = indexOf(opener, in: bytes, from: searchFrom) else { break }
            // The fence line is the opener, spaces or tabs, an optional CR, then a newline.
            var cursor = hit + opener.count
            while cursor < bytes.count, bytes[cursor] == 0x20 || bytes[cursor] == 0x09 { cursor += 1 }
            if cursor < bytes.count, bytes[cursor] == 0x0D { cursor += 1 }
            if cursor < bytes.count, bytes[cursor] == 0x0A {
                bodyStart = cursor + 1
                fenceIndex = hit
                break
            }
            searchFrom = hit + 1
        }
        guard let from = bodyStart, let open = bytes[from...].firstIndex(of: 0x7B) else { return nil }

        var depth = 0
        var inString = false
        var escaped = false
        var index = open
        while index < bytes.count {
            let byte = bytes[index]
            if inString {
                if escaped { escaped = false } else if byte == 0x5C { escaped = true } else if byte == 0x22 { inString = false }
            } else if byte == 0x22 {
                inString = true
            } else if byte == 0x7B {
                depth += 1
            } else if byte == 0x7D {
                depth -= 1
                if depth == 0 {
                    return (String(decoding: bytes[open...index], as: UTF8.self), fenceIndex)
                }
            }
            index += 1
        }
        return nil  // never closed: not a tool call, just text
    }

    private static func indexOf(_ needle: [UInt8], in haystack: [UInt8], from start: Int) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        var index = start
        let last = haystack.count - needle.count
        while index <= last {
            if haystack[index] == needle[0], haystack[index..<(index + needle.count)].elementsEqual(needle) { return index }
            index += 1
        }
        return nil
    }
}

extension ThinkingSplit {
    /// What a bubble shows: the words, or the reasoning when that is all the
    /// reply holds (a trace beats an empty bubble). `Thinking.strip` splits them.
    public var shown: String { text.isEmpty ? reasoning : text }
}
