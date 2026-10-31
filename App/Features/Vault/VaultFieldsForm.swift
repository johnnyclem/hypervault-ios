import HyperVaultKit
import SwiftUI

/// The fields for one kind, with the keyboards and content types that fit. Every field has its label above
/// it, because a placeholder is faint and goes the moment someone types; the prompt in an empty one is `hvPrompt`, as the
/// system's own is under 2:1. Secrets (a password, a security code, a key's value) are secure fields with a Show switch
/// for checking what was typed; they never ask the system to remember anything: no `.newPassword` (which offers to save
/// it), no autocorrection.
///
/// It is a stack of fields, not Form rows: the screen that holds it scrolls it with the rest of its content.
struct VaultFieldsForm: View {
    @Binding var draft: VaultDraft
    /// A new key can say what kind it is; replacing a value keeps the kind it has.
    var showsKindPicker = true

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var numberFocused: Bool
    /// The card number has been left once with something in it: from then on its own invalid state may show.
    @State private var numberLeft = false

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

    /// A field with its label above it. VoiceOver reads the same words as the field's name, since a field's own title is
    /// its placeholder and the label above is only text beside it.
    private func labelled<Field: View>(
        _ title: String, footnote: String? = nil, isFocused: Bool = false, isInvalid: Bool = false,
        @ViewBuilder field: @escaping () -> Field
    ) -> some View {
        HVLabeledField(title: title, footnote: footnote, isFocused: isFocused, isInvalid: isInvalid) {
            field().accessibilityLabel(title)
        }
    }

    // MARK: Login

