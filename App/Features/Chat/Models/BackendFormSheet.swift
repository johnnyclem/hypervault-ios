import HyperVaultKit
import SwiftUI

/// Connect a model, or change one. The server sends a real test message before
/// it saves (up to a minute), so the form shows that wait and lets you stop it.
struct ChatBackendFormSheet: View {
    enum Mode {
        case connect
        case edit(ChatBackend)
    }

    let mode: Mode
    let registry: [Capabilities.ProviderSpec]
    let serverCanStoreKeys: Bool
    let connectedCount: Int
    let maxBackends: Int
    /// Saves the draft and returns the server's sentence.
    let onSubmit: (ChatBackendDraft) async throws -> String

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @State private var draft: ChatBackendDraft
    @State private var isWorking = false
    @State private var errorText: String?
    @State private var submission: Task<Void, Never>?
    @FocusState private var focus: Field?

    private enum Field: Hashable { case name, key, baseURL, model, embedding }

    init(
        mode: Mode, registry: [Capabilities.ProviderSpec], serverCanStoreKeys: Bool, connectedCount: Int, maxBackends: Int,
        onSubmit: @escaping (ChatBackendDraft) async throws -> String
    ) {
        self.mode = mode
        self.registry = registry
        self.serverCanStoreKeys = serverCanStoreKeys
        self.connectedCount = connectedCount
        self.maxBackends = maxBackends
        self.onSubmit = onSubmit
        switch mode {
        case .connect:
            let first = ChatProviders.choices(from: registry).first { $0.id == "anthropic" }?.id
                ?? ChatProviders.choices(from: registry).first?.id ?? "anthropic"
            _draft = State(initialValue: ChatBackendDraft(provider: first))
        case .edit(let backend):
            _draft = State(initialValue: ChatBackendDraft(editing: backend))
        }
    }

    private var editing: ChatBackend? {
        if case .edit(let backend) = mode { return backend }
        return nil
    }

    private var spec: Capabilities.ProviderSpec {
        ChatProviders.spec(for: draft.provider, in: registry) ?? Capabilities.ProviderSpec(id: draft.provider, label: draft.provider)
    }

