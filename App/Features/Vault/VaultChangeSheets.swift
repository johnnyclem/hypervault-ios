import HyperVaultKit
import SwiftUI

// MARK: Rename

/// Renames an entry. The name is what an agent asks for, so the sheet says what a rename costs in the web's words
/// (`RENAME_WARNING`) and keeps the rule where the new name is typed (`RENAME_HINT`). Nothing else about an entry is
/// edited here: the web never shows a description and never sends one.
struct VaultRenameSheet: View {
    let secret: VaultSecret
    let model: VaultItemsModel

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app

    @State private var newName: String
    @State private var saving = false
    @State private var error: String?
    /// A 409: the new name is taken (or the entry is an MCP server's sign-in). Said under the field.
    @State private var nameRefusal: VaultNameRefusal?
    @State private var confirmingDiscard = false
    @FocusState private var nameFocused: Bool
    @AccessibilityFocusState private var nameSpoken: Bool

    init(secret: VaultSecret, model: VaultItemsModel) {
        self.secret = secret
        self.model = model
        _newName = State(initialValue: secret.name)
    }

    private var trimmedName: String { VaultItems.trimmedName(newName) }
    private var changed: Bool { trimmedName != secret.name }
    private var canSave: Bool { changed && VaultItems.isAddressableName(trimmedName) && !saving }
    /// The server's line about the name, for as long as the field holds the name it was said of.
    private var nameError: String? { nameRefusal?.line(whenNamed: trimmedName) }

    /// The rule under the field, and whether the name breaks it.
    private var hint: (text: String, isInvalid: Bool) {
        let name = trimmedName
        if !name.isEmpty, !VaultItems.isValidName(name) { return (VaultCopy.renameHint, true) }
        if !name.isEmpty, !VaultItems.isAddressableName(name) { return (VaultScreenCopy.dotsOnlyName, true) }
        return (VaultCopy.renameHint, false)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HV.Space.l) {
                    VStack(alignment: .leading, spacing: HV.Space.xs) {
                        // A taken name outlines the field, but the rule it satisfies stays plain: the server says why.
                        HVLabeledField(
                            title: VaultCopy.renameFieldLabel(secret.name), footnote: hint.text,
                            isFocused: nameFocused, isInvalid: hint.isInvalid || nameError != nil,
                            isFootnoteInvalid: hint.isInvalid
                        ) {
                            TextField(
                                "github.com",
                                // Only a change is an edit: the field writes its text back when it takes the cursor, and a taken
                                // name's line must survive the cursor being moved there.
                                text: Binding(
                                    get: { newName },
                                    set: { text in
                                        guard text != newName else { return }
                                        newName = text
                                        nameRefusal = nil
                                    }
                                ),
                                prompt: Text.hvPrompt("github.com")
                            )
                            .font(.system(.body, design: .monospaced))
                            .keyboardType(.asciiCapable)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($nameFocused)
                            .accessibilityFocused($nameSpoken)
                            .accessibilityIdentifier("vault.edit.name")
                        }
                        Text(VaultCopy.renameWarning)
                            .font(.hvFootnote)
                            .foregroundStyle(Palette.textSecondary)
                        if let nameError { KeysInlineMessage(text: nameError) }
                    }
                    if let error { KeysInlineMessage(text: error) }
                }
                .padding(HV.Space.m)
                .hvReadableWidth()
            }
            .scrollDismissesKeyboard(.interactively)
            .hvScreenBackground()
            .hvSensitive()
            .navigationTitle(VaultCopy.renameLabel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    VaultCloseButton { if changed { confirmingDiscard = true } else { dismiss() } }
                        .disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? VaultScreenCopy.savingLabel : VaultScreenCopy.saveLabel) { Task { await save() } }
                        .disabled(!canSave)
                }
            }
        }
        .vaultDiscardGuard(isDirty: changed, isSaving: saving, isPresented: $confirmingDiscard) { dismiss() }
    }

    private func save() async {
        guard canSave else { return }
        saving = true
        error = nil
        nameRefusal = nil
        defer { saving = false }
        // The name tried is the one a 409 is about, whatever is typed while the request is out.
        let name = trimmedName
        switch await model.change(secret, newName: name) {
        case .updated:
            Haptics.success()
            app.toasts.success("Saved.")
            dismiss()
        case .entryGone:
            // It was deleted somewhere else: the list has dropped it, and its page closes with this sheet.
            dismiss()
        case .failure(let failure):
            Haptics.failure()
            if failure.isConflict {
                // A taken name is the name field's problem, so it is said there, and the cursor and VoiceOver go there.
                nameRefusal = VaultNameRefusal(name: name, message: failure.message)
                nameFocused = true
                nameSpoken = true
            } else {
                error = failure.message
            }
        }
    }
}

