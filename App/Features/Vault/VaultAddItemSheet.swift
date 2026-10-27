import HyperVaultKit
import SwiftUI

/// What can be added, in the order the chooser lists it.
enum VaultAddType: String, CaseIterable, Identifiable, Hashable {
    case login, card, contact, key
    var id: String { rawValue }

    var title: String {
        switch self {
        case .login: return "Login"
        case .card: return "Card"
        case .contact: return "Contact info"
        case .key: return "Key"
        }
    }

    /// The title of its form (style guide 11.10).
    var formTitle: String {
        switch self {
        case .login: return "Add a login"
        case .card: return "Add a card"
        case .contact: return "Add contact info"
        case .key: return "Add a key"
        }
    }

    var detail: String {
        switch self {
        case .login: return "A site's username and password"
        case .card: return "A payment card"
        case .contact: return "A name, email, phone or address"
        case .key: return "An API token or header for an agent"
        }
    }

    /// What it is, drawn on the neutral tile (handoff 2.7).
    var symbol: String {
        switch self {
        case .login: return HVSymbol.login
        case .card: return HVSymbol.card
        case .contact: return HVSymbol.contact
        case .key: return HVSymbol.key
        }
    }

    var kind: SecretKind {
        switch self {
        case .login: return .login
        case .card: return .card
        case .contact: return .contact
        case .key: return .opaque
        }
    }

    var namePlaceholder: String {
        switch self {
        case .login: return "github.com"
        case .card: return "visa-4242"
        case .contact: return "home"
        case .key: return "github-mcp-token"
        }
    }
}

/// Add a login, a card, contact info or a key: pick the type, then fill in a form shaped for it. The form
/// checks with the same rules the server uses (`VaultItems`), so Save stays off until the server would
/// accept the entry, and the line under the form says what is still missing. The server checks again.
///
/// The type picker is the root of a navigation stack and the form is pushed on it, so the system draws the push and the
/// back button. What is typed lives in this sheet's state, so the sheet knows when closing it would lose something: a swipe
/// down is then refused, and Close asks first. It is gone when the sheet closes. Nothing is shown again after a save.
struct VaultAddItemSheet: View {
    let model: VaultItemsModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var path: [VaultAddType]
    @State private var draft: VaultDraft
    @State private var confirmingDiscard = false

    /// `startingWith` skips the type choice, for a screen that already knows what it is adding.
    init(model: VaultItemsModel, startingWith kind: SecretKind? = nil) {
        self.model = model
        let start: VaultAddType?
        switch kind {
        case .login?: start = .login
        case .card?: start = .card
        case .contact?: start = .contact
        case .some: start = .key
        case nil: start = nil
        }
        _path = State(initialValue: start.map { [$0] } ?? [])
        _draft = State(initialValue: VaultDraft(kind: kind ?? .login))
    }

    /// Whether closing now would drop something typed.
    private var isDirty: Bool { !path.isEmpty && draft.isDirty }

    var body: some View {
        NavigationStack(path: $path) {
            chooser
                .navigationTitle(VaultScreenCopy.addTitle)
                .navigationBarTitleDisplayMode(.inline)
                .hvScreenBackground()
                .toolbar { closeButton }
                .navigationDestination(for: VaultAddType.self) { type in
                    VaultNewItemForm(model: model, type: type, draft: $draft, onSaved: { dismiss() })
                        .navigationTitle(type.formTitle)
                        .navigationBarTitleDisplayMode(.inline)
                        .hvScreenBackground()
                        .toolbar { closeButton }
                }
        }
        .hvSensitive(!path.isEmpty)
        .vaultDiscardGuard(isDirty: isDirty, isPresented: $confirmingDiscard) { dismiss() }
        // Back to the chooser drops what was typed, as closing does.
        .onChange(of: path) { _, now in
            if now.isEmpty { draft = VaultDraft(kind: .login) }
        }
    }

    @ToolbarContentBuilder
    private var closeButton: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            VaultCloseButton { if isDirty { confirmingDiscard = true } else { dismiss() } }
        }
    }

    private var chooser: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HV.Space.m) {
                Text(VaultScreenCopy.chooseLine)
                    .font(.hvCallout)
                    .foregroundStyle(Palette.textSecondary)
                // A grid, not a flowing layout: the tiles of a row take the height of the tallest, so the
                // edges line up whatever each description's length.
                Grid(horizontalSpacing: HV.Space.s, verticalSpacing: HV.Space.s) {
                    ForEach(Array(chooserRows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(row) { choice in tile(choice) }
                        }
                    }
                }
                if let limit = VaultLimits.entryLimitProblem(count: model.secrets.count) {
                    KeysInlineMessage(text: limit)
                }
                Label(HVCopy.landingVaultLockLine, systemImage: "lock.fill")
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.textSecondary)
            }
            .padding(HV.Space.m)
            .hvReadableWidth()
        }
    }

    /// Two tiles to a row, one at accessibility sizes where two would each be a narrow column of words.
    private var chooserRows: [[VaultAddType]] {
        let all = VaultAddType.allCases
        let width = dynamicTypeSize.isAccessibilitySize ? 1 : 2
        return stride(from: 0, to: all.count, by: width).map { Array(all[$0 ..< min($0 + width, all.count)]) }
    }

    private func tile(_ choice: VaultAddType) -> some View {
        Button {
            Haptics.select()
            draft = VaultDraft(kind: choice.kind)
            path.append(choice)
        } label: {
            VStack(alignment: .leading, spacing: HV.Space.s) {
                HVTile(symbol: choice.symbol)
                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.title).font(.hvHeadline).foregroundStyle(Palette.textPrimary)
                    Text(choice.detail)
                        .font(.hvCaption)
                        .foregroundStyle(Palette.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .hvCard()
        }
        .buttonStyle(.plain)
        .disabled(model.isFull)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("vault.add.\(choice.rawValue)")
    }
}

