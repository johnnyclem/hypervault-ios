import HyperVaultKit
import SwiftUI

/// One saved entry, opened from its row: what it is, when it was saved and last read, which agent keys may
/// read it, the request an agent makes, and the ways to change it. Never the value: it is write-only once
/// saved. Replacing it asks for the whole entry again.
struct VaultItemDetailView: View {
    let name: String
    let model: VaultItemsModel

    @Environment(AppEnvironment.self) private var env
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var grants = VaultGrantsPhase.loading
    /// Why the last switch change was refused, in the server's words. A failed read has its own sentence.
    @State private var grantsError: String?
    @State private var pending: Set<String> = []
    @State private var editing = false
    @State private var replacing = false
    @State private var confirmDelete = false
    @State private var connecting = false

    var body: some View {
        Group {
            if let secret = model.secret(named: name) {
                details(secret)
            } else {
                HVEmptyState(symbol: "lock.rectangle.stack", title: "This entry is gone", actionTitle: "Back") { dismiss() }
                    .frame(maxHeight: .infinity)
            }
        }
        .hvScreenBackground()
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func details(_ secret: VaultSecret) -> some View {
        List {
            Section {
                header(secret)
                    .listRowInsets(EdgeInsets(top: HV.Space.s, leading: HV.Space.m, bottom: HV.Space.s, trailing: HV.Space.m))
            }
            .hvListRow()

            Section {
                LabeledContent("Type", value: secret.kind.label)
                LabeledContent("Saved", value: secret.createdAt?.keysDay ?? "Unknown")
                LabeledContent("Last used", value: secret.lastAccessedAt.map { AccountWords.agoLine(seconds: Date().timeIntervalSince($0)) } ?? "Never")
                if let note = secret.description, !note.isEmpty { LabeledContent("Note", value: note) }
            } footer: {
                Label("The value is encrypted and never shown again.", systemImage: "lock.fill")
                    .font(.hvFootnote)
            }
            .hvListRow()

            allowedKeys(secret)

            Section {
                VStack(alignment: .leading, spacing: HV.Space.xs) {
                    Text(readsLine(secret)).font(.hvFootnote).foregroundStyle(Palette.textSecondary)
                    Text(fetchCommand(secret))
                        .font(.hvMono)
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(HV.Space.s)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: HV.Radius.s, style: .continuous))
                }
                KeysCopyButton(title: "Copy", text: fetchCommand(secret))
            } header: {
                HVSectionHeader(title: "How an agent reads it")
            }
            .hvListRow()

            Section {
                Button { editing = true } label: { Label("Rename or add a note", systemImage: "pencil") }
                Button { Task { await startReplacing() } } label: { Label("Replace the value", systemImage: "arrow.triangle.2.circlepath") }
            }
            .hvListRow()

            Section {
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash").foregroundStyle(Palette.danger) }
            } footer: {
                Text("Deleting it cuts off every agent at once.")
            }
            .hvListRow()
        }
        .scrollContentBackground(.hidden)
        .task(id: secret.id) { await loadGrants(secret) }
        .sheet(isPresented: $editing) { VaultEditSheet(secret: secret, model: model) }
        .sheet(isPresented: $replacing) { VaultReplaceSheet(secret: secret, model: model) }
        .sheet(isPresented: $connecting, onDismiss: { Task { await model.load() } }) { ConnectAgentSheet() }
        .confirmationDialog("Delete \(secret.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { delete(secret) }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("Every agent allowed to read it loses it at once. This cannot be undone.")
        }
    }

    private func header(_ secret: VaultSecret) -> some View {
        // Beside the words while they have the room. At an accessibility size the tile would leave them a narrow column
        // and a name or an address would be broken in two with a hyphen ("github.-/com"), so the tile goes above them and
        // the second line (an address, a card's last digits) is kept on one line, a little smaller if it must be.
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: HV.Space.s))
            : AnyLayout(HStackLayout(spacing: HV.Space.m))
        return layout {
            VaultTile(secret: secret, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(secret.name).font(.hvTitle3).lineLimit(stacked ? nil : 2)
                Text(secret.subtitle)
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(stacked ? 1 : nil)
                    .minimumScaleFactor(stacked ? 0.6 : 1)
                    .truncationMode(.middle)
            }
            if !stacked { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: Which agents may read it

    @ViewBuilder
    private func allowedKeys(_ secret: VaultSecret) -> some View {
        Section {
            if model.keys.isEmpty {
                VStack(alignment: .leading, spacing: HV.Space.s) {
                    Text("No agent keys yet. Connect an agent, then allow it here.")
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.textSecondary)
                    Button("Connect an agent") { connecting = true }.buttonStyle(.hvGhost).padding(.leading, -HV.Space.s)
                }
            } else if grants.hasFailed {
                // No switches at all: a row of them would read as "none allowed" when nobody knows.
                VStack(alignment: .leading, spacing: HV.Space.xs) {
                    Label(VaultGrantsCopy.loadFailed, systemImage: "exclamationmark.circle")
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.textSecondary)
                    Button("Try again") { Task { await loadGrants(secret) } }.buttonStyle(.hvGhost).padding(.leading, -HV.Space.s)
                }
            } else {
                ForEach(model.keys) { key in
                    Toggle(isOn: Binding(
                        get: { grants.granted.contains(key.id) },
                        set: { toggle(key, on: $0, secret: secret) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(key.displayName ?? "Untitled key").font(.hvBody)
                            Text(key.prefixLabel).font(.hvFootnote).foregroundStyle(Palette.textSecondary)
                        }
                    }
                    .disabled(!grants.isLoaded || pending.contains(key.id))
                }
                if let grantsError { KeysInlineMessage(text: grantsError) }
            }
        } header: {
            HVSectionHeader(title: "Allowed keys")
        } footer: {
            Text("Only the agent keys switched on here can read it.")
        }
        .hvListRow()
    }

    private func loadGrants(_ secret: VaultSecret) async {
        grantsError = nil
        grants = .loading
        grants = await model.grantsPhase(for: secret)
    }

    /// The switch moves at once and goes back if the server says no. Only that switch goes back: another
    /// one may have been turned and accepted while this one waited, and a copy taken before would undo it.
    private func toggle(_ key: AgentKey, on: Bool, secret: VaultSecret) {
        guard grants.isLoaded else { return }
        grants = grants.setting(key.id, to: on)
        pending.insert(key.id)
        grantsError = nil
        Task {
            defer { pending.remove(key.id) }
            do {
                try await model.setGranted(on, keyID: key.id, for: secret)
                Haptics.select()
            } catch {
                grants = grants.setting(key.id, to: !on)
                grantsError = keysMessage(for: error)
                Haptics.failure()
            }
        }
    }

    // MARK: How an agent reads it

    private func fetchCommand(_ secret: VaultSecret) -> String {
        "curl -s \"\(PairingCode.origin(of: env.server.baseURL))/api/secrets/\(secret.name)\" \\\n  -H \"X-HyperVault-Key: hv_YOUR_KEY\""
    }

    private func readsLine(_ secret: VaultSecret) -> String {
        var line = "An allowed key gets back { name, kind, value }. "
        if let kind = secret.kind.vaultItemKind {
            line += "The value is JSON with \(VaultItems.valueFieldsLine(kind)); empty fields are left out."
        } else {
            line += "The value is exactly what you saved."
        }
        return line
    }

    // MARK: Changing it

    private func startReplacing() async {
        if await KeysBiometricGate.confirm(reason: "Replace a saved value") { replacing = true }
    }

    private func delete(_ secret: VaultSecret) {
        Task {
            do {
                try await model.delete(secret)
                Haptics.success()
                app.toasts.success("Deleted.")
                dismiss()
            } catch {
                app.toasts.show(error: error)
            }
        }
    }
}

