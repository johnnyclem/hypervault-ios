import HyperVaultKit
import SwiftUI

/// Connect your own models: OpenAI, Anthropic, xAI, Gemini, Mistral, a runtime
/// of your own (Ollama, LM Studio) or any compatible endpoint. HyperVault's
/// server stores the key encrypted and makes the calls.
struct ChatModelsScreen: View {
    var onChange: (([ChatBackend]) -> Void)?
    var onLocalChange: (([ChatLocalModel]) -> Void)?
    var onDevice: ChatOnDeviceSupport = .system

    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ChatModelsContent(env: env, onChange: onChange, onLocalChange: onLocalChange, onDevice: onDevice)
    }
}

struct ChatModelsContent: View {
    @Environment(AppModel.self) private var app
    private let env: AppEnvironment
    @State private var model: ChatBackendsModel
    @State private var form: FormTarget?
    @State private var pendingDisconnect: ChatBackend?
    @State private var locals: [ChatLocalModel] = []
    @State private var localForm: LocalTarget?
    @State private var pendingLocalRemoval: ChatLocalModel?
    private let onDevice: ChatOnDeviceSupport
    private let onLocalChange: (([ChatLocalModel]) -> Void)?

    private enum FormTarget: Identifiable {
        case connect
        case edit(ChatBackend)

        var id: String {
            switch self {
            case .connect: return "connect"
            case .edit(let backend): return "edit-\(backend.id)"
            }
        }
    }

