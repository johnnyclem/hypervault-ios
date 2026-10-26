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

    @State private var grants: Set<String>?
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

            Section {
                LabeledContent("Type", value: secret.kind.label)
                LabeledContent("Saved", value: secret.createdAt?.keysDay ?? "Unknown")
                LabeledContent("Last used", value: secret.lastAccessedAt.map { AccountWords.agoLine(seconds: Date().timeIntervalSince($0)) } ?? "Never")
                if let note = secret.description, !note.isEmpty { LabeledContent("Note", value: note) }
            } footer: {
                Label("The value is encrypted and never shown again.", systemImage: "lock.fill")
                    .font(.hvFootnote)
            }

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

            Section {
                Button { editing = true } label: { Label("Rename or add a note", systemImage: "pencil") }
                Button { Task { await startReplacing() } } label: { Label("Replace the value", systemImage: "arrow.triangle.2.circlepath") }
            }

            Section {
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
            } footer: {
                Text("Deleting it cuts off every agent at once.")
            }
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
        HStack(spacing: HV.Space.m) {
            VaultTile(secret: secret, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(secret.name).font(.hvTitle3).lineLimit(2)
                Text(secret.subtitle).font(.hvFootnote).foregroundStyle(Palette.textSecondary)
            }
            Spacer(minLength: 0)
        }
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
                    Button("Connect an agent") { connecting = true }.buttonStyle(.hvGhost)
                }
            } else {
                ForEach(model.keys) { key in
                    Toggle(isOn: Binding(
                        get: { grants?.contains(key.id) ?? false },
                        set: { toggle(key, on: $0, secret: secret) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(key.displayName ?? "Untitled key").font(.hvBody)
                            Text(key.prefixLabel).font(.hvFootnote).foregroundStyle(Palette.textSecondary)
                        }
                    }
                    .disabled(grants == nil || pending.contains(key.id))
                }
                if let grantsError { KeysInlineMessage(text: grantsError) }
            }
        } header: {
            HVSectionHeader(title: "Allowed keys")
        } footer: {
            Text("Only the agent keys switched on here can read it.")
        }
    }

    private func loadGrants(_ secret: VaultSecret) async {
        grantsError = nil
        do {
            grants = try await model.grantedKeyIDs(for: secret)
        } catch {
            grants = []
            grantsError = keysMessage(for: error)
        }
    }

    /// The switch moves at once and goes back if the server says no.
    private func toggle(_ key: AgentKey, on: Bool, secret: VaultSecret) {
        let before = grants ?? []
        var next = before
        if on { next.insert(key.id) } else { next.remove(key.id) }
        grants = next
        pending.insert(key.id)
        grantsError = nil
        Task {
            defer { pending.remove(key.id) }
            do {
                try await model.setGranted(on, keyID: key.id, for: secret)
                Haptics.select()
            } catch {
                grants = before
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
            Form {
                Section {
                    TextField("Name", text: $newName)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Note (optional)", text: $note)
                } footer: {
                    VStack(alignment: .leading, spacing: HV.Space.xxs) {
                        Text("Agents ask for it by name, so renaming it changes what they ask for. \(VaultItems.nameHint)")
                        if !trimmedName.isEmpty, !VaultItems.isValidName(trimmedName) {
                            KeysInlineMessage(text: "Use letters, digits, dots, dashes and underscores. No spaces.")
                        }
                        if let error { KeysInlineMessage(text: error) }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .hvScreenBackground()
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
            Form {
                Section {
                    Text("The saved value is never shown, so type the whole entry again. The agents you allowed keep their access.")
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.textSecondary)
                }
                // The kind stays as it was: only a key can pick among the key kinds, and that is its own choice.
                VaultFieldsForm(draft: $draft, showsKindPicker: false)
                Section {
                    if draft.isTouched, let problem = draft.problem { KeysInlineMessage(text: problem, isError: false) }
                    if let error { KeysInlineMessage(text: error) }
                }
            }
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .hvScreenBackground()
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
    KeysPreviewHost(routes: VaultPreviewData.routes) { VaultEntryPreview(name: "github.com") }
}

#Preview("Vault card") {
    KeysPreviewHost(routes: VaultPreviewData.routes) { VaultEntryPreview(name: "visa-4242") }
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
