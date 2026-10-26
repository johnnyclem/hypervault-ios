import Foundation

// Detecting artifact-worthy output in a model's reply: a full HTML page or a
// React component, fenced or bare. A faithful port of the web app's
// lib/chat/artifact.ts and lib/jsx.ts (detectJsx), so "Keep this" on a reply
// does what "Save to Vault" does on the web.

public struct JSXDetection: Sendable, Equatable {
    public let isJSX: Bool
    /// 0 to 100: how confident the heuristics are.
    public let confidence: Int
    public let signals: [String]
}

public enum JSXDetector {
    private static let strong: [(String, String)] = [
        (#"\bimport\s+React\b"#, "import React"),
        (#"\bfrom\s+['"]react(-dom)?(/[a-z]+)?['"]"#, "react import"),
        (#"\bReactDOM\b"#, "ReactDOM usage"),
        (#"\buse(State|Effect|Ref|Memo|Callback|Reducer|Context|LayoutEffect)\s*\("#, "react hook"),
        (#"\bexport\s+default\s+(async\s+)?(function|class)\s+[A-Z]"#, "export default component"),
    ]

    private static let weak: [(String, String)] = [
        (#"\bclassName\s*="#, "className prop"),
        (#"<[A-Z][A-Za-z0-9]*[\s/>]"#, "capitalized JSX tag"),
        (#"=>\s*\(?\s*<"#, "arrow function returning JSX"),
        (#"\breturn\s*\(?\s*<"#, "return <JSX"),
        (#"\b(?:function|const|let|var)\s+[A-Z][\w$]*\s*(?:=\s*(?:\([^)]*\)|[\w$]+)\s*=>|\()"#, "capitalized component definition"),
        (#"\{\s*[a-zA-Z_$][\w$.]*\s*\}\s*<"#, "JSX expression"),
        (#"\bexport\s+default\b"#, "export default"),
    ]

    /// Heuristic JSX detection over the first 50 KB. A real HTML document is never JSX.
    public static func detect(_ content: String) -> JSXDetection {
        let sample = String(content.prefix(50_000))
        if ChatArtifactExtractor.isFullHTMLDocument(sample) {
            return JSXDetection(isJSX: false, confidence: 0, signals: ["full HTML document"])
        }
        var signals: [String] = []
        var score = 0
        for (pattern, label) in strong where matches(pattern, in: sample) {
            score += 3
            signals.append(label)
        }
        for (pattern, label) in weak where matches(pattern, in: sample) {
            score += 1
            signals.append(label)
        }
        return JSXDetection(isJSX: score >= 3, confidence: min(100, score * 20), signals: signals)
    }

    static func matches(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

public struct ChatArtifact: Sendable, Equatable {
    public enum Kind: String, Sendable { case html, jsx }

    /// The extracted code, ready to keep.
    public let content: String
    public let kind: Kind
    /// A best-effort title guess (from `<title>`, an `<h1>`, or the component name).
    public var title: String?
}

public enum ChatArtifactExtractor {
    /// Snippets shorter than this are too small to be a real artifact.
    static let minArtifactChars = 60

    private static let htmlLangs: Set<String> = ["html", "htm", "xhtml", "svg", "xml"]
    private static let jsxLangs: Set<String> = ["jsx", "tsx", "react"]
    private static let scriptLangs: Set<String> = ["", "js", "javascript", "ts", "typescript"]

    /// A complete page: starts with a doctype or an `<html>` tag.
    public static func isFullHTMLDocument(_ code: String) -> Bool {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        return JSXDetector.matches(#"^<!doctype\s+html"#, in: trimmed, options: .caseInsensitive)
            || JSXDetector.matches(#"^<html[\s>]"#, in: trimmed, options: .caseInsensitive)
    }

    /// Markup-shaped enough to serve as a page even without a doctype.
    static func looksLikeHTMLFragment(_ code: String) -> Bool {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("<")
            && JSXDetector.matches(#"</[a-z][\w-]*\s*>"#, in: trimmed, options: .caseInsensitive)
            && JSXDetector.matches(#"<(body|head|div|main|section|article|style|script|svg|canvas|form|table|nav|header|footer|p|h[1-6])\b"#, in: trimmed, options: .caseInsensitive)
    }

    private static func classify(_ code: String, lang: String) -> ChatArtifact.Kind? {
        if htmlLangs.contains(lang) { return .html }
        if jsxLangs.contains(lang) { return .jsx }
        guard scriptLangs.contains(lang) else { return nil }
        if isFullHTMLDocument(code) { return .html }
        if JSXDetector.detect(code).isJSX { return .jsx }
        if lang.isEmpty, looksLikeHTMLFragment(code) { return .html }
        return nil
    }

    /// Find the artifact in an assistant reply, if there is one. Reasoning traces are ignored;
    /// fenced blocks are checked first (the longest qualifying block wins, an unclosed trailing
    /// fence counts); with no fences the whole message counts only if it IS the artifact.
    public static func extract(_ message: String) -> ChatArtifact? {
        guard !message.isEmpty else { return nil }
        let visible = Thinking.strip(message).text
        guard visible.count >= minArtifactChars else { return nil }

        let fenced = fences(in: visible)
        let after = fenced.last?.end ?? visible.startIndex
        let openTail = trailingOpenFence(visible, after: after)
        if !fenced.isEmpty || openTail != nil {
            var best: ChatArtifact?
            var blocks = fenced.map { (lang: $0.lang, code: $0.code) }
            if let openTail { blocks.append(openTail) }
            for block in blocks {
                guard block.code.count >= minArtifactChars, let kind = classify(block.code, lang: block.lang) else { continue }
                if best == nil || block.code.count > best!.content.count {
                    best = ChatArtifact(content: block.code, kind: kind, title: nil)
                }
            }
            if var found = best {
                found.title = guessTitle(found)
                return found
            }
            return nil
        }

        let bare = visible.trimmingCharacters(in: .whitespacesAndNewlines)
        guard bare.count >= minArtifactChars else { return nil }
        if isFullHTMLDocument(bare) {
            var artifact = ChatArtifact(content: bare, kind: .html, title: nil)
            artifact.title = guessTitle(artifact)
            return artifact
        }
        // Bare JSX, but only when the reply opens like code.
        let startsLikeCode = JSXDetector.matches(#"^(import\s|export\s|function\s|const\s|let\s|var\s|class\s|<|//|/\*)"#, in: bare)
        if startsLikeCode, JSXDetector.detect(bare).isJSX {
            var artifact = ChatArtifact(content: bare, kind: .jsx, title: nil)
            artifact.title = guessTitle(artifact)
            return artifact
        }
        return nil
    }

    // MARK: Fences

    private struct Fence {
        let lang: String
        let code: String
        let end: String.Index
    }

    private static func fences(in text: String) -> [Fence] {
        guard let regex = try? NSRegularExpression(pattern: #"```([\w-]*)[ \t]*\n([\s\S]*?)```"#) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let lang = Range(match.range(at: 1), in: text), let code = Range(match.range(at: 2), in: text),
                  let full = Range(match.range, in: text)
            else { return nil }
            return Fence(lang: text[lang].lowercased(), code: text[code].trimmingCharacters(in: .whitespacesAndNewlines), end: full.upperBound)
        }
    }

    /// A reply cut off by a token limit loses the closing fence of its final block.
    private static func trailingOpenFence(_ message: String, after: String.Index) -> (lang: String, code: String)? {
        let tail = String(message[after...])
        guard let regex = try? NSRegularExpression(pattern: #"```([\w-]*)[ \t]*\r?\n([\s\S]*)$"#),
              let match = regex.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)),
              let lang = Range(match.range(at: 1), in: tail), let code = Range(match.range(at: 2), in: tail)
        else { return nil }
        let trimmed = tail[code].trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : (tail[lang].lowercased(), trimmed)
    }

    // MARK: Titles

    private static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func firstCapture(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    /// A best-effort title from the artifact itself.
    public static func guessTitle(_ artifact: ChatArtifact) -> String? {
        if artifact.kind == .html {
            let fromTitle = firstCapture(#"<title[^>]*>([\s\S]*?)</title>"#, in: artifact.content, options: .caseInsensitive)
            let fromH1 = firstCapture(#"<h1[^>]*>([\s\S]*?)</h1>"#, in: artifact.content, options: .caseInsensitive)
            let guess = stripTags(fromTitle ?? fromH1 ?? "")
            return guess.isEmpty ? nil : String(guess.prefix(80))
        }
        let name = firstCapture(#"\bexport\s+default\s+(?:async\s+)?(?:function|class)\s+([A-Z][\w$]*)"#, in: artifact.content)
            ?? firstCapture(#"\bfunction\s+([A-Z][\w$]*)\s*\("#, in: artifact.content)
            ?? firstCapture(#"\b(?:const|let|var)\s+([A-Z][\w$]*)\s*=\s*(?:\([^)]*\)|[\w$]+)\s*=>"#, in: artifact.content)
        guard let name else { return nil }
        // CamelCase component names read better as words: "PomodoroTimer" -> "Pomodoro Timer".
        let spaced = name.replacingOccurrences(of: #"([a-z0-9])([A-Z])"#, with: "$1 $2", options: .regularExpression)
        return String(spaced.prefix(80))
    }
}

public enum KeepReply {
    /// What to hand `POST /api/keep` when the thing to keep is an assistant reply, or nil when
    /// there is nothing in it. A code block wins (a reply that contains a page keeps the page, not
    /// the "here you go" around it): a whole HTML document as it is, anything else as a single
    /// fenced block tagged with the kind the detector found. A reply with no page is kept whole.
    public static func content(of reply: String) -> String? {
        guard let artifact = ChatArtifactExtractor.extract(reply) else {
            let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if ChatArtifactExtractor.isFullHTMLDocument(artifact.content) { return artifact.content }
        return "```\(artifact.kind.rawValue)\n\(artifact.content)\n```"
    }
}
