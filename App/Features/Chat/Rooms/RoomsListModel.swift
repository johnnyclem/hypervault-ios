import HyperVaultKit
import SwiftUI

/// Each member of a room has a colour, by their place in the roster.
enum ChatRoomPalette {
    static let colors: [Color] = [Palette.sky, Palette.mint, Palette.amber, Palette.violet, Palette.rose, Palette.cyan]

    static func color(at index: Int) -> Color {
        colors[((index % colors.count) + colors.count) % colors.count]
    }

    static func color(for handle: String?, in members: [ChatRoomMember]) -> Color {
        guard let handle, let index = members.firstIndex(where: { $0.handle == handle }) else { return Palette.textSecondary }
        return color(at: index)
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
