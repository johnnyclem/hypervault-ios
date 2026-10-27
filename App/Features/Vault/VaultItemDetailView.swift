import HyperVaultKit
import SwiftUI

/// One saved entry, in the sheet its row opens: what it is, when it was saved and last read, which agent keys may
/// read it, the request an agent makes, and the ways to change it. Never the value: it is write-only once
/// saved. Replacing it asks for the whole entry again.
struct VaultItemDetailView: View {
    /// The name the entry had when its row was opened. The entry is followed by its id from then on: renaming it from
    /// this screen changes its name, and a screen that went on looking for the old name found nothing ("This entry is gone").
    let name: String
    let model: VaultItemsModel
    @State private var id: String?
    @State private var allowed: VaultAllowedKeysModel

    @Environment(AppEnvironment.self) private var env
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var renaming = false
    @State private var replacing = false
    @State private var confirmDelete = false
    @State private var connecting = false

    init(name: String, model: VaultItemsModel) {
        self.name = name
        self.model = model
        _id = State(initialValue: model.secret(named: name)?.id)
        _allowed = State(initialValue: model.makeAllowedKeys())
    }

    private var current: VaultSecret? {
        if let id, let found = model.secret(id: id) { return found }
        return model.secret(named: name)
    }

    var body: some View {
        Group {
            if let secret = current {
                details(secret)
            } else {
                HVEmptyState(symbol: "lock.rectangle.stack", title: "This entry is gone", actionTitle: "Back") { dismiss() }
                    .frame(maxHeight: .infinity)
            }
        }
        .hvScreenBackground()
        .navigationTitle(current?.name ?? name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { VaultCloseButton { dismiss() } }
        }
        // The entry left the list while this page was up (deleted here or somewhere else): there is nothing to show.
        .onChange(of: current == nil) { _, isGone in
            if isGone { dismiss() }
        }
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
                LabeledContent(VaultCopy.createdLabel, value: secret.createdAt?.keysDay ?? "Unknown")
                LabeledContent("Last used", value: VaultCopy.sheetLastUsedLine(secret.lastAccessedAt))
            } footer: {
                Label(VaultCopy.valueNeverShownLine, systemImage: "lock.fill")
                    .font(.hvFootnote)
            }
            .hvListRow()

            VaultAllowedKeysSection(allowed: allowed, secret: secret, onConnect: { connecting = true })

            Section {
                VStack(alignment: .leading, spacing: HV.Space.xs) {
                    Text(readsLine(secret)).font(.hvFootnote).foregroundStyle(Palette.textSecondary)
                    HVCodePanel(fetchCommand(secret))
                }
                VaultCopyButton(text: fetchCommand(secret))
            } header: {
                HVSectionHeader(title: VaultCopy.howAgentReadsHeading)
            }
            .hvListRow()

            Section {
                Button { renaming = true } label: { Label(VaultCopy.renameLabel, systemImage: "pencil") }
                Button { Task { await startReplacing() } } label: { Label("Replace the value", systemImage: "arrow.triangle.2.circlepath") }
            }
            .hvListRow()

            Section {
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: HVSymbol.delete).foregroundStyle(Palette.danger) }
            } footer: {
                Text("Deleting it cuts off every agent at once.")
            }
            .hvListRow()
        }
        .scrollContentBackground(.hidden)
        .task(id: secret.id) { await allowed.load(name: secret.name) }
        .onChange(of: allowed.entryIsGone) { _, isGone in
            if isGone { model.forget(secret) }
        }
        .sheet(isPresented: $renaming) { VaultRenameSheet(secret: secret, model: model) }
        .sheet(isPresented: $replacing) { VaultReplaceSheet(secret: secret, model: model) }
        .sheet(isPresented: $connecting, onDismiss: { Task { await allowed.load(name: secret.name, quietly: true) } }) { ConnectAgentSheet() }
        .confirmationDialog("Delete \(secret.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { delete(secret) }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text(VaultCopy.deleteConfirmationMessage)
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
                // The name is what tells two entries apart, so it wraps as far as it needs.
                Text(secret.name).font(.hvTitle3)
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
        // The card's mask reads as "ending in 4242", not as four bullets.
        .accessibilityLabel("\(secret.name), \(secret.spokenSubtitle)")
    }

    // MARK: How an agent reads it

    /// The command to copy, with the public origin the agent has to call (`capabilities.app_url`) and not the host this
    /// phone happens to be talking to.
    private func fetchCommand(_ secret: VaultSecret) -> String {
        VaultItems.fetchCommand(appURL: env.capabilities.appUrl, fallbackOrigin: ServerOrigin.string(of: env.server.baseURL), name: secret.name)
    }

    private func readsLine(_ secret: VaultSecret) -> String {
        let reads: String
        if let kind = secret.kind.vaultItemKind {
            reads = VaultCopy.jsonValueLine(fields: VaultItems.valueFieldsLine(kind))
        } else {
            reads = VaultCopy.exactValueLine
        }
        return VaultCopy.allowedKeyGetsLine + " " + reads
    }

    // MARK: Changing it

    private func startReplacing() async {
        if await KeysBiometricGate.confirm(reason: "Replace a saved value") { replacing = true }
    }

    /// Deletes the entry. When it goes, off the list or already gone elsewhere, `current` turns nil and the page closes.
    private func delete(_ secret: VaultSecret) {
        Task {
            switch await model.delete(secret) {
            case .deleted, .entryGone:
                Haptics.success()
                app.toasts.success("Deleted.")
            case .failure(let failure):
                app.toasts.show(failure.message, style: .error)
            }
        }
    }
}

/// The fetch command's Copy button. It says "Copied" for a moment, and tells VoiceOver which copy it is: the page has no
/// other, but a screen reader hears the button without the command beside it.
struct VaultCopyButton: View {
    let text: String

    @State private var copied = false

    var body: some View {
        Button {
            KeysPasteboard.copy(text, secret: false)
            Haptics.success()
            copied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                copied = false
            }
        } label: {
            Label(copied ? VaultScreenCopy.copiedLabel : VaultScreenCopy.copyLabel, systemImage: copied ? HVSymbol.copied : HVSymbol.copy)
        }
        // The ghost style pads its text in from the edge for a 44pt target; in a column of text that would set the
        // button's words in from the text above it.
        .buttonStyle(.hvGhost)
        .padding(.leading, -HV.Space.s)
        .accessibilityLabel(copied ? VaultScreenCopy.copiedLabel : VaultScreenCopy.copyFetchCommandLabel)
    }
}

#if DEBUG
#Preview("Vault entry") {
    PreviewHost(routes: VaultPreviewData.routes) { VaultEntryPreview(name: "github.com") }
}

#Preview("Vault card") {
    PreviewHost(routes: VaultPreviewData.routes) { VaultEntryPreview(name: "visa-4242") }
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
