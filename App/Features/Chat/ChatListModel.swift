import HyperVaultKit
import SwiftUI

/// The conversations list: cached first, then fresh; search and a platform
/// filter run on what is already here; delete is optimistic and rolls back.
@MainActor
@Observable
final class ChatListModel {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var conversations: [ChatConversation] = []
    private(set) var isStale = false
    var query = ""
    /// The platform label being shown ("ChatGPT"), or nil for everything.
    var platform: String?

    private let client: HVClient
    private let cache: DiskCache
    private let namespace: String
    private static let cacheKey = "chat.conversations"

    init(client: HVClient, cache: DiskCache, namespace: String) {
        self.client = client
        self.cache = cache
        self.namespace = namespace
    }

    /// Whether the person has no chats, as the server last said it: Home shows its starter page then, and only then. "No
    /// chats" is never read off a cached copy (which may be old) or off a refresh that failed, so a person who has chats
    /// does not see the starter for the moment before the list comes, and one who is offline does not see it at all.
    var showsStarter: Bool { phase == .loaded && conversations.isEmpty && !isStale }

    func load() async {
        let client = self.client
        do {
            let stream = cachedLoad(cache: cache, namespace: namespace, key: Self.cacheKey) {
                try await client.send(.conversations)
            }
            for try await loaded in stream {
                // A cached "no chats" is a guess until the server has answered: it is passed over, so the page stays on what
                // it was (the skeleton, on a first look) and the starter does not flash under it. If the refresh behind it
                // failed too, nothing is known, and the page says so, unless the server's own "no chats" is already up.
                if loaded.value.isEmpty, loaded.isStale {
                    if let failure = loaded.refreshError, conversations.isEmpty, !showsStarter {
                        phase = .failed(failure.userMessage)
                    }
                    continue
                }
                conversations = loaded.value.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
                isStale = loaded.isStale
                phase = .loaded
            }
        } catch {
            if conversations.isEmpty, !showsStarter {
                phase = .failed((error as? HVError)?.userMessage ?? error.localizedDescription)
            }
        }
    }

    // MARK: What is shown

    /// Platforms present in the list, most common first.
    var platforms: [String] {
        let counts = Dictionary(grouping: conversations, by: { $0.platform.label }).mapValues(\.count)
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    /// The number on a platform's filter pill: how many conversations come from it, whatever is typed in the search.
    func count(for platform: String) -> Int {
        conversations.filter { $0.platform.label == platform }.count
    }

    var visible: [ChatConversation] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return conversations.filter { conversation in
            if let platform, conversation.platform.label != platform { return false }
            if needle.isEmpty { return true }
            return conversation.title.localizedCaseInsensitiveContains(needle)
        }
    }

    var sections: [(bucket: ChatDates.Bucket, items: [ChatConversation])] {
        ChatDates.sections(of: visible, date: \.updatedAt)
    }

    var isFiltering: Bool { platform != nil || !query.trimmingCharacters(in: .whitespaces).isEmpty }

    // MARK: Deleting

    /// Removes the row now and asks the server; puts it back if the server says no.
    func delete(_ conversation: ChatConversation) async throws {
        guard let index = conversations.firstIndex(where: { $0.id == conversation.id }) else { return }
        let removed = conversations.remove(at: index)
        do {
            _ = try await client.send(.deleteConversation(id: conversation.id))
            await cache.store(conversations, key: Self.cacheKey, namespace: namespace)
            await cache.remove(key: "chat.conversation.\(conversation.id)", namespace: namespace)
            // The last chat of a list that came from the cache: the cache cannot say there are no more, so the server is asked
            // before Home says there are none. (A list the server sent is empty for good: the starter shows at once.)
            if conversations.isEmpty, isStale { await load() }
        } catch let error as HVError {
            conversations.insert(removed, at: min(index, conversations.count))
            throw ChatActionError(message: error.sentence(offline: "Network hiccup. The chat was not deleted."))
        }
    }
}
