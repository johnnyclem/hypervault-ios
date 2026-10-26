import HyperVaultKit
import SwiftUI

/// The Rooms half of the chat tab: group chats with several of your models.
struct ChatRoomsListView: View {
    @Environment(AppModel.self) private var app
    private let client: HVClient
    private let cache: DiskCache
    private let namespace: String
    @State private var model: ChatRoomsListModel
    @State private var showNew = false
    @State private var pendingDelete: ChatRoomSummary?
    @State private var reloadToken = 0

    init(client: HVClient, cache: DiskCache, namespace: String) {
        self.client = client
        self.cache = cache
        self.namespace = namespace
        _model = State(initialValue: ChatRoomsListModel(client: client, cache: cache, namespace: namespace))
    }

    var body: some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNew = true } label: {
                        Image(systemName: "plus").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("New room")
                }
            }
            .sheet(isPresented: $showNew) {
                ChatNewRoomSheet(client: client, cache: cache, namespace: namespace) { created in
                    model.added(created)
                    app.router.push(.room(id: created.id))
                }
            }
            .confirmationDialog(
                "Delete this room?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible, presenting: pendingDelete
            ) { room in
                Button("Delete room", role: .destructive) { delete(room) }
                Button("Cancel", role: .cancel) {}
            } message: { room in
                Text("\u{201C}\(room.title)\u{201D} and everything said in it are deleted. This can't be undone.")
            }
            .task(id: reloadToken) {
                guard reloadToken > 0 else { return }
                await model.load()
            }
            .onAppear { reloadToken += 1 }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            HVListSkeleton(rows: 5).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        case .failed(let message):
            HVErrorState(message: message) { reloadToken += 1 }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            if model.rooms.isEmpty {
                HVEmptyState(
                    symbol: "person.3",
                    title: "No rooms yet.",
                    message: "Put several of your models in one room and run them like a team: you say who does what, they hand work to each other.",
                    actionTitle: "Start a room"
                ) { showNew = true }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
    }

    private var list: some View {
        List {
            if model.isStale {
                HVStaleBanner().listRowSeparator(.hidden).listRowBackground(Color.clear)
            }
            ForEach(model.rooms) { room in
                NavigationLink(value: Route.room(id: room.id)) {
                    ChatRoomRow(room: room)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) { pendingDelete = room } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await model.load() }
    }

    private func delete(_ room: ChatRoomSummary) {
        Task {
            do {
                try await model.delete(room)
                Haptics.success()
            } catch {
                app.toasts.show(error: error)
            }
        }
    }
}

struct ChatRoomRow: View {
    let room: ChatRoomSummary

    var body: some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(room.title).font(.hvBody).foregroundStyle(Palette.textPrimary).lineLimit(2)
                Spacer(minLength: HV.Space.xs)
                Text(ChatDates.relative(room.updatedAt)).font(.hvCaption).foregroundStyle(Palette.textTertiary)
            }
            ChatFlowLayout(spacing: 6) {
                ForEach(Array(room.members.enumerated()), id: \.element.id) { index, member in
                    Text("@\(member.handle)")
                        .font(.hvCaption.weight(.medium))
                        .foregroundStyle(ChatRoomPalette.color(at: index))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(ChatRoomPalette.color(at: index).opacity(0.14), in: Capsule())
                }
                if !room.pending.isEmpty {
                    HVTag(text: "\(room.pending.count) queued", tint: Color.accentColor)
                }
            }
        }
        .padding(.vertical, HV.Space.xxs)
        .frame(minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(room.title), \(room.members.map { "@" + $0.handle }.joined(separator: ", "))")
    }
}
