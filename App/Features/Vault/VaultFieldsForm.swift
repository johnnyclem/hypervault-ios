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

/// The fields for one kind, with the keyboards and content types that fit. Secrets (a password, a security
/// code, a key's value) are secure fields with a Show switch for checking what was typed; they never ask
/// the system to remember anything: no `.newPassword` (which offers to save it), no autocorrection.
struct VaultFieldsForm: View {
    @Binding var draft: VaultDraft
    /// A new key can say what kind it is; replacing a value keeps the kind it has.
    var showsKindPicker = true

    var body: some View {
        switch draft.kind {
        case .login: loginFields
        case .card: cardFields
        case .contact: contactFields
        case .opaque, .header, .oauthGrant: keyFields
        }
    }

    private func binding(_ field: String) -> Binding<String> {
        Binding(get: { draft.fields[field] ?? "" }, set: { draft.fields[field] = $0 })
    }

    // MARK: Login

    @ViewBuilder
    private var loginFields: some View {
        Section {
            TextField("Website (optional)", text: binding("url"))
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Username", text: binding("username"))
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            VaultSecretField(title: "Password", text: binding("password"), contentType: .password)
            TextField("Notes (optional)", text: binding("notes"), axis: .vertical)
                .lineLimit(2...5)
        } footer: {
            Text("Include the full address, starting with https://, so an agent knows where it signs in.")
        }
    }

    // MARK: Card

    @ViewBuilder
    private var cardFields: some View {
        let digits = (draft.fields["number"] ?? "").filter(\.isNumber)
        let brand = VaultItems.cardBrand(digits)
        Section {
            HStack {
                TextField("Card number", text: Binding(
                    get: { draft.fields["number"] ?? "" },
                    set: { draft.fields["number"] = VaultItems.formatCardNumber($0) }
                ))
                .keyboardType(.numberPad)
                .textContentType(.creditCardNumber)
                .autocorrectionDisabled()
                .monospacedDigit()
                if brand != .other { VaultBrandCard(brand: brand) }
            }
            if digits.count >= 12, !VaultItems.luhnValid(digits) {
                KeysInlineMessage(text: "That card number doesn't look right. Check it for a typo.")
            }
            HStack(spacing: HV.Space.m) {
                TextField("MM", text: limited("expMonth", 2))
                    .keyboardType(.numberPad)
                    .textContentType(.creditCardExpirationMonth)
                TextField("YY", text: limited("expYear", 4))
                    .keyboardType(.numberPad)
                    .textContentType(.creditCardExpirationYear)
                VaultSecretField(title: "CVC", text: limited("cvc", 4), keyboard: .numberPad, contentType: .creditCardSecurityCode)
            }
            TextField("Cardholder (optional)", text: binding("cardholder"))
                .textContentType(.creditCardName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
        } footer: {
            Text("The list shows only the brand and the last four digits.")
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
        Section {
            TextField("Full name (optional)", text: binding("fullName"))
                .textContentType(.name)
                .textInputAutocapitalization(.words)
            TextField("Email (optional)", text: binding("email"))
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Phone (optional)", text: binding("phone"))
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
            TextField("Address (optional)", text: binding("address"), axis: .vertical)
                .lineLimit(2...5)
                .textContentType(.fullStreetAddress)
        } footer: {
            Text("Add at least one. The list shows an email, or the last four digits of a phone number, never the rest.")
        }
    }

    // MARK: Key

    @ViewBuilder
    private var keyFields: some View {
        Section {
            if showsKindPicker {
                Picker("Kind", selection: $draft.kind) {
                    ForEach(VaultDraft.keyKinds, id: \.self) { kind in Text(kind.label).tag(kind) }
                }
            }
            VaultSecretField(title: "Value", text: $draft.value, contentType: nil)
        } footer: {
            Text("An API token, a header value or an OAuth grant. The agents you allow read it by name.")
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
            .buttonStyle(.borderless)
            .accessibilityLabel(revealed ? "Hide \(title.lowercased())" : "Show \(title.lowercased())")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { revealed = false }
        }
    }

    @ViewBuilder
    private var field: some View {
        if revealed {
            TextField(title, text: $text)
        } else {
            SecureField(title, text: $text)
        }
    }
}
