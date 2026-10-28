import Foundation

// Sharing a chat reply out of the thread. The title rule of the web app's lib/chat/share.ts (`shareTitle`), so a reply
// saved as a memory is named the way the web names it. The page wrapper in that file has no use here: Keep sends the
// server the reply itself. White space and the 80-unit cap are JavaScript's (`\s`, `trim`, `slice`), not Foundation's,
// for the reasons VaultText.swift gives.

public enum ChatShare {
    /// The longest title, counted in UTF-16 units the way `slice(0, 80)` counts them.
    public static let maxTitleUnits = 80

    /// What a reply is called when nothing else names it.
    public static let fallbackTitle = "Chat reply"

    /// Best-effort title for a shared reply: the message that produced it, or its first line without the markdown
    /// lead-in (`#`, `>`, `-`, `*` and white space). A message of only white space names nothing.
    public static func title(content: String, sourcePrompt: String? = nil) -> String {
        if let sourcePrompt {
            let prompt = VaultItems.jsTrim(collapsingWhiteSpace(sourcePrompt))
            if !prompt.isEmpty { return capped(prompt) }
        }
        for line in content.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false) {
            let first = VaultItems.jsTrim(String(line.drop(while: isLeadIn)))
            if !first.isEmpty { return capped(first) }
        }
        return fallbackTitle
    }

    /// The scalars `/^[#>\-*\s]+/` strips from the front of a line.
    private static func isLeadIn(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "#" || scalar == ">" || scalar == "-" || scalar == "*" || VaultItems.isJSWhitespace(scalar)
    }

    /// `text.replace(/\s+/g, " ")`: each run of white space becomes one space.
    private static func collapsingWhiteSpace(_ text: String) -> String {
        var scalars: [Unicode.Scalar] = []
        var inRun = false
        for scalar in text.unicodeScalars {
            if VaultItems.isJSWhitespace(scalar) {
                if !inRun { scalars.append(" ") }
                inRun = true
            } else {
                scalars.append(scalar)
                inRun = false
            }
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// `text.slice(0, 80)`: the first 80 UTF-16 units. A character that would be cut in half (a surrogate pair
    /// that straddles the limit) is left out whole, where JavaScript would keep a lone half that no string here can hold.
    private static func capped(_ text: String) -> String {
        var units = 0
        var scalars: [Unicode.Scalar] = []
        for scalar in text.unicodeScalars {
            units += scalar.value > 0xFFFF ? 2 : 1
            if units > maxTitleUnits { break }
            scalars.append(scalar)
        }
        return String(String.UnicodeScalarView(scalars))
    }
}
