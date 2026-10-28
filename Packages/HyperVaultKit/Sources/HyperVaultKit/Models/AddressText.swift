import Foundation

/// How a host, a URL or an email is drawn when it has to run over more than one line.
///
/// A line breaker finds no place to break in "hooks.example.org", so a narrow line breaks the word and adds a hyphen
/// ("example.-" then "com"), and the hyphen reads as part of the address. A zero width space after a ".", an "@" or a
/// "/" gives it a place to break between the parts instead. The space is for drawing only: what is copied, shared,
/// compared or read aloud is the real string, so a view that draws `breakable(_:)` names the real one for VoiceOver.
public enum AddressText {
    /// U+200B ZERO WIDTH SPACE: no width and no glyph, and a place where a line may break.
    public static let breakOpportunity: Character = "\u{200B}"

    /// Where a line may break: after these.
    private static let breakAfter: Set<Character> = [".", "@", "/"]

    /// `address` with a break opportunity after each ".", "@" and "/" that has something after it to break before.
    /// Not at the end, not before white space, and not inside a run ("https://" breaks after the second slash only),
    /// so a sentence that ends on an address, or an address with a dot at its end, is not given a break it did not
    /// need. Taking the break opportunities out again gives `address` back, and giving it to this twice changes nothing.
    public static func breakable(_ address: String) -> String {
        let characters = Array(address)
        var result = ""
        result.reserveCapacity(address.utf8.count + address.utf8.count / 4)
        for (index, character) in characters.enumerated() {
            result.append(character)
            guard breakAfter.contains(character), index + 1 < characters.count else { continue }
            let next = characters[index + 1]
            if breakAfter.contains(next) || next == breakOpportunity || next.isWhitespace { continue }
            result.append(breakOpportunity)
        }
        return result
    }
}