    private enum LocalTarget: Identifiable {
        case add
        case edit(ChatLocalModel)

        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let model): return model.id
            }
        }
    }

    /// The Models pane of the You tab: its heading is a large one, and the web's line about the pane stands above the list.
    private let embedded: Bool

    init(
        env: AppEnvironment, onChange: (([ChatBackend]) -> Void)?, onLocalChange: (([ChatLocalModel]) -> Void)? = nil,
        onDevice: ChatOnDeviceSupport = .system, embedded: Bool = false
    ) {
        self.env = env
        self.onDevice = onDevice
        self.embedded = embedded
        self.onLocalChange = onLocalChange
        let backends = ChatBackendsModel(client: env.client, cache: env.cache, namespace: env.user.id)
        backends.onChange = onChange
        _model = State(initialValue: backends)
    }

    private var registry: [Capabilities.ProviderSpec] { env.capabilities.providers }
    private var canStoreKeys: Bool { env.features.keyEncryption }
    private var atLimit: Bool { model.backends.count >= env.limits.maxBackends }

    var body: some View {
        content
            .hvScreenBackground()
            .navigationTitle("Models")
            .navigationBarTitleDisplayMode(embedded ? .large : .inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if atLimit {
                            app.toasts.show("Backend limit reached (\(env.limits.maxBackends)).", style: .error)
                        } else {
                            form = .connect
                        }
                    } label: {
                        Image(systemName: "plus").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Connect a model")
                }
            }
            .sheet(item: $form) { target in
                ChatBackendFormSheet(
                    mode: formMode(target), registry: registry, serverCanStoreKeys: canStoreKeys,
                    connectedCount: model.backends.count, maxBackends: env.limits.maxBackends
                ) { draft in
                    try await submit(target, draft)
                }
            }
            .confirmationDialog(
                "Disconnect this model?",
                isPresented: Binding(get: { pendingDisconnect != nil }, set: { if !$0 { pendingDisconnect = nil } }),
                titleVisibility: .visible, presenting: pendingDisconnect
            ) { backend in
                Button("Disconnect \(backend.name)", role: .destructive) { disconnect(backend) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Its key is deleted from HyperVault, and it leaves any room it is in. Your chats stay.")
            }
            .sheet(item: $localForm) { target in
                ChatLocalModelSheet(existing: localModel(for: target)) { saved in saveLocal(saved) }
            }
            .confirmationDialog(
                "Remove this model?",
                isPresented: Binding(get: { pendingLocalRemoval != nil }, set: { if !$0 { pendingLocalRemoval = nil } }),
                titleVisibility: .visible, presenting: pendingLocalRemoval
            ) { local in
                Button("Remove \(local.displayName)", role: .destructive) { removeLocal(local) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Only this iPhone forgets it. The model itself is untouched, and your chats stay.")
            }
            .task {
                locals = onDevice.localModels()
                await model.load()
            }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            HVListSkeleton(rows: 4).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        case .failed(let message):
            HVErrorState(message: message) { Task { await model.load() } }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            list
        }
    }

    private var list: some View {
        List {
            if embedded {
                Text(AccountPane.backends.descriptionLine)
                    .font(.hvCallout)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            if model.isStale {
                HVStaleBanner()
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            if !canStoreKeys {
                noEncryptionBanner
            }
            Section {
                if model.backends.isEmpty {
                    emptyModels
                }
                ForEach(model.backends) { backend in
                    Button { form = .edit(backend) } label: {
                        ChatBackendRow(backend: backend, registry: registry)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) { pendingDisconnect = backend } label: {
                            Label("Disconnect", systemImage: "link.badge.minus")
                        }
                    }
                }
            } header: {
                HVSectionHeader(title: "Your models", detail: model.backends.isEmpty ? nil : "\(model.backends.count) of \(env.limits.maxBackends)")
            } footer: {
                if canStoreKeys {
                    ChatFooter("Your key is stored encrypted on HyperVault's server, which makes the calls to your model. It is shown once, when you connect, and never again.")
                }
            }
            .hvListRow()
            networkSection
            if env.features.onDeviceInference {
                Section {
                    ChatOnDeviceRow(status: onDevice.status())
                } header: {
                    HVSectionHeader(title: "On this iPhone")
                }
                .hvListRow()
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .refreshable { await model.load() }
    }

    /// Models on the person's own network, called by this iPhone directly.
    private var networkSection: some View {
        Section {
            ForEach(locals) { local in
                Button { localForm = .edit(local) } label: {
                    HStack(spacing: HV.Space.s + 2) {
                        HVIconBadge(symbol: "desktopcomputer", tint: ChatAgentTone(provider: "ollama").color)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(local.displayName).font(.hvBody).foregroundStyle(Palette.textPrimary).lineLimit(nil)
                            Text("\(local.model) \u{00B7} \(URL(string: ChatLocalModel.normalizedBase(local.baseURL))?.host ?? local.baseURL)")
                                .font(.hvFootnote)
                                .foregroundStyle(Palette.textSecondary)
                                .lineLimit(nil)
                        }
                        Spacer(minLength: HV.Space.xs)
                        Image(systemName: "chevron.right").font(.hvCaption.weight(.semibold)).foregroundStyle(Palette.textTertiary)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) { pendingLocalRemoval = local } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
            }
            Button { localForm = .add } label: {
                Label("Add a model on your network", systemImage: "plus.circle").frame(minHeight: 44, alignment: .leading)
            }
        } header: {
            HVSectionHeader(title: "On your network")
        } footer: {
            ChatFooter("Ollama or LM Studio at home: this iPhone talks to it directly, so a 192.168 address works. Replies are saved to your vault afterwards. No tools, and no key.")
        }
        .hvListRow()
    }

    private var emptyModels: some View {
        VStack(alignment: .leading, spacing: HV.Space.s) {
            Text("Bring your own model.")
                .font(.hvHeadline)
            Text("Connect OpenAI, Anthropic, xAI, Gemini or Mistral with your key, or point HyperVault at a model you run yourself. Then chat with it here, and put it in a room.")
                .font(.hvCallout)
                .foregroundStyle(Palette.textSecondary)
            Button("Connect a model") { form = .connect }
                .buttonStyle(.hvPrimary)
                .padding(.top, HV.Space.xs)
        }
        .padding(.vertical, HV.Space.xs)
        .listRowSeparator(.hidden)
    }

    private var noEncryptionBanner: some View {
        Section {
            Label {
                Text(ChatBackendDraft.noKeyStorageLine)
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.textPrimary)
            } icon: {
                Image(systemName: "lock.slash").foregroundStyle(Palette.warning)
            }
            .padding(.vertical, HV.Space.xxs)
        }
        .hvListRow()
    }

    // MARK: Actions

    private func formMode(_ target: FormTarget) -> ChatBackendFormSheet.Mode {
        switch target {
        case .connect: return .connect
        case .edit(let backend): return .edit(backend)
        }
    }

    /// Returns the server's sentence; the form shows it as a toast after it closes.
    private func submit(_ target: FormTarget, _ draft: ChatBackendDraft) async throws -> String {
        switch target {
        case .connect:
            return try await model.connect(draft, serverCanStoreKeys: canStoreKeys)
        case .edit(let backend):
            let supports = ChatProviders.spec(for: backend.provider, in: registry)?.supportsEmbeddings ?? false
            return try await model.update(backend, draft: draft, supportsEmbeddings: supports, serverCanStoreKeys: canStoreKeys)
        }
    }

    private func localModel(for target: LocalTarget) -> ChatLocalModel? {
        switch target {
        case .add: return nil
        case .edit(let model): return model
        }
    }

    private func saveLocal(_ saved: ChatLocalModel) {
        if let index = locals.firstIndex(where: { $0.id == saved.id }) { locals[index] = saved } else { locals.append(saved) }
        ChatLocalModelStore.save(locals)
        onLocalChange?(locals)
    }

    private func removeLocal(_ local: ChatLocalModel) {
        locals.removeAll { $0.id == local.id }
        ChatLocalModelStore.save(locals)
        onLocalChange?(locals)
        Haptics.success()
    }

    private func disconnect(_ backend: ChatBackend) {
        Task {
            do {
                try await model.disconnect(backend)
                Haptics.success()
            } catch {
                app.toasts.show(error: error)
            }
        }
    }
}

struct ChatOnDeviceRow: View {
    let status: ChatOnDeviceStatus

    var body: some View {
        HStack(alignment: .top, spacing: HV.Space.s) {
            HVIconBadge(symbol: "iphone", tint: status.isAvailable ? Palette.mint : Palette.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: HV.Space.xs) {
                    Text(ChatOnDeviceModels.subtitle).font(.hvBody)
                    HVTag(text: status.isAvailable ? "Ready" : "Not available", tint: status.isAvailable ? Palette.mint : Palette.textSecondary)
                }
                Text(status.explanation)
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, HV.Space.xxs)
        .accessibilityElement(children: .combine)
    }
}

struct ChatBackendRow: View {
    let backend: ChatBackend
    let registry: [Capabilities.ProviderSpec]
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Two lines are enough at normal sizes; at the large ones nothing is cut to an ellipsis.
    private var lineLimit: Int? { typeSize.isAccessibilitySize ? nil : 2 }

    var body: some View {
        HStack(spacing: HV.Space.s + 2) {
            HVIconBadge(symbol: Self.symbol(for: backend.provider), tint: Self.tint(for: backend.provider))
            VStack(alignment: .leading, spacing: 2) {
                Text(backend.name).font(.hvBody).foregroundStyle(Palette.textPrimary).lineLimit(lineLimit)
                Text(detail).font(.hvFootnote).foregroundStyle(Palette.textSecondary).lineLimit(lineLimit)
                Text(usage).font(.hvCaption).foregroundStyle(Palette.textTertiary).lineLimit(lineLimit)
            }
            Spacer(minLength: HV.Space.xs)
            Image(systemName: "chevron.right").font(.hvCaption.weight(.semibold)).foregroundStyle(Palette.textTertiary)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Edit this model")
    }

    private var detail: String {
        var parts = [ChatProviders.shortName(for: backend.provider, in: registry)]
        if let model = backend.defaultModel, !model.isEmpty { parts.append(model) }
        return parts.joined(separator: " \u{00B7} ")
    }

    private var usage: String {
        var parts = [backend.lastUsedAt.map { "Used \(ChatDates.relative($0))" } ?? "Not used yet"]
        if let hint = backend.keyHint, !hint.isEmpty { parts.append(hint) }
        return parts.joined(separator: " \u{00B7} ")
    }

    static func symbol(for provider: String) -> String {
        switch provider {
        case "openai": return "sparkle"
        case "anthropic", "custom-anthropic": return "asterisk"
        case "xai": return "bolt"
        case "gemini": return "diamond"
        case "mistral": return "wind"
        case "ollama", "lmstudio": return "desktopcomputer"
        default: return "link"
        }
    }

    /// The colour of the provider's family, the same one its members wear in a room and its imported
    /// chats wear in the list.
    static func tint(for provider: String) -> Color {
        ChatAgentTone(provider: provider).color
    }
}

#Preview("Models") {
    PreviewHost(routes: ChatPreviewData.routes) {
        ChatModelsScreen()
    }
}
