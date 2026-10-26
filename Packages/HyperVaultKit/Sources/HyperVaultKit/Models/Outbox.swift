import Foundation

/// Something kept from the share sheet (or a Shortcut) while there was no way to send it. It waits in
/// the shared container until the app next has the network, then is kept like any other thing.
public struct OutboxItem: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let content: String
    public let sourcePrompt: String?
    public let createdAt: Date

    public init(id: String = UUID().uuidString, content: String, sourcePrompt: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.content = content
        self.sourcePrompt = sourcePrompt
        self.createdAt = createdAt
    }
}

public enum Outbox {
    /// The most items that wait at once; past it the oldest give way, so a long offline spell cannot grow without bound.
    public static let capacity = 50

    /// Whether a keep that failed should wait for another try. A network that did not answer, a
    /// busy server and a signed-out session all pass; a refusal that repeating cannot fix
    /// (too large, not accepted) does not, because it would sit there forever.
    public static func shouldRetain(after error: HVError) -> Bool {
        switch error {
        case .transport, .unauthorized, .cancelled:
            return true
        case .api(let failure):
            return failure.status == 401 || failure.status == 403 || failure.status == 408 || failure.status == 429 || failure.status >= 500
        case .decoding, .invalidRequest:
            return false
        }
    }

    public static func adding(_ item: OutboxItem, to items: [OutboxItem]) -> [OutboxItem] {
        let next = items.filter { $0.id != item.id } + [item]
        return next.count > capacity ? Array(next.suffix(capacity)) : next
    }

    public struct Flush: Sendable, Equatable {
        public let kept: [OutboxItem]
        public let remaining: [OutboxItem]
        public let dropped: [OutboxItem]
    }

    /// Tries each waiting item in order. Stops at the first failure that is the network's or the
    /// session's (the rest would fail the same way); an item the server will never take is dropped.
    public static func flush(_ items: [OutboxItem], send: (OutboxItem) async throws -> Void) async -> Flush {
        var kept: [OutboxItem] = []
        var dropped: [OutboxItem] = []
        var remaining = items
        while let item = remaining.first {
            do {
                try await send(item)
                kept.append(item)
                remaining.removeFirst()
            } catch {
                let failure = (error as? HVError) ?? .transport(error.localizedDescription)
                if shouldRetain(after: failure) { break }
                dropped.append(item)
                remaining.removeFirst()
            }
        }
        return Flush(kept: kept, remaining: remaining, dropped: dropped)
    }
}
