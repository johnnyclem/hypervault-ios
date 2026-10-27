import Foundation

// The text rules the server runs, which are JavaScript's and not Foundation's. lib/secrets/items.ts trims with
// `String.prototype.trim`, strips card numbers with the regex class `\s` and counts digits with `\d`; each of those
// has its own idea of white space and of a digit, and a form that follows Foundation's instead lets Save through
// for an entry the server refuses (or refuses one it takes). Everything here compares Unicode scalars against
// explicit lists, never `CharacterSet` or `Unicode.Scalar.Properties.isWhitespace`, whose answers change with the
// platform's Unicode tables.

extension VaultItems {
    /// Whether JavaScript counts `scalar` as white space: what `trim()` removes and what `\s` matches. That is the
    /// tab, line feed, vertical tab, form feed and carriage return (U+0009 to U+000D), the space, U+00A0, U+1680,
    /// U+2000 to U+200A, the line and paragraph separators (U+2028, U+2029), U+202F, U+205F, U+3000 and the byte
    /// order mark (U+FEFF). Foundation's `.whitespacesAndNewlines` also holds U+0085 (and, on Linux, U+200B) and
    /// lacks U+FEFF.
    public static func isJSWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0009...0x000D, 0x0020, 0x00A0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            return true
        default:
            return false
        }
    }

    /// `text.trim()` as JavaScript does it: JavaScript white space removed from both ends, nothing else touched.
    public static func jsTrim(_ text: String) -> String {
        let view = text.unicodeScalars
        var start = view.startIndex
        var end = view.endIndex
        while start < end, isJSWhitespace(view[start]) { start = view.index(after: start) }
        while start < end {
            let before = view.index(before: end)
            guard isJSWhitespace(view[before]) else { break }
            end = before
        }
        return String(String.UnicodeScalarView(view[start..<end]))
    }

    /// The name as the forms send it: trimmed the way the web trims it. `isValidName` then judges the result, so
    /// "abc\n" is accepted after this and a name that is only a newline is not.
    public static func trimmedName(_ text: String) -> String {
        jsTrim(text)
    }

    /// A name that passes `isValidName` and can also be addressed as a path segment. "." and ".." pass the rule
    /// (it is `/^[A-Za-z0-9._-]{1,100}$/`) but a proxy or a server resolves them away, so `/api/secrets/..` reaches
    /// `/api/` and the entry could never be opened, allowed or deleted. `isValidName` stays equal to the web's
    /// rule; the forms use this one to refuse the two on create and rename (handoff 5.7, open question 6).
    public static func isAddressableName(_ name: String) -> Bool {
        isValidName(name) && name != "." && name != ".."
    }

    /// Only the ASCII digits 0 to 9 of `text`, in order, stopping at `limit` digits. For the month, year and
    /// security-code fields, whose validators are ASCII-only: `Character.isNumber` and `wholeNumberValue` also
    /// take Arabic-Indic, fullwidth and superscript digits, which the server refuses, so a field built on them
    /// shows a number Save will never accept.
    ///
    /// With `transliterating` the Arabic-Indic (U+0660 to U+0669), Persian (U+06F0 to U+06F9) and fullwidth
    /// (U+FF10 to U+FF19) digits are turned into their ASCII twins first, so a person on an Arabic number pad
    /// can type a card and the value sent is ASCII. Anything else that is not a digit is dropped either way.
    public static func asciiDigits(_ text: String, limit: Int? = nil, transliterating: Bool = false) -> String {
        var out = String.UnicodeScalarView()
        var kept = 0
        for scalar in text.unicodeScalars {
            if let limit, kept >= limit { break }
            var value = scalar.value
            if transliterating {
                switch value {
                case 0x0660...0x0669: value = 0x30 + (value - 0x0660)
                case 0x06F0...0x06F9: value = 0x30 + (value - 0x06F0)
                case 0xFF10...0xFF19: value = 0x30 + (value - 0xFF10)
                default: break
                }
            }
            guard value >= 0x30, value <= 0x39, let digit = Unicode.Scalar(value) else { continue }
            out.append(digit)
            kept += 1
        }
        return String(out)
    }
}
