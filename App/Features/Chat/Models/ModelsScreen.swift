import HyperVaultKit
import SwiftUI

/// Connect your own models: OpenAI, Anthropic, xAI, Gemini, Mistral, a runtime
/// of your own (Ollama, LM Studio) or any compatible endpoint. HyperVault's
/// server stores the key encrypted and makes the calls.
struct ChatModelsScreen: View {
    var onChange: (([ChatBackend]) -> Void)?

    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ChatModelsContent(env: env, onChange: onChange)
    }
}

struct ChatModelsContent: View {
    @Environment(AppModel.self) private var app
    private let env: AppEnvironment
    @State private var model: ChatBackendsModel
    @State private var form: FormTarget?
    @State private var pendingDisconnect: ChatBackend?
    private let onDevice: ChatOnDeviceSupport

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

    init(env: AppEnvironment, onChange: (([ChatBackend]) -> Void)?, onDevice: ChatOnDeviceSupport = .system) {
        self.env = env
        self.onDevice = onDevice
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
            .navigationBarTitleDisplayMode(.inline)
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
            .task { await model.load() }
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
            if model.isStale {
                HVStaleBanner().listRowSeparator(.hidden).listRowBackground(Color.clear)
            }
            if !canStoreKeys {
                noEncryptionBanner
            }
            if env.features.onDeviceInference {
                Section {
                    ChatOnDeviceRow(status: onDevice.status())
                } header: {
                    HVSectionHeader(title: "On this iPhone")
                }
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
                Text("Your key is stored encrypted on HyperVault's server, which makes the calls to your model. It is shown once, when you connect, and never again.")
                    .font(.hvCaption)
            }
        }
        .scrollContentBackground(.hidden)
        .refreshable { await model.load() }
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

    var body: some View {
        HStack(spacing: HV.Space.s + 2) {
            HVIconBadge(symbol: Self.symbol(for: backend.provider), tint: Self.tint(for: backend.provider))
            VStack(alignment: .leading, spacing: 2) {
                Text(backend.name).font(.hvBody).foregroundStyle(Palette.textPrimary).lineLimit(1)
                Text(detail).font(.hvFootnote).foregroundStyle(Palette.textSecondary).lineLimit(1)
                Text(usage).font(.hvCaption).foregroundStyle(Palette.textTertiary).lineLimit(1)
            }
            Spacer(minLength: HV.Space.xs)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.textTertiary)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Edit this model")
    }

    private var detail: String {
        var parts = [ChatProviders.shortName(for: backend.provider, in: registry)]
        if let model = backend.defaultModel, !model.isEmpty { parts.append(model) }
        if let hint = backend.keyHint, !hint.isEmpty { parts.append(hint) }
        return parts.joined(separator: " \u{00B7} ")
    }

    private var usage: String {
        guard let last = backend.lastUsedAt else { return "Not used yet" }
        return "Used \(ChatDates.relative(last))"
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

    static func tint(for provider: String) -> Color {
        switch provider {
        case "openai": return Palette.mint
        case "anthropic", "custom-anthropic": return Palette.coral
        case "xai": return Palette.textSecondary
        case "gemini": return Palette.blue
        case "mistral": return Palette.amber
        case "ollama", "lmstudio": return Palette.violet
        default: return Palette.sky
        }
    }
}

#Preview("Models") {
    PreviewHost(routes: ChatPreviewData.routes) {
        ChatModelsScreen()
    }
}
