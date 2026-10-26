import Foundation

/// Runs `run` over every item with at most `limit` in flight and settles all of
/// them: one that fails does not stop the others, and the answers come back in
/// the order of the items. The web's `settleBounded`, a few at a time instead
/// of all at once.
enum MailParallel {
    static func settle<Item: Sendable, Output: Sendable>(
        _ items: [Item],
        limit: Int,
        _ run: @escaping @Sendable (Item) async -> Output
    ) async -> [Output] {
        var results = [Output?](repeating: nil, count: items.count)
        await withTaskGroup(of: (Int, Output).self) { group in
            var iterator = items.enumerated().makeIterator()
            for _ in 0..<min(max(limit, 1), items.count) {
                guard let (index, item) = iterator.next() else { break }
                group.addTask { (index, await run(item)) }
            }
            while let (index, output) = await group.next() {
                results[index] = output
                if let (next, item) = iterator.next() {
                    group.addTask { (next, await run(item)) }
                }
            }
        }
        return results.compactMap { $0 }
    }
}

/// What moving a thread did.
public enum MailMoveResult: Sendable, Equatable {
    case moved(Int)
    case nothing
    case tooMany(cap: Int)
}

/// The actions on mail that take more than one request: marking a thread read
/// and moving a whole thread. Each is a `PATCH` per message through the same
/// route an agent's mark-read uses; there is no thread-level route.
public struct MailService: Sendable {
    public let client: HVClient
    /// Changes in flight at once while a thread is moved or marked read.
    public static let concurrency = 6

    public init(client: HVClient) {
        self.client = client
    }

    /// Clears the unread bit on each id, a few at a time, and returns the ids
    /// the server accepted (a failure leaves that message unread, quietly).
    public func markRead(_ ids: [String], mailbox: String?) async -> [String] {
        guard !ids.isEmpty else { return [] }
        let client = self.client
        let cleared = await MailParallel.settle(ids, limit: Self.concurrency) { id -> String? in
            do {
                _ = try await client.send(.mailUpdate(id: id, unread: false, mailbox: mailbox))
                return id
            } catch {
                return nil
            }
        }
        return cleared.compactMap { $0 }
    }

    /// Moves every message of a thread that is elsewhere into `folder`. Pages
    /// not yet loaded are read first (a thread over the cap is refused before
    /// anything changes, so it is never half moved). Throws the first failure
    /// after trying the rest.
    public func moveThread(
        id: String,
        mailbox: String?,
        loaded: [MailMessage],
        olderCursor: String?,
        to folder: MailFolder
    ) async throws -> MailMoveResult {
        var all = loaded
        var cursor = olderCursor
        while let next = cursor, all.count <= MailMovePlan.cap {
            let page = try await client.send(.mailThread(threadId: id, mailbox: mailbox, cursor: next))
            all = MailThreads.appendUnique(page.messages, all)
            cursor = page.nextCursor
        }
        switch MailMovePlan.make(messages: all, to: folder) {
        case .tooMany(let cap):
            return .tooMany(cap: cap)
        case .nothing:
            return .nothing
        case .move(let ids):
            let client = self.client
            let failures = await MailParallel.settle(ids, limit: Self.concurrency) { messageId -> HVError? in
                do {
                    _ = try await client.send(.mailUpdate(id: messageId, folder: folder, mailbox: mailbox))
                    return nil
                } catch {
                    return (error as? HVError) ?? HVError.transport(error.localizedDescription)
                }
            }
            if let failure = failures.compactMap({ $0 }).first { throw failure }
            return .moved(ids.count)
        }
    }
}
