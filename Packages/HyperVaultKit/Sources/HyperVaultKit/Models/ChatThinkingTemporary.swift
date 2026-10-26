import Foundation

// TEMPORARY. The lead is landing `Thinking.strip(_:)` (a port of lib/chat/thinking.ts) in the
// shared Kit. This stands in so this branch builds; delete this file and point
// `ChatThinking.visibleText` callers at `Thinking.strip` when claude/ios-client is merged.

/// Reasoning models inline their chain of thought as `<think>...</think>`.
/// That is scratch work, not the answer.
public enum ChatThinking {
    /// Splits a reply into the words to show and the reasoning removed from it.
    /// An unclosed `<think>` swallows to the end (the reply was cut off mid
    /// thought); an orphan `</think>` swallows from the start (some providers
    /// drop the opener).
    public static func split(_ raw: String) -> (text: String, reasoning: String) {
        let lower = raw.lowercased()
        guard lower.contains("<think>") || lower.contains("</think>")
            || lower.contains("<thinking>") || lower.contains("</thinking>")
        else {
            return (raw.trimmingCharacters(in: .whitespacesAndNewlines), "")
        }

        let source = raw as NSString
        guard let tag = try? NSRegularExpression(pattern: "<(/?)think(?:ing)?>", options: [.caseInsensitive]) else {
            return (raw.trimmingCharacters(in: .whitespacesAndNewlines), "")
        }
        var visible: [String] = []
        var reasoning: [String] = []
        var cursor = 0
        var inThought = false
        for match in tag.matches(in: raw, range: NSRange(location: 0, length: source.length)) {
            let chunk = source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let closing = match.range(at: 1).length > 0
            if closing {
                // A closing tag ends a thought, even one whose opener never arrived.
                reasoning.append(chunk)
                inThought = false
            } else {
                if inThought { reasoning.append(chunk) } else { visible.append(chunk) }
                inThought = true
            }
            cursor = match.range.location + match.range.length
        }
        let tail = source.substring(from: cursor)
        if inThought { reasoning.append(tail) } else { visible.append(tail) }

        let text = visible.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let thought = reasoning
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return (text, thought)
    }

    /// The reply to show: the words, or the reasoning when that is all there is
    /// (a trace beats an empty bubble).
    public static func visibleText(_ raw: String) -> String {
        let parts = split(raw)
        return parts.text.isEmpty ? parts.reasoning : parts.text
    }
}

