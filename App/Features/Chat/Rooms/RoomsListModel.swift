import HyperVaultKit
import SwiftUI

/// The colours of one room: each member wears the tone of their model (`ChatAgentTone`), and a second
/// member of the same model takes a neighbouring tone, so every dot in the room is its own.
struct ChatRoomPalette {
    private let tones: [String: ChatAgentTone]

    init(members: [ChatRoomMember]) {
        let tones = ChatAgentTone.tones(forProviders: members.map { $0.backend?.provider ?? "" })
        self.tones = Dictionary(zip(members.map(\.handle), tones), uniquingKeysWith: { first, _ in first })
    }

    func color(for member: ChatRoomMember) -> Color {
        tones[member.handle]?.color ?? Palette.textSecondary
    }

    /// The colour of whoever wrote with `handle`; a handle the room no longer has is plain grey.
    func color(forHandle handle: String?) -> Color {
        handle.flatMap { tones[$0]?.color } ?? Palette.textSecondary
    }
}

/// The Rooms half of the chat tab: cached first, then fresh; delete is optimistic.
@MainActor
@Observable
final class ChatRoomsListModel {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var rooms: [ChatRoomSummary] = []
    private(set) var isStale = false

    /// The rooms under "Today", "Previous 7 days" and so on, as the chats are.
    var sections: [(bucket: ChatDates.Bucket, items: [ChatRoomSummary])] {
        ChatDates.sections(of: rooms, date: \.updatedAt)
    }

    private let client: HVClient
    private let cache: DiskCache
    private let namespace: String
    static let cacheKey = "chat.rooms"

    init(client: HVClient, cache: DiskCache, namespace: String) {
        self.client = client
        self.cache = cache
        self.namespace = namespace
    }

    func load() async {
        let client = self.client
        do {
            let stream = cachedLoad(cache: cache, namespace: namespace, key: Self.cacheKey) {
                try await client.send(.rooms)
            }
            for try await loaded in stream {
                rooms = loaded.value
                isStale = loaded.isStale
                phase = .loaded
            }
        } catch {
            if rooms.isEmpty { phase = .failed((error as? HVError)?.userMessage ?? error.localizedDescription) }
        }
    }

    func delete(_ room: ChatRoomSummary) async throws {
        guard let index = rooms.firstIndex(where: { $0.id == room.id }) else { return }
        let removed = rooms.remove(at: index)
        do {
            _ = try await client.send(.deleteRoom(id: room.id))
            await cache.store(rooms, key: Self.cacheKey, namespace: namespace)
        } catch let error as HVError {
            rooms.insert(removed, at: min(index, rooms.count))
            throw ChatActionError(message: error.sentence(offline: "Network hiccup. The room was not deleted."))
        }
    }

    /// A room that was just made shows at the top before the list reloads.
    func added(_ room: ChatRoomSummary) {
        rooms.insert(room, at: 0)
        phase = .loaded
    }
}
