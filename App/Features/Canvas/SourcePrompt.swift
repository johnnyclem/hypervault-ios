import Foundation

/// What `POST /api/keep` takes as `source_prompt`: at most 10,000 characters as the server counts
/// them, which is UTF-16 units (a JavaScript string's length), not Swift Characters. A longer one is a
/// 400, not a trim, so the app clips it as the web does (`trim().slice(0, 10000)`), but only between
/// characters, never through an emoji or a pair of units that belong together.
enum SourcePrompt {
    static let limit = 10_000

    /// The prompt trimmed and, if it is over the limit, cut at the last whole character that fits.
    /// Nil when nothing is left, so the field is left out as the web leaves it out.
    static func clipped(_ prompt: String, to limit: Int = SourcePrompt.limit) -> String? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf16.count > limit else { return trimmed.isEmpty ? nil : trimmed }
        var kept = ""
        var units = 0
        for character in trimmed {
            units += String(character).utf16.count
            if units > limit { break }
            kept.append(character)
        }
        return kept.isEmpty ? nil : kept
    }
}