// MARK: Replace the value

/// The old value was never kept, so a new one means typing the whole entry again.
struct VaultReplaceSheet: View {
    let secret: VaultSecret
    let model: VaultItemsModel

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app

    @State private var draft: VaultDraft
    @State private var saving = false
    @State private var error: String?
    @State private var confirmingDiscard = false

    init(secret: VaultSecret, model: VaultItemsModel) {
        self.secret = secret
        self.model = model
        _draft = State(initialValue: VaultDraft(kind: secret.kind))
    }

    private var canSave: Bool { draft.problem == nil && !saving }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HV.Space.l) {
                    // The title above names it too, but it is one line between two buttons and cuts a long name short.
                    VStack(alignment: .leading, spacing: HV.Space.xs) {
                        Text("Replace the value of \(secret.name)")
                            .font(.hvHeadline)
                            .foregroundStyle(Palette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("The saved value is never shown, so type the whole entry again. The agents you allowed keep their access.")
                            .font(.hvCallout)
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // The kind stays as it was: only a key can pick among the key kinds, and that is its own choice.
                    VaultFieldsForm(draft: $draft, showsKindPicker: false)
                    VStack(alignment: .leading, spacing: HV.Space.xs) {
                        if draft.isTouched, let problem = draft.problem { KeysInlineMessage(text: problem, isError: false) }
                        if let error { KeysInlineMessage(text: error) }
                    }
                }
                .padding(HV.Space.m)
                .hvReadableWidth()
            }
            .scrollDismissesKeyboard(.interactively)
            .hvScreenBackground()
            .hvSensitive()
            .navigationTitle("Replace \(secret.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    VaultCloseButton { if draft.isDirty { confirmingDiscard = true } else { dismiss() } }
                        .disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? VaultScreenCopy.replacingLabel : VaultScreenCopy.replaceLabel) { Task { await save() } }
                        .disabled(!canSave)
                }
            }
        }
        .vaultDiscardGuard(isDirty: draft.isDirty, isSaving: saving, isPresented: $confirmingDiscard) { dismiss() }
    }

    private func save() async {
        guard canSave else { return }
        saving = true
        error = nil
        defer { saving = false }
        switch await model.change(secret, value: draft.serialized) {
        case .updated:
            draft = VaultDraft(kind: secret.kind)
            Haptics.success()
            app.toasts.success("Replaced.")
            dismiss()
        case .entryGone:
            draft = VaultDraft(kind: secret.kind)
            dismiss()
        case .failure(let failure):
            Haptics.failure()
            error = failure.message
        }
    }
}

#if DEBUG
/// A preview and snapshot helper: the rename sheet, or the replace sheet, over a loaded model.
struct VaultChangePreview: View {
    let name: String
    var replacing = false

    @Environment(AppEnvironment.self) private var env
    @State private var model: VaultItemsModel?

    var body: some View {
        Group {
            if let model, let secret = model.secret(named: name) {
                if replacing { VaultReplaceSheet(secret: secret, model: model) } else { VaultRenameSheet(secret: secret, model: model) }
            } else {
                HVLoadingState()
            }
        }
        .task {
            let loaded = VaultItemsModel(client: env.client, rest: env.keysRest, userID: env.user.id)
            await loaded.load()
            model = loaded
        }
    }
}
#endif
