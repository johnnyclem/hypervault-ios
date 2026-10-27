import Foundation

// The web's connect page ends several of its checks with a verdict the web can read out of its own database and a phone
// cannot: "the key's row in the Agent keys card on the Account page reads Agent connected". No route reports the server's
// check of a setup challenge to the app (handoff 5.10 and 10), so the guide the app lays out must not repeat the claim.

extension ConnectGuide {
    /// What the web writes on a key's row once its setup challenge has passed.
    static let verdictLabel = "Agent connected"

    /// The same guide with every sentence that says a key's row will read "Agent connected" taken out of its prose: the
    /// steps, the check, the notes and the warning. The strings to paste are code, not prose, and are never touched.
    /// A step or a check that was nothing but that sentence goes away; a sentence that carries the claim as a last clause
    /// keeps the clause before it.
    public func withoutVerdictClaims() -> ConnectGuide {
        var copy = self
        copy.steps = steps.compactMap(Self.removingVerdictClaims)
        copy.check = check.flatMap(Self.removingVerdictClaims)
        copy.warning = warning.flatMap(Self.removingVerdictClaims)
        copy.caveats = caveats.compactMap(Self.removingVerdictClaims)
        return copy
    }

    /// `text` without the sentences that make the claim, or nil when nothing else was in it.
    static func removingVerdictClaims(_ text: String) -> String? {
        guard text.contains(verdictLabel) else { return text }
        var kept: [String] = []
        for sentence in text.components(separatedBy: ". ") {
            guard let label = sentence.range(of: verdictLabel) else {
                kept.append(sentence)
                continue
            }
            // "..., and the key's row ... reads Agent connected": the clause before the "and" stands without it.
            if let join = sentence.range(of: ", and ", options: .backwards, range: sentence.startIndex..<label.lowerBound) {
                let head = String(sentence[..<join.lowerBound])
                if !head.isEmpty { kept.append(head) }
            }
        }
        var joined = kept.joined(separator: ". ")
        if text.hasSuffix("."), !joined.isEmpty, !joined.hasSuffix(".") { joined += "." }
        return joined.isEmpty ? nil : joined
    }
}
