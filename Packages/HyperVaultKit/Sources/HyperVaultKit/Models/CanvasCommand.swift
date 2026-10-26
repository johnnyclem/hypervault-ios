import Foundation

/// What "show my ..." can ask for. "stuff" opens Yours.
public enum ShowTarget: String, Sendable, Equatable {
    case memories, files, keys, stuff
}

/// A plain-language command the canvas understands without a model: "Keep
/// this", "Hide that", "Show my memories", "Pull the trip notes onto the page".
/// A faithful port of the web app's `lib/canvas/commands.ts`, so a person gets
/// the same answer from the same words on either.
public enum CanvasCommand: Sendable, Equatable {
    case help
    case keep
    case hideAll
    case hide(name: String)
    case show(ShowTarget)
    case pull(query: String)
    case agentKeys
}

public enum CanvasCommandParser {
    /// Longer messages are never commands.
    public static let maxCommandChars = 80

    private static let helpRE = regex(#"^(?:help|help\s+me|what\s+(?:can|do)\s+you\s+do|what\s+does\s+this\s+(?:page\s+|thing\s+)?do|what\s+can\s+i\s+do\s+here|what\s+do\s+i\s+do\s+here|how\s+does\s+this\s+(?:page\s+)?work|how\s+do\s+i\s+use\s+this)$"#)
    private static let keepRE = regex(#"^keep\s+(?:this|that)(?:\s+one)?$"#)
    private static let hideAllRE = regex(#"^(?:hide\s+(?:that|this|it|them|those|these|all|everything|all\s+of\s+(?:it|them)|(?:it|them)\s+all|everything\s+on\s+the\s+(?:page|canvas)|(?:all\s+(?:the\s+)?|the\s+)?cards)|clear\s+(?:the\s+)?(?:page|canvas|everything))$"#)
    private static let hideNameRE = regex(#"^hide\s+(.+)$"#)
    private static let showRE = regex(#"^show\s+(?:me\s+)?(?:(?:all\s+(?:of\s+)?)?my\s+|all\s+)?(memories|files|keys|stuff)$"#)
    private static let showEverythingRE = regex(#"^show\s+(?:me\s+)?everything$"#)
    private static let agentKeysRE = regex(#"^(?:what|which)\s+keys\s+(?:does|do|can|could)\s+(?:this|my|the|that)\s+(?:agent|assistant)\s+(?:have(?:\s+access\s+to)?|use|access)$"#)
    private static let pullRE = regex(#"^pull\s+(.+?)\s+(?:onto|on|to|into)\s+(?:(?:the|my|this)\s+)?(?:page|canvas)$"#)

    private static let leadPoliteRE = regex(#"^(?:(?:please|pls)\s+)?(?:(?:can|could|would|will)\s+you\s+(?:please\s+)?)?"#)
    private static let trailPoliteRE = regex(#"(?:(?:\s*,\s*|\s+)(?:please|pls|thanks|thank\s+you))+$"#)
    private static let trailPunctRE = regex(#"[.!?\u2026]+$"#)

    private static let sentenceWordRE = regex(#"\b(?:from|in|on|at|with|without|for|to|of|by|as|and|or|but|except|unless|until|if|so|because|when|while|which|then|than|before|after|over|under|into|onto|about|using|via|behind|beside|below|beneath|above|around|inside|outside|through|during|between|across|against|near|within)\b"#)
    private static let nonNameRE = regex(#"^(?:it|them|that|this|those|these|one|ones|all|everything|something|stuff|thing|things|card|cards|me|myself|you|yourself|him|her|us|here|there)$"#)
    private static let addressedToAssistantRE = regex(#"^your\b"#)
    private static let maxHideNameWords = 5

    private static let leadingDeterminerRE = regex(#"^(?:the|my|our|a|an|that|this|those|these)\s+"#)
    private static let quotedRE = regex(#"^(?:"(.+)"|\u201C(.+)\u201D|'(.+)'|\u2018(.+)\u2019)$"#)

    /// The command a message is, or nil when it is just a message. Never throws.
    public static func parse(_ text: String) -> CanvasCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxCommandChars else { return nil }
        let input = normalize(trimmed)

        if matches(helpRE, input) { return .help }
        if matches(keepRE, input) { return .keep }
        if matches(hideAllRE, input) { return .hideAll }
        if matches(agentKeysRE, input) { return .agentKeys }

        if let groups = capture(showRE, input), let word = groups[1]?.lowercased(), let target = ShowTarget(rawValue: word) {
            return .show(target)
        }
        if matches(showEverythingRE, input) { return .show(.stuff) }

        if let groups = capture(pullRE, input), let raw = groups[1] {
            let name = readTarget(raw).name
            return !name.isEmpty && !matches(nonNameRE, name) ? .pull(query: name) : nil
        }

        if let groups = capture(hideNameRE, input), let raw = groups[1] {
            let (name, quoted) = readTarget(raw)
            if name.isEmpty || matches(nonNameRE, name) { return nil }
            if !quoted {
                if matches(sentenceWordRE, name) { return nil }
                if matches(addressedToAssistantRE, name) { return nil }
                if name.split(separator: " ").count > maxHideNameWords { return nil }
            }
            return .hide(name: name)
        }
        return nil
    }

    // MARK: Helpers

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are constants checked by the tests, so a failure here is a programmer error.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static func matches(_ re: NSRegularExpression, _ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return re.firstMatch(in: text, options: [], range: range) != nil
    }

    private static func capture(_ re: NSRegularExpression, _ text: String) -> [Int: String]? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = re.firstMatch(in: text, options: [], range: range) else { return nil }
        var groups: [Int: String] = [:]
        for index in 0..<match.numberOfRanges {
            let r = match.range(at: index)
            if r.location != NSNotFound, let swiftRange = Range(r, in: text) { groups[index] = String(text[swiftRange]) }
        }
        return groups
    }

    private static func replace(_ re: NSRegularExpression, in text: String) -> String {
        re.stringByReplacingMatches(in: text, options: [], range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    /// Collapse whitespace and drop the politeness and punctuation around a command.
    private static func normalize(_ text: String) -> String {
        var s = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        s = replace(trailPunctRE, in: s)
        s = replace(trailPoliteRE, in: s)
        s = replace(trailPunctRE, in: s)
        s = replace(leadPoliteRE, in: s)
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func readTarget(_ raw: String) -> (name: String, quoted: Bool) {
        let bare = replace(leadingDeterminerRE, in: raw.trimmingCharacters(in: .whitespaces)).trimmingCharacters(in: .whitespaces)
        if let groups = capture(quotedRE, bare) {
            let inner = [1, 2, 3, 4].compactMap { groups[$0] }.first ?? ""
            return (inner.trimmingCharacters(in: .whitespaces), true)
        }
        return (bare, false)
    }
}