// MARK: The form

private struct VaultNewItemForm: View {
    let model: VaultItemsModel
    let type: VaultAddType
    @Binding var draft: VaultDraft
    let onSaved: () -> Void

    @Environment(AppModel.self) private var app

    @State private var saving = false
    @State private var error: String?
    /// A 409: the name is in use. Said under the Name field, which takes the cursor and VoiceOver's focus.
    @State private var nameError: String?
    @FocusState private var nameFocused: Bool
    @AccessibilityFocusState private var nameSpoken: Bool

    private var canSave: Bool {
        !saving && !model.isFull && draft.canSave
    }

    /// The line under the form: the account is full, or the first thing still missing once anything has been typed.
    private var shownProblem: String? {
        if let limit = VaultLimits.entryLimitProblem(count: model.secrets.count) { return limit }
        return draft.isTouched ? draft.problem : nil
    }

    var body: some View {
        ScrollViewReader { proxy in
            form
                // A taken name is said under the Name field, and the keyboard that comes up for it covers what is under the
                // field: once it is up, the name and its line are brought into the middle of what is left.
                .onChange(of: nameError) { _, error in
                    guard error != nil else { return }
                    Task {
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        proxy.scrollTo(Self.nameBlockID, anchor: .center)
                    }
                }
        }
    }

    private static let nameBlockID = "vault.add.name-block"

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HV.Space.l) {
                // A key is named first, then given its kind and value; the others are named from what is typed, so the
                // name comes after the fields it is made from.
                if draft.itemKind == nil {
                    nameBlock
                    VaultFieldsForm(draft: $draft)
                } else {
                    VaultFieldsForm(draft: $draft)
                    nameBlock
                }

                VStack(alignment: .leading, spacing: HV.Space.s) {
                    if let shownProblem {
                        KeysInlineMessage(text: shownProblem, isError: model.isFull)
                    }
                    if let error { KeysInlineMessage(text: error) }
                    Button {
                        Task { await save() }
                    } label: {
                        HStack(spacing: HV.Space.xs) {
                            if saving { ProgressView().tint(.white) }
                            Text(saving ? VaultScreenCopy.savingLabel : VaultScreenCopy.saveLabel)
                        }
                    }
                    .buttonStyle(.hvPrimary)
                    .disabled(!canSave)
                    Text(VaultScreenCopy.afterSaveLine)
                        .font(.hvCaption)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            .padding(HV.Space.m)
            .hvReadableWidth()
        }
        .scrollDismissesKeyboard(.interactively)
        // The web's polite live region: the line under the form is spoken when it changes, after the person has stopped
        // typing for a moment so it does not talk over every keystroke.
        .task(id: shownProblem) {
            guard let line = shownProblem else { return }
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            VaultAnnouncement.polite(line)
        }
    }

    private var nameBlock: some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            // The rule is the footnote, and turns destructive, with the field's edge, when the name breaks it.
            HVLabeledField(
                title: "Name", footnote: draft.nameProblem ?? VaultItems.nameHint,
                isFocused: nameFocused, isInvalid: draft.nameProblem != nil || nameError != nil
            ) {
                TextField(type.namePlaceholder, text: Binding(
                    get: { draft.typedName ?? draft.suggestedName },
                    set: { draft.typedName = $0; nameError = nil }
                ))
                .font(.system(.body, design: .monospaced))
                .keyboardType(.asciiCapable)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($nameFocused)
                .accessibilityFocused($nameSpoken)
                .accessibilityLabel("Name")
                .accessibilityIdentifier("vault.add.name")
            }
            Text("Agents ask for it by this name.")
                .font(.hvCaption)
                .foregroundStyle(Palette.textSecondary)
            if let nameError { KeysInlineMessage(text: nameError) }
        }
        .id(Self.nameBlockID)
    }

    private func save() async {
        guard canSave else { return }
        saving = true
        error = nil
        nameError = nil
        defer { saving = false }
        switch await model.create(name: draft.name, kind: draft.kind, value: draft.serialized) {
        case .created:
            draft = VaultDraft(kind: type.kind)
            Haptics.success()
            app.toasts.success("Saved. Allow an agent to use it from its page.")
            onSaved()
        case .failure(let failure):
            Haptics.failure()
            if failure.isConflict {
                // A taken name is the name field's problem, so it is said there, and the cursor and VoiceOver go there.
                nameError = failure.message
                nameFocused = true
                nameSpoken = true
            } else {
                error = failure.message
            }
        }
    }
}

#if DEBUG
#Preview("Add, choose") {
    PreviewHost(routes: VaultPreviewData.routes, embedInNavigation: false) { VaultAddPreview() }
}

#Preview("Add a card") {
    PreviewHost(routes: VaultPreviewData.routes, embedInNavigation: false) { VaultAddPreview(kind: .card) }
}

struct VaultAddPreview: View {
    var kind: SecretKind?

    @Environment(AppEnvironment.self) private var env
    @State private var model: VaultItemsModel?

    var body: some View {
        Group {
            if let model { VaultAddItemSheet(model: model, startingWith: kind) } else { HVLoadingState() }
        }
        .task { model = VaultItemsModel(client: env.client, rest: env.keysRest, userID: env.user.id) }
    }
}
#endif
