import Foundation

/// Drives a room: says something, then keeps asking the server for the next
/// turns until the queue is empty or the round's budget is spent. The server
/// runs at most three agent turns (about 75 seconds) per request, so a round
/// of twelve takes several. `onProgress` hears every answer as it lands, on
/// the main actor and in order.
public struct ChatRoomDriver: Sendable {
    public enum Outcome: Sendable, Equatable {
        /// The queue is empty.
        case finished
        /// Several runs in a row produced nothing while turns were still queued.
        /// The room keeps its queue; running again resumes it.
        case stalled
    }

    let client: HVClient
    let roomID: String
    /// How long to wait before asking again when another client holds the room.
    let pollDelay: TimeInterval
    /// A ceiling on requests in one drive, so nothing loops forever.
    let maxRequests: Int
    let sleep: @Sendable (TimeInterval) async -> Void

    public init(
        client: HVClient, roomID: String, pollDelay: TimeInterval = 4, maxRequests: Int = 40,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.client = client
        self.roomID = roomID
        self.pollDelay = pollDelay
        self.maxRequests = maxRequests
        self.sleep = sleep
    }

    /// Posts the person's message, then drives the round to its end.
    public func send(_ content: String, onProgress: @escaping @MainActor @Sendable (ChatRoomRun) -> Void) async throws -> Outcome {
        let first = try await client.send(.postRoomMessage(roomID: roomID, content: content))
        await onProgress(first)
        return try await drive(after: first, onProgress: onProgress)
    }

    /// Picks a queued round back up (the room was left mid-round, or another
    /// client started it).
    public func resume(onProgress: @escaping @MainActor @Sendable (ChatRoomRun) -> Void) async throws -> Outcome {
        try await drive(after: nil, onProgress: onProgress)
    }

    func drive(after start: ChatRoomRun?, onProgress: @escaping @MainActor @Sendable (ChatRoomRun) -> Void) async throws -> Outcome {
        var current = start
        var fruitless = 0
        for _ in 0..<maxRequests {
            if let current, current.pending.isEmpty, !current.busy { return .finished }
            if Task.isCancelled { throw HVError.cancelled }
            if current?.busy == true { await sleep(pollDelay) }
            let next = try await client.send(.runRoom(id: roomID))
            await onProgress(next)
            if next.pending.isEmpty, !next.busy { return .finished }
            fruitless = (next.messages.isEmpty && !next.busy) ? fruitless + 1 : 0
            if fruitless >= 3 { return .stalled }
            current = next
        }
        return .stalled
    }
}
