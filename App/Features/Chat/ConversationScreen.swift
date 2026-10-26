import HyperVaultKit
import SwiftUI

/// One conversation: the thread, and a composer to continue it. `nil` starts a
/// new one, which exists on the server after its first turn.
struct ConversationScreen: View {
    let conversationID: String?
    var onDevice: ChatOnDeviceSupport = .system

    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ChatConversationContent(conversationID: conversationID, env: env, onDevice: onDevice)
            .id(conversationID ?? "new")
    }
}

struct ChatConversationContent: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var model: ChatConversationModel
    @State private var speech = ChatSpeechController()
    @State private var showOptions = false
    @State private var showVisibility = false
    @State private var confirmDelete = false
    @FocusState private var composerFocused: Bool

    private static let bottomID = "bottom"

    init(conversationID: String?, env: AppEnvironment, onDevice: ChatOnDeviceSupport) {
        _model = State(
            initialValue: ChatConversationModel(
                conversationID: conversationID,
                client: env.client,
                cache: env.cache,
                namespace: env.user.id,
                limits: env.limits,
                features: env.features,
                onDevice: onDevice,
                outbox: ChatOutboxes.outbox(for: env)
            )
        )
    }

    #if DEBUG
    /// A prebuilt model, for previews and snapshots.
    init(model: ChatConversationModel) {
        _model = State(initialValue: model)
    }
    #endif

    var body: some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if case .failed = model.phase {
                    EmptyView()
                } else {
                    ChatComposerView(model: model, focus: $composerFocused) { showOptions = true }
                }
            }
            .hvScreenBackground()
            .navigationTitle(model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .sheet(isPresented: $showOptions) { ChatOptionsSheet(model: model) }
            .sheet(isPresented: $showVisibility) { ChatVisibilitySheet(model: model) }
            .confirmationDialog("Delete this chat?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete chat", role: .destructive) { delete() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The chat and the memory made from it are deleted. This can't be undone.")
            }
            .task {
                await model.load()
                await model.syncOutbox()
            }
            .onChange(of: scenePhase) {
                if scenePhase == .active { Task { await model.syncOutbox() } }
            }
            .onDisappear { speech.stop() }
    }

    // MARK: Thread

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            loadingThread
        case .failed(let message):
            HVErrorState(message: message) { Task { await model.retryLoad() } }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            thread
        }
    }

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: HV.Space.m) {
                    if model.isStale { HVStaleBanner() }
                    if model.rows.isEmpty { emptyThread }
                    ForEach(items) { item in
                        itemView(item)
                    }
                    if let started = model.workStarted, model.isWorking, !model.isStreaming, !model.isOnDevice {
                        ChatThinkingBubble(startedAt: started, usesRecall: model.useRecall) { model.stop() }
                            .transition(.opacity)
                    }
                    if let toolNotice = model.toolNotice {
                        Label(toolNotice, systemImage: "wrench.and.screwdriver")
                            .font(.hvFootnote)
                            .foregroundStyle(Palette.warning)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(.horizontal, HV.Space.m)
                .padding(.vertical, HV.Space.s)
                .hvReadableWidth()
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.rows.count) { scrollToBottom(proxy) }
            .onChange(of: model.isWorking) { scrollToBottom(proxy) }
            .onChange(of: composerFocused) { if composerFocused { scrollToBottom(proxy) } }
        }
    }

    private var items: [ChatThreadItem] { ChatThreadItem.items(from: model.rows) }

    @ViewBuilder private func itemView(_ item: ChatThreadItem) -> some View {
        switch item {
        case .message(let row):
            switch row.kind {
            case .user:
                ChatUserBubble(row: row, onRetry: { model.retry(row) }, onEdit: { model.edit(row) })
            case .assistant:
                ChatAssistantMessageView(row: row, isLast: row.id == model.rows.last?.id, model: model, speech: speech)
            case .tool:
                EmptyView()
            }
        case .tools(let rows):
            ChatToolGroupView(rows: rows)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.25)) {
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        }
    }

    private var emptyThread: some View {
        HVEmptyState(
            symbol: "bubble.left.and.bubble.right",
            title: "Ask anything.",
            message: "Your memories come along. The model is only the engine, so you can switch it in the middle of a chat."
        )
        .padding(.top, HV.Space.xxl)
    }

    private var loadingThread: some View {
        VStack(alignment: .leading, spacing: HV.Space.m) {
            HStack { Spacer(); HVSkeleton(height: 40, width: 180) }
            HVSkeleton(height: 14)
            HVSkeleton(height: 14)
            HVSkeleton(height: 14, width: 200)
            HStack { Spacer(); HVSkeleton(height: 40, width: 120) }
            HVSkeleton(height: 14)
            HVSkeleton(height: 14, width: 240)
            Spacer()
        }
        .padding(HV.Space.m)
        .hvReadableWidth()
        .accessibilityLabel("Loading the conversation")
    }

    // MARK: Menu

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if let url = model.shareURL {
                    ShareLink(item: url) { Label("Share link", systemImage: "square.and.arrow.up") }
                }
                if model.conversation != nil {
                    Button { showVisibility = true } label: {
                        Label("Who can read this", systemImage: "lock")
                    }
                }
                Button { showOptions = true } label: {
                    Label("Model and options", systemImage: "slider.horizontal.3")
                }
                if model.conversation != nil {
                    Divider()
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Delete chat", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Chat menu")
        }
    }

    private func delete() {
        Task {
            do {
                try await model.delete()
                Haptics.success()
                dismiss()
            } catch {
                app.toasts.show(error: error)
            }
        }
    }
}

#Preview("Conversation") {
    PreviewHost(routes: ChatPreviewData.routes) {
        ConversationScreen(conversationID: "c1", onDevice: .fixed(.unavailable("Preview")))
    }
}

#Preview("New conversation") {
    PreviewHost(routes: ChatPreviewData.routes) {
        ConversationScreen(conversationID: nil, onDevice: .fixed(.unavailable("Preview")))
    }
}
