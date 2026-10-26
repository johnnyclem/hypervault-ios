import HyperVaultKit
import SwiftUI

/// Add a login, a card, contact info or a key: pick the type, then fill in a form shaped for it. The form
/// checks with the same rules the server uses (`VaultItems`), so Save stays off until the server would
/// accept the entry, and the line under the form says what is still missing. The server checks again.
///
/// What is typed lives in this sheet's state and is gone when it closes. Nothing is shown again after a save.
struct VaultAddItemSheet: View {
    let model: VaultItemsModel

    @Environment(\.dismiss) private var dismiss

    private enum AddType: String, CaseIterable, Identifiable {
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

        var detail: String {
            switch self {
            case .login: return "A site's username and password"
            case .card: return "A payment card"
            case .contact: return "A name, email, phone or address"
            case .key: return "An API token or header for an agent"
            }
        }

        var symbol: String {
            switch self {
            case .login: return "globe"
            case .card: return "creditcard"
            case .contact: return "person.crop.circle"
            case .key: return "key.horizontal"
            }
        }

        var tint: Color {
            switch self {
            case .login: return Palette.blue
            case .card: return Palette.violet
            case .contact: return Palette.sky
            case .key: return Palette.amber
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

    @State private var type: AddType?

    /// `startingWith` skips the type choice, for a screen that already knows what it is adding.
    init(model: VaultItemsModel, startingWith kind: SecretKind? = nil) {
        self.model = model
        switch kind {
        case .login?: _type = State(initialValue: .login)
        case .card?: _type = State(initialValue: .card)
        case .contact?: _type = State(initialValue: .contact)
        case .some: _type = State(initialValue: .key)
        case nil: _type = State(initialValue: nil)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let type {
                    VaultNewItemForm(model: model, kind: type.kind, namePlaceholder: type.namePlaceholder, onSaved: { dismiss() })
                        .id(type)
                        .navigationTitle("Add a \(type.title.lowercased())")
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button { self.type = nil } label: { Label("Back", systemImage: "chevron.left") }
                            }
                        }
                } else {
                    chooser
                        .navigationTitle("Add to your vault")
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                        }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .hvScreenBackground()
        }
    }

    private var chooser: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HV.Space.m) {
                Text("What would you like to save?")
                    .font(.hvCallout)
                    .foregroundStyle(Palette.textSecondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: HV.Space.s)], spacing: HV.Space.s) {
                    ForEach(AddType.allCases) { choice in
                        Button {
                            Haptics.select()
                            type = choice
                        } label: {
                            VStack(alignment: .leading, spacing: HV.Space.s) {
                                HVIconBadge(symbol: choice.symbol, tint: choice.tint, size: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(choice.title).font(.hvHeadline).foregroundStyle(Palette.textPrimary)
                                    Text(choice.detail)
                                        .font(.hvCaption)
                                        .foregroundStyle(Palette.textSecondary)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .hvCard()
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                    }
                }
                Label("Values are encrypted when you save them and never shown again.", systemImage: "lock.fill")
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.textTertiary)
            }
            .padding(HV.Space.m)
            .hvReadableWidth()
        }
    }
}

// MARK: The form

private struct VaultNewItemForm: View {
    let model: VaultItemsModel
    let kind: SecretKind
    let namePlaceholder: String
    let onSaved: () -> Void

    @Environment(AppModel.self) private var app

    @State private var draft: VaultDraft
    @State private var typedName: String?
    @State private var details = ""
    @State private var saving = false
    @State private var error: String?
    @State private var nameError: String?

    init(model: VaultItemsModel, kind: SecretKind, namePlaceholder: String, onSaved: @escaping () -> Void) {
        self.model = model
        self.kind = kind
        self.namePlaceholder = namePlaceholder
        self.onSaved = onSaved
        _draft = State(initialValue: VaultDraft(kind: kind))
    }

    private var name: String {
        (typedName ?? draft.suggestedName).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !saving && draft.problem == nil && VaultItems.isValidName(name)
    }

    var body: some View {
        Form {
            VaultFieldsForm(draft: $draft)

            Section {
                TextField(namePlaceholder, text: Binding(get: { typedName ?? draft.suggestedName }, set: { typedName = $0; nameError = nil }))
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Note (optional)", text: $details)
            } header: {
                Text("Name")
            } footer: {
                VStack(alignment: .leading, spacing: HV.Space.xxs) {
                    Text("Agents ask for it by this name. \(VaultItems.nameHint)")
                    if !name.isEmpty, !VaultItems.isValidName(name) {
                        KeysInlineMessage(text: "Use letters, digits, dots, dashes and underscores. No spaces.")
                    }
                    if let nameError { KeysInlineMessage(text: nameError) }
                }
            }

            Section {
                if draft.isTouched, let problem = draft.problem {
                    KeysInlineMessage(text: problem, isError: false)
                }
                if let error { KeysInlineMessage(text: error) }
                Button {
                    Task { await save() }
                } label: {
                    if saving { ProgressView().tint(.white) } else { Text("Save") }
                }
                .buttonStyle(.hvPrimary)
                .disabled(!canSave)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: HV.Space.xs, leading: HV.Space.m, bottom: HV.Space.xs, trailing: HV.Space.m))
            } footer: {
                Text("Once saved, the value cannot be shown again. You can replace it.")
            }
        }
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    private func save() async {
        guard canSave else { return }
        saving = true
        error = nil
        nameError = nil
        defer { saving = false }
        do {
            let note = details.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await model.create(name: name, kind: draft.kind, value: draft.serialized, description: note.isEmpty ? nil : note)
            draft = VaultDraft(kind: kind)
            Haptics.success()
            app.toasts.success("Saved. Allow an agent to use it from its page.")
            onSaved()
        } catch {
            Haptics.failure()
            // A taken name is the name field's problem, so it is said there.
            if (error as? HVError)?.status == 409 {
                nameError = keysMessage(for: error)
            } else {
                self.error = keysMessage(for: error)
            }
        }
    }
}

#if DEBUG
#Preview("Add, choose") {
    KeysPreviewHost(routes: VaultPreviewData.routes, embedInNavigation: false) { VaultAddPreview() }
}

#Preview("Add a card") {
    KeysPreviewHost(routes: VaultPreviewData.routes, embedInNavigation: false) { VaultAddPreview(kind: .card) }
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
