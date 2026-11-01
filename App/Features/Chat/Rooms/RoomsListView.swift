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
                        Image(systemName: HVSymbol.add).frame(width: 44, height: 44)
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
                    title: "No rooms yet",
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
                HVStaleBanner()
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            ForEach(model.sections, id: \.bucket) { section in
                Section(header: HVSectionHeader(title: section.bucket.title)) {
                    ForEach(section.items) { room in
                        NavigationLink(value: Route.room(id: room.id)) {
                            ChatRoomRow(room: room)
                        }
                        .accessibilityIdentifier("chat.room.\(room.id)")
                        .hvListRow()
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { pendingDelete = room } label: {
                                Label("Delete", systemImage: HVSymbol.delete)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
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
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let palette = ChatRoomPalette(members: room.members)
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            titleLine
            ChatFlowLayout(spacing: 6) {
                ForEach(room.members) { member in
                    ChatHandleChip(handle: member.handle, color: palette.color(for: member))
                }
                if !room.pending.isEmpty {
                    // Grey, not blue: a status is not a member, and blue is Gemini's.
                    HVTag(text: "\(room.pending.count) queued")
                }
            }
        }
        .padding(.vertical, HV.Space.xxs)
        .frame(minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(room.title), \(room.members.map { "@" + $0.handle }.joined(separator: ", "))")
    }

    /// The name, and when it last moved: side by side, or stacked when the text is too big to share a line.
    @ViewBuilder private var titleLine: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: HV.Space.xxs) {
                title
                updated
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                title
                Spacer(minLength: HV.Space.xs)
                updated
            }
        }
    }

    private var title: some View {
        Text(room.title).font(.hvBody).foregroundStyle(Palette.textPrimary).lineLimit(2)
    }

    private var updated: some View {
        Text(ChatDates.relative(room.updatedAt)).font(.hvCaption).foregroundStyle(Palette.textTertiary)
    }
}

/// "@grok" in the model's colour on `HV.Tint.fill` of the same colour. In the dark look the text holds 4.5:1 on its own
/// tint on the page, paper and raised paper. In the light look the lighter pairs fall a little under it (coral is 4.19:1
/// on the page and 3.88:1 on raised paper): the handle is a word the chip spells out, and the colour only echoes the model.
struct ChatHandleChip: View {
    let handle: String
    let color: Color
    var font: Font = .hvCaption.weight(.medium)
    var verticalPadding: CGFloat = HV.Space.xxs

    var body: some View {
        Text("@\(handle)")
            .font(font)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, verticalPadding)
            .background(color.opacity(HV.Tint.fill), in: Capsule())
    }
}