    private var problem: String? {
        draft.problem(
            spec: spec, serverCanStoreKeys: serverCanStoreKeys, editing: editing != nil,
            connectedCount: connectedCount, maxBackends: maxBackends
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                providerSection
                detailsSection
                if let note = draft.reachabilityNote(spec: spec) {
                    Section {
                        Label {
                            Text(note).font(.hvFootnote)
                        } icon: {
                            Image(systemName: "network").foregroundStyle(Palette.warning)
                        }
                    }
                }
                advancedSection
                submitSection
            }
            .scrollContentBackground(.hidden)
            .hvScreenBackground()
            .navigationTitle(editing == nil ? "Connect a model" : "Edit \(editing?.name ?? "model")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { close() }
                }
            }
            .interactiveDismissDisabled(isWorking)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onDisappear { draft.apiKey = "" }
    }

    // MARK: Sections

    @ViewBuilder private var providerSection: some View {
        Section {
            if editing == nil {
                Picker("Provider", selection: providerBinding) {
                    ForEach(ChatProviders.choices(from: registry)) { choice in
                        Text(choice.isCustom ? "Custom endpoint" : choice.label).tag(choice.id)
                    }
                }
                if spec.isCustom {
                    Picker("API style", selection: $draft.provider) {
                        Text("OpenAI-compatible").tag("custom")
                        Text("Anthropic-compatible").tag("custom-anthropic")
                    }
                    .pickerStyle(.segmented)
                }
            } else {
                LabeledContent("Provider", value: spec.label)
            }
        } footer: {
            if editing != nil {
                Text("The provider can't change. To use another, connect it as a new model.")
            }
        }
    }

    private var providerBinding: Binding<String> {
        Binding(
            get: { spec.isCustom ? "custom" : draft.provider },
            set: { newValue in
                draft.provider = newValue
                draft.apiKey = ""
                errorText = nil
            }
        )
    }

    @ViewBuilder private var detailsSection: some View {
        Section {
            TextField("Name (optional)", text: $draft.name)
                .focused($focus, equals: .name)
                .submitLabel(.next)
            if spec.acceptsKey {
                keyField
            }
            if spec.asksForBaseURL || !draft.baseURL.isEmpty {
                TextField(spec.defaultBaseUrl.isEmpty ? "Base URL" : spec.defaultBaseUrl, text: $draft.baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .baseURL)
            }
            TextField(spec.defaultModel.isEmpty ? "Model" : "Model (\(spec.defaultModel))", text: $draft.model)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focus, equals: .model)
            if spec.supportsEmbeddings {
                TextField(embeddingPlaceholder, text: $draft.embeddingModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .embedding)
            }
        } footer: {
            VStack(alignment: .leading, spacing: HV.Space.xs) {
                if spec.supportsEmbeddings {
                    Text("An embedding model lets recall find memories by meaning. It must return 1536-number vectors, and it is checked when you connect.")
                }
                if editing != nil, spec.acceptsKey {
                    Text("Leave the key empty to keep the current one. Changes to the key, model or address are tested again before they are saved.")
                }
            }
        }
    }

    @ViewBuilder private var keyField: some View {
        if serverCanStoreKeys {
            SecureField(keyPlaceholder, text: $draft.apiKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focus, equals: .key)
        } else {
            HStack {
                Image(systemName: "lock.slash").foregroundStyle(Palette.warning)
                Text("Keys can't be stored on this server right now.")
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    private var keyPlaceholder: String {
        if let hint = editing?.keyHint, !hint.isEmpty { return "API key (kept: \(hint))" }
        return spec.requiresKey ? "API key" : "API key (optional)"
    }

    private var embeddingPlaceholder: String {
        if let model = spec.defaultEmbeddingModel, !model.isEmpty { return "Embedding model (\(model))" }
        return "Embedding model (optional)"
    }

    private var advancedSection: some View {
        Section {
            Toggle(isOn: $draft.skipTest) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Skip the connection test")
                    Text("Saves it as it is, without sending a test message first.")
                        .font(.hvCaption)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
        }
    }

    private var submitSection: some View {
        Section {
            VStack(alignment: .leading, spacing: HV.Space.s) {
                Button(action: submit) {
                    if isWorking {
                        HStack(spacing: HV.Space.xs) {
                            ProgressView().tint(.white)
                            Text(editing == nil ? "Testing" : "Checking")
                        }
                    } else {
                        Text(editing == nil ? "Connect" : "Save")
                    }
                }
                .buttonStyle(.hvPrimary)
                .disabled(isWorking || problem != nil)

                if isWorking {
                    Text(editing == nil
                         ? "Sending a test message to check the connection. This can take up to a minute."
                         : "Checking the connection again before saving. This can take up to a minute.")
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.textSecondary)
                    Button("Stop", action: stop).buttonStyle(.hvGhost)
                } else if let errorText {
                    Text(errorText)
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let problem {
                    Text(problem)
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            .padding(.vertical, HV.Space.xs)
        }
    }

    // MARK: Actions

    private func submit() {
        guard !isWorking, problem == nil else { return }
        isWorking = true
        errorText = nil
        focus = nil
        let snapshot = draft
        submission = Task {
            defer { isWorking = false }
            do {
                let message = try await onSubmit(snapshot)
                draft.apiKey = ""
                Haptics.success()
                app.toasts.success(message)
                dismiss()
            } catch let error as HVError {
                if case .cancelled = error { return }
                errorText = error.userMessage
            } catch {
                if error is CancellationError { return }
                errorText = error.localizedDescription
            }
        }
    }

    private func stop() {
        submission?.cancel()
    }

    private func close() {
        submission?.cancel()
        draft.apiKey = ""
        dismiss()
    }
}

#Preview("Connect") {
    PreviewHost(routes: ChatPreviewData.routes) {
        ChatBackendFormSheet(
            mode: .connect, registry: ChatProviders.builtIn, serverCanStoreKeys: true, connectedCount: 1, maxBackends: 20
        ) { _ in "Connected." }
    }
}
