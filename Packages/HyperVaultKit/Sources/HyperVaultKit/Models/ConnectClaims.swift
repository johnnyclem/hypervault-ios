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
    /// keeps what comes before it (see `instruction(in:before:)`).
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
            let head = instruction(in: sentence, before: label)
            if !head.isEmpty { kept.append(head) }
        }
        var joined = kept.joined(separator: ". ")
        if text.hasSuffix("."), !joined.isEmpty, !joined.hasSuffix(".") { joined += "." }
        return joined.isEmpty ? nil : joined
    }

    /// What can join an instruction to the clause that makes the claim: "Finish the challenge and the key's row ... reads
    /// Agent connected", "Run the tool; the key's row then shows ...", "Complete it, then check that the row says ...",
    /// "Send it: the row reads ...".
    private static let claimJoins = [", and ", " and ", "; ", ", then ", ": "]

    /// What a sentence says before the clause that makes the claim: everything up to the last join before that clause, and
    /// the rest goes. Empty when the sentence is only the claim ("Once it is written, the key's row reads Agent
    /// connected"), and when a comma stands between the join and the claim's subject ("Once you finish and open the page,
    /// the key's row reads ..."), where the words before the join would be left without their ending.
    private static func instruction(in sentence: String, before label: Range<String.Index>) -> String {
        // The claim's clause starts at its subject ("the key's row"), so a join inside it is not where the instruction ends.
        var clauseStart = label.lowerBound
        if let subject = sentence.range(of: " row", options: .backwards, range: sentence.startIndex..<clauseStart) {
            clauseStart = subject.lowerBound
        }
        // ", and " and " and " end in the same place: the one with the comma is the join, and the comma goes with it.
        let join = claimJoins
            .compactMap { sentence.range(of: $0, options: .backwards, range: sentence.startIndex..<clauseStart) }
            .max { $0.upperBound != $1.upperBound ? $0.upperBound < $1.upperBound : $0.lowerBound > $1.lowerBound }
        guard let join, !sentence[join.upperBound..<clauseStart].contains(",") else { return "" }
        return String(sentence[..<join.lowerBound])
    }
}
