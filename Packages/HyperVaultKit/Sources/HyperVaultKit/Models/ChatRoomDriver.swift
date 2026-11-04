import Foundation

/// Drives a room: says something, then keeps asking the server to take the next turn until the queue is empty or the
/// round's budget is spent. It asks for one turn per request (`turns: 1`), so each answer comes back as soon as that
/// member has spoken and no request has to outlast the server's limit. `onProgress` hears every answer as it lands, on
/// the main actor and in order.
///
/// The driver pushes the queue along; it does not decide what is on screen. What the room has said, and who is
/// thinking, is read from the server by `ChatRoomFollower`, so a request that never comes back cannot hide an answer.
///
/// It works against the server as it is today as well as the one that knows `run: false` and `turns`: a server that
/// ignores both answers the post after running the turns, and the driver finds the queue empty and stops there.
public struct ChatRoomDriver: Sendable {
    public enum Outcome: Sendable, Equatable {
        /// The queue is empty.
        case finished
        /// Runs in a row produced nothing while turns were still queued, or another run held the room for too long.
        /// The room keeps its queue; running again resumes it.
        case stalled
    }

    let client: HVClient
    let roomID: String
    /// How long to wait before asking again while another run holds the room: 3 seconds, then 4, 5 and 6.
    let busySteps: [TimeInterval]
    /// How many times in a row to ask a room another run holds. At the steps above, 40 asks take about four minutes,
    /// longer than the server keeps a lease, so a run that died is taken over before this gives up.
    let maxBusyAsks: Int
    /// A ceiling on requests in one drive, so nothing loops forever.
    let maxRequests: Int
    let sleep: @Sendable (TimeInterval) async -> Void

    public init(client: HVClient, roomID: String, pace: ChatRoomPace = .live, maxBusyAsks: Int = 40, maxRequests: Int = 80) {
        self.client = client
        self.roomID = roomID
        self.busySteps = pace.busySteps.isEmpty ? [3] : pace.busySteps
        self.maxBusyAsks = maxBusyAsks
        self.maxRequests = maxRequests
        self.sleep = pace.sleep
    }

    /// The old spelling: one wait between asks of a held room, and nothing but how to wait to configure.
    public init(
        client: HVClient, roomID: String, pollDelay: TimeInterval = 4, maxRequests: Int = 80,
        sleep: @escaping @Sendable (TimeInterval) async -> Void
    ) {
        self.init(client: client, roomID: roomID, pace: ChatRoomPace(busySteps: [pollDelay], sleep: sleep), maxRequests: maxRequests)
    }

    /// Posts the person's message (a server that knows `run: false` keeps it and queues the turns; one that does not
    /// runs them first), then drives the round to its end.
    public func send(_ content: String, onProgress: @escaping @MainActor @Sendable (ChatRoomRun) -> Void) async throws -> Outcome {
        let first = try await client.send(.postRoomMessage(roomID: roomID, content: content, run: false))
        await onProgress(first)
        return try await drive(after: first, onProgress: onProgress)
    }

    /// Picks a queued round back up (the room was left mid-round, or another client started it).
    public func resume(onProgress: @escaping @MainActor @Sendable (ChatRoomRun) -> Void) async throws -> Outcome {
        try await drive(after: nil, onProgress: onProgress)
    }

    func drive(after start: ChatRoomRun?, onProgress: @escaping @MainActor @Sendable (ChatRoomRun) -> Void) async throws -> Outcome {
        var current = start
        // The run before the one being judged: after a post, the post's answer; a resumed round has none yet.
        var lastRun = start
        var fruitless = 0
        var busyAsks = 0
        for _ in 0..<maxRequests {
            // Nothing queued, nobody holding the room, and no turn in flight that a run would have to account for.
            if let current, current.pending.isEmpty, !current.busy, current.current == nil { return .finished }
            if Task.isCancelled { throw HVError.cancelled }
            if current?.busy == true {
                if busyAsks >= maxBusyAsks { return .stalled }
                await sleep(busySteps[Swift.min(busyAsks, busySteps.count - 1)])
                busyAsks += 1
            } else {
                busyAsks = 0
            }
            let next = try await client.send(.runRoom(id: roomID, turns: 1))
            await onProgress(next)
            if next.pending.isEmpty, !next.busy { return .finished }
            // A run that wrote nothing is fruitless, unless it took a turn off the queue all the same (the member
            // had left the room): one turn per request would otherwise count three such turns as a stall. It is
            // compared with the run before it, which for the first run after a post is the post's own answer.
            let tookATurn = lastRun.map { next.pending.count < $0.pending.count } ?? false
            fruitless = (next.messages.isEmpty && !next.busy && !tookATurn) ? fruitless + 1 : 0
            if fruitless >= 3 { return .stalled }
            lastRun = next
            current = next
        }
        return .stalled
    }
}
