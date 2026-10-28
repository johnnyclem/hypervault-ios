import Foundation
import HyperVaultKit

/// What a person is typing into the add and replace forms. It lives in the form's `@State` and nowhere
/// else: when the sheet closes it is gone.
struct VaultDraft {
    /// The kinds a plain key can have, offered as the old secrets form offered them.
    static let keyKinds: [SecretKind] = [.opaque, .header, .oauthGrant]

    var kind: SecretKind
    /// A login, card or contact: keyed by `VaultItemKind.fields`.
    var fields: [String: String] = [:]
    /// A key's value, kept exactly as typed.
    var value = ""
    /// The name as typed, for the add form. Nil until the person edits the Name field: until then the suggestion
    /// (from the username, the card, the address) fills it in.
    var typedName: String?

    var itemKind: VaultItemKind? { kind.vaultItemKind }

    /// Why this cannot be saved yet, worded for the person, or nil when the server would accept it. A value over 64 KB
    /// is the server's own refusal, said before the request is made.
    var problem: String? {
        if let itemKind {
            return VaultItems.validate(itemKind, fields) ?? VaultLimits.valueProblem(VaultItems.serialize(itemKind, fields))
        }
        if value.isEmpty { return "Add the value." }
        return VaultLimits.valueProblem(value)
    }

    /// Whether anything has been typed into the value's fields, so the line under the form only speaks once someone
    /// has started.
    var isTouched: Bool {
        itemKind == nil ? !value.isEmpty : fields.values.contains { !$0.isEmpty }
    }

    /// Whether closing the form would drop something typed: the value, or a name of the person's own.
    var isDirty: Bool {
        isTouched || !(typedName ?? "").isEmpty
    }

    /// The text sent as `value`: the canonical JSON for a typed entry, the key's text as typed.
    var serialized: String {
        if let itemKind { return VaultItems.serialize(itemKind, fields) }
        return value
    }

    var suggestedName: String {
        guard let itemKind else { return "" }
        return VaultItems.suggestName(itemKind, fields)
    }

    // MARK: The name

    /// The name as the form sends it: what is typed, or the suggestion until something is, trimmed the way the web trims.
    var name: String {
        VaultItems.trimmedName(typedName ?? suggestedName)
    }

    /// What is wrong with the name, as the line under the field says it, or nil when it is fine or still empty. "." and ".."
    /// follow the server's rule and cannot be addressed as a path, so they are refused here.
    var nameProblem: String? {
        let name = name
        if name.isEmpty { return nil }
        if !VaultItems.isValidName(name) { return VaultItems.nameHint }
        if !VaultItems.isAddressableName(name) { return VaultScreenCopy.dotsOnlyName }
        return nil
    }

    /// Whether the server would take this entry as it stands: the value passes and the name can be addressed.
    var canSave: Bool {
        problem == nil && VaultItems.isAddressableName(name)
    }

    // MARK: The card number

    /// What is wrong with the card number alone, for its field to show once the person has left it: fewer than 12
    /// digits, or a failed checksum. Nil while the field is empty, and when the number is fine (a problem with the
    /// expiry is not this field's).
    var cardNumberProblem: String? {
        guard kind == .card else { return nil }
        let digits = VaultItems.asciiDigits(fields["number"] ?? "")
        guard !digits.isEmpty else { return nil }
        let isValid = (12...19).contains(digits.count) && VaultItems.luhnValid(digits)
        return isValid ? nil : VaultItems.validate(.card, ["number": digits])
    }
}

/// A 409 on a name and the name it was said of, so the line goes when the field no longer holds that name: a suggestion
/// that moves while the person fixes the value is not the name the server refused.
struct VaultNameRefusal: Equatable {
    let name: String
    let message: String

    /// The line to show under a field that holds `current`, or nil once it holds another name.
    func line(whenNamed current: String) -> String? {
        current == name ? message : nil
    }
}
