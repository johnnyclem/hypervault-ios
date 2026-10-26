import HyperVaultKit
import SwiftUI

/// The Chats half of the chat tab.
struct ChatConversationListView: View {
    @Environment(AppModel.self) private var app
    @State private var model: ChatListModel
    @State private var pendingDelete: ChatConversation?
    @State private var reloadToken = 0

    init(client: HVClient, cache: DiskCache, namespace: String) {
        _model = State(initialValue: ChatListModel(client: client, cache: cache, namespace: namespace))
    }

    var body: some View {
        @Bindable var model = model
        content
            .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search chats")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: ChatDestination.newConversation) {
                        Image(systemName: "square.and.pencil").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("New chat")
                }
            }
            .confirmationDialog(
                "Delete this chat?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible, presenting: pendingDelete
            ) { conversation in
                Button("Delete chat", role: .destructive) { delete(conversation) }
                Button("Cancel", role: .cancel) {}
            } message: { conversation in
                Text("\u{201C}\(conversation.title)\u{201D} and the memory made from it are deleted. This can't be undone.")
            }
            // The first appearance and every return from a pushed chat load again
            // (cached first, so it is quick); the zero token is only the initial value.
            .task(id: reloadToken) {
                guard reloadToken > 0 else { return }
                await model.load()
            }
            .onAppear { reloadToken += 1 }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            HVListSkeleton(rows: 8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        case .failed(let message):
            HVErrorState(message: message) { reloadToken += 1 }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            if model.conversations.isEmpty {
                HVEmptyState(
                    symbol: "bubble.left.and.bubble.right",
                    title: "No chats yet.",
                    message: "Start one, or bring in your history from ChatGPT, Claude, Gemini or Grok.",
                    actionTitle: "Import your history"
                ) {
                    app.router.open(.route(.importHistory))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
    }

    private var list: some View {
        List {
            if model.isStale {
                HVStaleBanner()
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            if model.platforms.count > 1 {
                filterChips
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: HV.Space.xs, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            if model.visible.isEmpty {
                Text("Nothing matches.")
                    .font(.hvCallout)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, HV.Space.xl)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            ForEach(model.sections, id: \.bucket) { section in
                Section(header: HVSectionHeader(title: section.bucket.title)) {
                    ForEach(section.items) { conversation in
                        NavigationLink(value: Route.conversation(id: conversation.id)) {
                            ChatConversationRow(conversation: conversation)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDelete = conversation
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await model.load() }
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: HV.Space.xs) {
                chip("All", selected: model.platform == nil) { model.platform = nil }
                ForEach(model.platforms, id: \.self) { name in
                    chip(name, selected: model.platform == name) { model.platform = name }
                }
            }
            .padding(.horizontal, HV.Space.m)
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.select()
            action()
        } label: {
            HVChip(title: title, isSelected: selected)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func delete(_ conversation: ChatConversation) {
        Task {
            do {
                try await model.delete(conversation)
                Haptics.success()
            } catch {
                app.toasts.show(error: error)
            }
        }
    }
}

struct ChatConversationRow: View {
    let conversation: ChatConversation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(conversation.title)
                .font(.hvBody)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(2)
            HStack(spacing: HV.Space.xs) {
                if conversation.platform.isImported {
                    HVTag(text: conversation.platform.label, tint: Palette.coral)
                }
                if conversation.visibility.hasLink {
                    Label(conversation.visibility.title, systemImage: "link")
                        .labelStyle(.titleAndIcon)
                        .font(.hvCaption)
                        .foregroundStyle(Palette.textSecondary)
                }
                Text(ChatDates.relative(conversation.updatedAt))
                    .font(.hvCaption)
                    .foregroundStyle(Palette.textTertiary)
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, HV.Space.xxs)
        .frame(minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
