import Foundation

// What the server will not take, so the forms can say so before Save instead of after a 400. Capabilities does
// not carry these (handoff 5.12, open question 11), so the app has to know them itself. The server stays final:
// where the handoff or the files here do not pin an exact comparison, the check below is the looser one, so the
// app never blocks something the server would have taken.

/// The vault's limits and the checks that go with them (handoff 5.12; `app/api/secrets/route.ts:19-20,100,107-108`).
public enum VaultLimits {
    /// Entries per account. The server answers a 400 "Limit of 100 secrets reached." for the 101st.
    public static let maxEntries = 100

    /// Bytes of one value, as sent: UTF-8, counted with `Buffer.byteLength` on the server and so with `utf8.count`
    /// here, not `String.count` (graphemes) or `utf16.count`. For a typed entry the value is the canonical JSON
    /// (`VaultItems.serialize`), for a key the text as typed. 64 KB is read as 64 * 1024 and the check as "more
    /// than"; route.ts was not among the files, so neither is verified, and both are the looser reading.
    public static let maxValueBytes = 64 * 1024

    /// UTF-16 units of a secret's description (the "Note" a person types). The server does not refuse a longer one:
    /// `body.description.slice(0, 500)` (`app/api/secrets/route.ts:107-108`) cuts it silently, and `slice` counts
    /// UTF-16 units, so an emoji uses two. There is no 400 and so no message for it; a form that takes a note stops
    /// the field at this count (`clampedDescription`) so what was typed is what is kept.
    public static let maxDescription = 500

    /// A name is 1 to 100 characters of `[A-Za-z0-9._-]` (`VaultItems.isValidName`).
    public static let maxNameLength = 100

    /// A hint is cut to this many code points (`VaultItems.hintMax`).
    public static let maxHint = VaultItems.hintMax

    // MARK: The server's sentences

    /// The 400 for a value over the limit (handoff 5.12).
    public static let valueTooLargeMessage = "value is too large (max 64 KB)."

    /// The 400 for the entry past the limit (handoff 5.12).
    public static let entryLimitMessage = "Limit of 100 secrets reached."

    /// The 400 for a missing or empty value (handoff 5.12).
    public static let valueRequiredMessage = "value is required."

    /// The 400 for a bad name (handoff 5.7).
    public static let invalidNameMessage = "name must be 1–100 chars: letters, digits, dot, dash, or underscore."

    // MARK: Checks

    /// How many bytes the server will count in `value`.
    public static func valueByteCount(_ value: String) -> Int {
        value.utf8.count
    }

    /// Whether `value`, as it will be sent, is over the limit.
    public static func valueTooLarge(_ value: String) -> Bool {
        value.utf8.count > maxValueBytes
    }

    /// The server's own sentence when `value` is over the limit, else nil. For the draft's problem line.
    public static func valueProblem(_ value: String) -> String? {
        valueTooLarge(value) ? valueTooLargeMessage : nil
    }

    /// Whether an account with `count` entries has no room for another. For disabling Add.
    public static func entryLimitReached(count: Int) -> Bool {
        count >= maxEntries
    }

    /// The server's own sentence when `count` entries leave no room, else nil.
    public static func entryLimitProblem(count: Int) -> String? {
        entryLimitReached(count: count) ? entryLimitMessage : nil
    }

    /// How many characters of the description the server keeps count of: UTF-16 units, as `slice` counts them.
    public static func descriptionLength(_ text: String) -> Int {
        text.utf16.count
    }

    /// Whether the server would cut the description.
    public static func descriptionTooLong(_ text: String) -> Bool {
        descriptionLength(text) > maxDescription
    }

    /// `text` cut to the limit, for a field that stops taking input there. It never ends in half of a surrogate pair
    /// (the server's `slice` would leave one), so an emoji that does not fit is dropped whole.
    public static func clampedDescription(_ text: String) -> String {
        guard descriptionTooLong(text) else { return text }
        var kept = String.UnicodeScalarView()
        var used = 0
        for scalar in text.unicodeScalars {
            let width = scalar.value > 0xFFFF ? 2 : 1
            if used + width > maxDescription { break }
            kept.append(scalar)
            used += width
        }
        return String(kept)
    }
}