// MARK: Rename and note

private struct VaultEditSheet: View {
    let secret: VaultSecret
    let model: VaultItemsModel

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app

    @State private var newName: String
    @State private var note: String
    @State private var saving = false
    @State private var error: String?

    init(secret: VaultSecret, model: VaultItemsModel) {
        self.secret = secret
        self.model = model
        _newName = State(initialValue: secret.name)
        _note = State(initialValue: secret.description ?? "")
    }

    private var trimmedName: String { newName.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var changed: Bool { trimmedName != secret.name || note != (secret.description ?? "") }
    private var canSave: Bool { changed && VaultItems.isValidName(trimmedName) && !saving }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HV.Space.l) {
                    VStack(alignment: .leading, spacing: HV.Space.xs) {
                        HVLabeledField(
                            title: "Name",
                            footnote: "Agents ask for it by name, so renaming it changes what they ask for. \(VaultItems.nameHint)"
                        ) {
                            TextField("github.com", text: $newName)
                                .font(.system(.body, design: .monospaced))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        if !trimmedName.isEmpty, !VaultItems.isValidName(trimmedName) {
                            KeysInlineMessage(text: "Use letters, digits, dots, dashes and underscores. No spaces.")
                        }
                    }
                    HVLabeledField(title: "Note (optional)") {
                        TextField("What is it for?", text: $note)
                    }
                    if let error { KeysInlineMessage(text: error) }
                }
                .padding(HV.Space.m)
                .hvReadableWidth()
            }
            .scrollDismissesKeyboard(.interactively)
            .hvScreenBackground()
            .hvSensitive()
            .navigationTitle("Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(!canSave)
                }
            }
        }
    }

    private func save() async {
        saving = true
        error = nil
        defer { saving = false }
        do {
            _ = try await model.update(
                secret,
                newName: trimmedName == secret.name ? nil : trimmedName,
                description: note == (secret.description ?? "") ? nil : note
            )
            Haptics.success()
            app.toasts.success("Saved.")
            dismiss()
        } catch {
            Haptics.failure()
            self.error = keysMessage(for: error)
        }
    }
}

