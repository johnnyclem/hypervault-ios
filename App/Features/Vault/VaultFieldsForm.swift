import HyperVaultKit
import SwiftUI

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

    var itemKind: VaultItemKind? { kind.vaultItemKind }

    /// Why this cannot be saved yet, worded for the person, or nil when the server would accept it.
    var problem: String? {
        if let itemKind { return VaultItems.validate(itemKind, fields) }
        return value.isEmpty ? "Add the value." : nil
    }

    /// Whether anything has been typed, so the line under the form only speaks once someone has started.
    var isTouched: Bool {
        itemKind == nil ? !value.isEmpty : fields.values.contains { !$0.isEmpty }
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
}

/// The fields for one kind, with the keyboards and content types that fit. Every field has its label above
/// it, because a placeholder is faint and goes the moment someone types. Secrets (a password, a security
/// code, a key's value) are secure fields with a Show switch for checking what was typed; they never ask
/// the system to remember anything: no `.newPassword` (which offers to save it), no autocorrection.
///
/// It is a stack of fields, not Form rows: the screen that holds it scrolls it with the rest of its content.
struct VaultFieldsForm: View {
    @Binding var draft: VaultDraft
    /// A new key can say what kind it is; replacing a value keeps the kind it has.
    var showsKindPicker = true

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: HV.Space.l) {
            switch draft.kind {
            case .login: loginFields
            case .card: cardFields
            case .contact: contactFields
            case .opaque, .header, .oauthGrant: keyFields
            }
        }
    }

    private func binding(_ field: String) -> Binding<String> {
        Binding(get: { draft.fields[field] ?? "" }, set: { draft.fields[field] = $0 })
    }

    // MARK: Login

    @ViewBuilder
    private var loginFields: some View {
        HVLabeledField(
            title: "Website (optional)",
            footnote: "Include the full address, starting with https://, so an agent knows where it signs in."
        ) {
            // Verbatim: a plain string is read as Markdown, and an address in it is drawn as a link.
            TextField("Website", text: binding("url"), prompt: Text(verbatim: "https://github.com"))
                .accessibilityIdentifier("vault.field.website")
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        HVLabeledField(title: "Username") {
            TextField("Username or email", text: binding("username"))
                .accessibilityIdentifier("vault.field.username")
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        HVLabeledField(title: "Password") {
            VaultSecretField(title: "Password", text: binding("password"), contentType: .password)
        }
        HVLabeledField(title: "Notes (optional)") {
            TextField("Anything an agent should know", text: binding("notes"), axis: .vertical)
                .lineLimit(2...5)
        }
    }

    // MARK: Card

    @ViewBuilder
    private var cardFields: some View {
        let digits = (draft.fields["number"] ?? "").filter(\.isNumber)
        let brand = VaultItems.cardBrand(digits)
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            HVLabeledField(title: "Card number", footnote: "The list shows only the brand and the last four digits.") {
                HStack {
                    TextField("1234 5678 9012 3456", text: Binding(
                        get: { draft.fields["number"] ?? "" },
                        set: { draft.fields["number"] = VaultItems.formatCardNumber($0) }
                    ))
                    .keyboardType(.numberPad)
                    .textContentType(.creditCardNumber)
                    .autocorrectionDisabled()
                    .monospacedDigit()
                    if brand != .other { VaultBrandCard(brand: brand) }
                }
            }
            if digits.count >= 12, !VaultItems.luhnValid(digits) {
                KeysInlineMessage(text: "That card number doesn't look right. Check it for a typo.")
            }
        }
        // Side by side while there is room; stacked at accessibility sizes, where two fields would each be a sliver.
        if dynamicTypeSize.isAccessibilitySize {
            monthField
            yearField
        } else {
            HStack(alignment: .top, spacing: HV.Space.s) {
                monthField
                yearField
            }
        }
        HVLabeledField(title: "Security code (optional)") {
            VaultSecretField(title: "Security code", text: limited("cvc", 4), keyboard: .numberPad, contentType: .creditCardSecurityCode)
        }
        HVLabeledField(title: "Cardholder (optional)") {
            TextField("Name on the card", text: binding("cardholder"))
                .textContentType(.creditCardName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
        }
    }

    private var monthField: some View {
        HVLabeledField(title: "Expiry month") {
            TextField("MM", text: limited("expMonth", 2))
                .keyboardType(.numberPad)
                .textContentType(.creditCardExpirationMonth)
                .monospacedDigit()
        }
    }

    private var yearField: some View {
        HVLabeledField(title: "Expiry year") {
            TextField("YY", text: limited("expYear", 4))
                .keyboardType(.numberPad)
                .textContentType(.creditCardExpirationYear)
                .monospacedDigit()
        }
    }

    /// Digits only, at most `length` of them.
    private func limited(_ field: String, _ length: Int) -> Binding<String> {
        Binding(
            get: { draft.fields[field] ?? "" },
            set: { draft.fields[field] = String($0.filter(\.isNumber).prefix(length)) }
        )
    }

    // MARK: Contact

    @ViewBuilder
    private var contactFields: some View {
        HVLabeledField(title: "Full name") {
            TextField("Jane Appleseed", text: binding("fullName"))
                .textContentType(.name)
                .textInputAutocapitalization(.words)
        }
        HVLabeledField(title: "Email") {
            TextField("jane@appleseed.dev", text: binding("email"))
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        HVLabeledField(title: "Phone") {
            TextField("+1 555 0100", text: binding("phone"))
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
        }
        HVLabeledField(title: "Address") {
            TextField("Street, city, postcode", text: binding("address"), axis: .vertical)
                .lineLimit(2...5)
                .textContentType(.fullStreetAddress)
        }
        Text("Add at least one. The list shows an email, or the last four digits of a phone number, never the rest.")
            .font(.hvCaption)
            .foregroundStyle(Palette.textSecondary)
    }

    // MARK: Key

    @ViewBuilder
    private var keyFields: some View {
        if showsKindPicker {
            HVLabeledField(title: "Kind") {
                Picker("Kind", selection: $draft.kind) {
                    ForEach(VaultDraft.keyKinds, id: \.self) { kind in Text(kind.label).tag(kind) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        HVLabeledField(
            title: "Value",
            footnote: "An API token, a header value or an OAuth grant. The agents you allow read it by name."
        ) {
            VaultSecretField(title: "Value", text: $draft.value, contentType: nil)
        }
    }
}

/// A secure field with a Show switch, for checking what was typed before it is saved. It hides again when the
/// app leaves the foreground, and it only exists in the forms that create or replace a value: a saved value is
/// never shown.
struct VaultSecretField: View {
    let title: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default
    var contentType: UITextContentType?

    @State private var revealed = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        HStack(spacing: HV.Space.s) {
            field
                .keyboardType(keyboard)
                .textContentType(contentType)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button {
                revealed.toggle()
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
                    .foregroundStyle(Palette.textSecondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The tap area is 44pt square, but the field it sits in takes its height from the text, so a
            // secret field is as tall as the others. The button's extra height overlaps the field's own padding.
            .padding(.vertical, -HV.Space.s)
            .accessibilityLabel(revealed ? "Hide \(title.lowercased())" : "Show \(title.lowercased())")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { revealed = false }
        }
    }

    /// `vault.field.password`, `vault.field.security-code`, `vault.field.value`.
    private var fieldID: String {
        "vault.field." + title.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    @ViewBuilder
    private var field: some View {
        if revealed {
            TextField(title, text: $text)
                .accessibilityIdentifier(fieldID)
        } else {
            SecureField(title, text: $text)
                .accessibilityIdentifier(fieldID)
        }
    }
}
