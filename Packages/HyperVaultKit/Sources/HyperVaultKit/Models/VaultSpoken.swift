import Foundation

// A row's hint is "Visa •••• 4242", and VoiceOver reads four U+2022 bullets as "bullet bullet bullet bullet" or
// not at all, depending on the person's punctuation setting. The handoff (4.3, 9) proposes keeping the visible
// text and having the accessibility label say "ending in 4242" (copy for the owner).

extension VaultItems {
    /// `hint` as it should be spoken. The mask the server writes, four U+2022 bullets and a space before four ASCII
    /// digits, at the end of the hint, reads as "ending in" and the digits:
    ///
    ///     "Visa •••• 4242"  ->  "Visa ending in 4242"
    ///     "•••• 1234"       ->  "ending in 1234"
    ///
    /// Anything else, a username, an email, "Address", a key's kind, and a hint where the mask is not set off by
    /// a space or is followed by more than four digits, is returned as it is. The visible text is never changed.
    public static func spokenHint(_ hint: String) -> String {
        let scalars = Array(hint.unicodeScalars)
        let tailLength = 9  // "••••", a space and four digits
        guard scalars.count >= tailLength else { return hint }
        let tailStart = scalars.count - tailLength
        let tail = scalars[tailStart...]
        let bullets = tail.prefix(4)
        let digits = tail.suffix(4)
        guard bullets.allSatisfy({ $0.value == 0x2022 }), tail[tailStart + 4] == " ",
              digits.allSatisfy({ $0.value >= 0x30 && $0.value <= 0x39 })
        else { return hint }
        let spokenDigits = String(String.UnicodeScalarView(digits))
        if tailStart == 0 { return "ending in " + spokenDigits }
        // Something before the mask has to end in the space that sets it off ("Visa " + the mask).
        guard scalars[tailStart - 1] == " " else { return hint }
        return String(String.UnicodeScalarView(scalars[0..<tailStart])) + "ending in " + spokenDigits
    }
}

extension VaultSecret {
    /// `subtitle` as it should be spoken: the hint with its mask read as "ending in 4242". Use it in the row's
    /// accessibility label and the detail header's; the visible `subtitle` stays as it is.
    public var spokenSubtitle: String {
        VaultItems.spokenHint(subtitle)
    }
}