// MARK: Replace the value

/// The old value was never kept, so a new one means typing the whole entry again.
private struct VaultReplaceSheet: View {
    let secret: VaultSecret
    let model: VaultItemsModel

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app

    @State private var draft: VaultDraft
    @State private var saving = false
    @State private var error: String?

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
                    Text("The saved value is never shown, so type the whole entry again. The agents you allowed keep their access.")
                        .font(.hvCallout)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
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
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Replace") { Task { await save() } }.disabled(!canSave)
                }
            }
        }
    }

    private func save() async {
        saving = true
        error = nil
        defer { saving = false }
        do {
            _ = try await model.update(secret, value: draft.serialized)
            draft = VaultDraft(kind: secret.kind)
            Haptics.success()
            app.toasts.success("Replaced.")
            dismiss()
        } catch {
            Haptics.failure()
            self.error = keysMessage(for: error)
        }
    }
}

#if DEBUG
#Preview("Vault entry") {
    PreviewHost(routes: VaultPreviewData.routes) { VaultEntryPreview(name: "github.com") }
}

#Preview("Vault card") {
    PreviewHost(routes: VaultPreviewData.routes) { VaultEntryPreview(name: "visa-4242") }
}

/// A preview and snapshot helper: the rename sheet, or the replace sheet, over a loaded model.
struct VaultChangePreview: View {
    let name: String
    var replacing = false

    @Environment(AppEnvironment.self) private var env
    @State private var model: VaultItemsModel?

    var body: some View {
        Group {
            if let model, let secret = model.secret(named: name) {
                if replacing { VaultReplaceSheet(secret: secret, model: model) } else { VaultEditSheet(secret: secret, model: model) }
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

struct VaultEntryPreview: View {
    let name: String
    @Environment(AppEnvironment.self) private var env
    @State private var model: VaultItemsModel?

    var body: some View {
        Group {
            if let model { VaultItemDetailView(name: name, model: model) } else { HVLoadingState() }
        }
        .task {
            let loaded = VaultItemsModel(client: env.client, rest: env.keysRest, userID: env.user.id)
            await loaded.load()
            model = loaded
        }
    }
}
#endif