    @ViewBuilder
    private var loginFields: some View {
        labelled(
            "Website (optional)",
            footnote: "Include the full address, starting with https://, so an agent knows where it signs in."
        ) {
            // `hvPrompt` takes the string as it is: a literal `Text` reads Markdown and would draw the address as a link.
            TextField("Website", text: binding("url"), prompt: .hvPrompt("https://github.com"))
                .accessibilityIdentifier("vault.field.website")
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        labelled("Username") {
            TextField("Username", text: binding("username"), prompt: .hvPrompt("Username or email"))
                .accessibilityIdentifier("vault.field.username")
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        HVLabeledField(title: "Password") {
            VaultSecretField(title: "Password", identifier: "password", spokenName: "password", text: binding("password"), contentType: .password)
        }
        labelled("Notes (optional)") {
            TextField("Notes", text: binding("notes"), prompt: .hvPrompt("Anything an agent should know"), axis: .vertical)
                .lineLimit(2...5)
        }
    }

    // MARK: Card

    @ViewBuilder
    private var cardFields: some View {
        let brand = VaultItems.cardBrand(VaultItems.asciiDigits(draft.fields["number"] ?? ""))
        // Its own invalid state shows once the field has been left, not while the number is still being typed: the
        // footnote says what is wrong, in destructive, with the field's edge.
        let numberProblem = numberLeft && !numberFocused ? draft.cardNumberProblem : nil
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            labelled(
                "Card number", footnote: numberProblem ?? "The list shows only the brand and the last four digits.",
                isFocused: numberFocused, isInvalid: numberProblem != nil
            ) {
                HStack {
                    TextField("Card number", text: Binding(
                        get: { draft.fields["number"] ?? "" },
                        // Digits only, and only ASCII ones: an Arabic number pad types others, which the server refuses.
                        set: { draft.fields["number"] = VaultItems.formatCardNumber(VaultItems.asciiDigits($0, transliterating: true)) }
                    ), prompt: .hvPrompt("1234 5678 9012 3456"))
                    .accessibilityIdentifier("vault.field.card-number")
                    .keyboardType(.numberPad)
                    .textContentType(.creditCardNumber)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                    .focused($numberFocused)
                    if let tileBrand = HVCardBrand(brand) { HVCardBrandTile(brand: tileBrand) }
                }
            }
        }
        .onChange(of: numberFocused) { _, focused in
            if !focused, !(draft.fields["number"] ?? "").isEmpty { numberLeft = true }
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
        HVLabeledField(title: "CVC (optional)") {
            VaultSecretField(
                title: "CVC (optional)", identifier: "security-code", spokenName: "security code",
                text: limited("cvc", 4), keyboard: .numberPad, contentType: .creditCardSecurityCode, prompt: "123"
            )
        }
        labelled("Cardholder (optional)") {
            TextField("Cardholder", text: binding("cardholder"), prompt: .hvPrompt("Name on the card"))
                .textContentType(.creditCardName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
        }
    }

    private var monthField: some View {
        labelled("Month") {
            TextField("Month", text: limited("expMonth", 2), prompt: .hvPrompt("MM"))
                .keyboardType(.numberPad)
                .textContentType(.creditCardExpirationMonth)
                .monospacedDigit()
        }
    }

    private var yearField: some View {
        labelled("Year") {
            TextField("Year", text: limited("expYear", 4), prompt: .hvPrompt("YY"))
                .keyboardType(.numberPad)
                .textContentType(.creditCardExpirationYear)
                .monospacedDigit()
        }
    }

    /// ASCII digits only, at most `length` of them: the validators are ASCII-only, so a field that took any other digit
    /// would show a number Save will never accept.
    private func limited(_ field: String, _ length: Int) -> Binding<String> {
        Binding(
            get: { draft.fields[field] ?? "" },
            set: { draft.fields[field] = VaultItems.asciiDigits($0, limit: length, transliterating: true) }
        )
    }

    // MARK: Contact

    @ViewBuilder
    private var contactFields: some View {
        labelled("Full name (optional)") {
            TextField("Full name", text: binding("fullName"), prompt: .hvPrompt("Jane Appleseed"))
                .textContentType(.name)
                .textInputAutocapitalization(.words)
        }
        labelled("Email (optional)") {
            TextField("Email", text: binding("email"), prompt: .hvPrompt("jane@appleseed.dev"))
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        labelled("Phone (optional)") {
            TextField("Phone", text: binding("phone"), prompt: .hvPrompt("+1 555 0100"))
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
        }
        labelled("Address (optional)") {
            TextField("Address", text: binding("address"), prompt: .hvPrompt("Street, city, postcode"), axis: .vertical)
                .lineLimit(2...5)
                .textContentType(.fullStreetAddress)
        }
        Text("Add at least one. The list shows an email, else the last four digits of a phone number, else the name. The rest is never shown.")
            .font(.hvCaption)
            .foregroundStyle(Palette.textSecondary)
    }

    // MARK: Key

    @ViewBuilder
    private var keyFields: some View {
        if showsKindPicker {
            VStack(alignment: .leading, spacing: 6) {
                Text("Kind")
                    .font(.hvFootnote.weight(.medium))
                    .foregroundStyle(Palette.textSecondary)
                // Key, MCP header, OAuth grant: a segmented control, a menu at accessibility sizes (HVChoicePicker).
                HVChoicePicker(title: "Kind", selection: $draft.kind) {
                    ForEach(VaultDraft.keyKinds, id: \.self) { kind in Text(kind.label).tag(kind) }
                }
                .accessibilityIdentifier("vault.field.kind")
            }
        }
        HVLabeledField(
            title: "Value",
            footnote: "An API token, a header value or an OAuth grant. The agents you allow read it by name."
        ) {
            VaultSecretField(title: "Value", identifier: "value", spokenName: "value", text: $draft.value, contentType: nil)
        }
    }
}

/// A secure field with a Show switch, for checking what was typed before it is saved. It hides again when the
/// app leaves the foreground, and it only exists in the forms that create or replace a value: a saved value is
/// never shown.
struct VaultSecretField: View {
    /// The field's name for VoiceOver.
    let title: String
    /// What follows `vault.field.` in the field's accessibility identifier.
    let identifier: String
    /// What the Show and Hide buttons name: "Show password".
    let spokenName: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default
    var contentType: UITextContentType?
    /// What the empty field shows. Empty when the label above already says what goes there; never bullets, which
    /// would read as characters already typed.
    var prompt = ""

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
            .accessibilityLabel(revealed ? "Hide \(spokenName)" : "Show \(spokenName)")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { revealed = false }
        }
    }

    @ViewBuilder
    private var field: some View {
        if revealed {
            TextField(title, text: $text, prompt: .hvPrompt(prompt))
                .accessibilityIdentifier("vault.field.\(identifier)")
        } else {
            SecureField(title, text: $text, prompt: .hvPrompt(prompt))
                .accessibilityIdentifier("vault.field.\(identifier)")
        }
    }
}
