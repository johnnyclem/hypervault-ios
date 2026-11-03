import Foundation

/// How often to ask the server what the room has said, while the screen is up.
public struct ChatRoomPollSchedule: Sendable, Equatable {
    /// The wait after 0, 1, 2... asks that brought nothing new; the last step repeats.
    public var active: [TimeInterval]
    /// The wait between asks while nothing is moving (another device or an agent may still speak).
    public var idle: TimeInterval
    /// The longest wait after failed asks (the wait doubles from 2 seconds).
    public var failureCeiling: TimeInterval

    public init(active: [TimeInterval] = [1.5, 1.5, 2, 3, 4, 5], idle: TimeInterval = 20, failureCeiling: TimeInterval = 15) {
        self.active = active
        self.idle = idle
        self.failureCeiling = failureCeiling
    }

    public static let standard = ChatRoomPollSchedule()

    /// The wait after an ask that worked. `quiet` counts the asks in a row that brought nothing new.
    public func delay(quiet: Int, isActive: Bool) -> TimeInterval {
        guard isActive, !active.isEmpty else { return idle }
        return active[Swift.min(Swift.max(quiet, 0), active.count - 1)]
    }

    /// The wait after `failures` asks in a row that failed: 2, 4, 8 seconds, then the ceiling.
    public func delay(failures: Int) -> TimeInterval {
        Swift.min(failureCeiling, 2 * pow(2, Double(Swift.max(failures, 1) - 1)))
    }
}

/// How fast the phone asks, in one place so a test can make a minute pass in a moment.
public struct ChatRoomPace: Sendable {
    public var schedule: ChatRoomPollSchedule
    /// The longest the follower sleeps without looking at the room's state again.
    public var tick: TimeInterval
    /// The waits between asks while another run holds the room (`ChatRoomDriver`); the last step repeats.
    public var busySteps: [TimeInterval]
    public var sleep: @Sendable (TimeInterval) async -> Void

    public init(
        schedule: ChatRoomPollSchedule = .standard, tick: TimeInterval = 0.5, busySteps: [TimeInterval] = [3, 4, 5, 6],
        sleep: @escaping @Sendable (TimeInterval) async -> Void = ChatRoomPace.realSleep
    ) {
        self.schedule = schedule
        self.tick = tick
        self.busySteps = busySteps
        self.sleep = sleep
    }

    public static let live = ChatRoomPace()

    /// Waits; returns early when the task is cancelled (the caller looks at `Task.isCancelled`).
    @Sendable public static func realSleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(Swift.max(0, seconds) * 1_000_000_000))
    }
}

/// What the follower needs to know about the room, asked on the main actor before every request.
public struct ChatRoomFollowState: Sendable, Equatable {
    /// Where to poll from: `ChatRoomTranscript.cursor`.
    public var cursor: Int?
    /// A round is moving (this phone is driving one, a run holds the room, the person's message is on its way).
    public var isActive: Bool

    public init(cursor: Int?, isActive: Bool) {
        self.cursor = cursor
        self.isActive = isActive
    }
}

/// Keeps a room on screen true to the server for as long as the screen is up: it reads the room past the place the
/// phone has reached, hands every answer to `onSnapshot`, and asks again soon while the room is moving and rarely
/// while it is not. It does not drive anything (that is `ChatRoomDriver`), so a request that never comes back, or a
/// run that died, cannot keep the person from seeing what the room has said.
///
/// It runs until the task it runs in is cancelled (a SwiftUI `.task` is, when the screen goes), and a failed ask
/// never ends it: a flaky network must not leave a screen stuck.
public struct ChatRoomFollower: Sendable {
    let client: HVClient
    let roomID: String
    let schedule: ChatRoomPollSchedule
    /// The longest the follower sleeps without looking at `state` again, so a round that starts is noticed at once.
    let tick: TimeInterval
    let sleep: @Sendable (TimeInterval) async -> Void

    public init(client: HVClient, roomID: String, pace: ChatRoomPace = .live) {
        self.client = client
        self.roomID = roomID
        self.schedule = pace.schedule
        // A tick of nothing would never let the wait run out.
        self.tick = Swift.max(pace.tick, 0.001)
        self.sleep = pace.sleep
    }

    /// - Parameters:
    ///   - state: asked on the main actor before every request and after every tick of a wait.
    ///   - onSnapshot: hears every read of the room, on the main actor, in order. Apply it to a `ChatRoomTranscript`
    ///     so that the next `state()` reports the cursor it moved.
    public func follow(
        state: @escaping @MainActor @Sendable () -> ChatRoomFollowState,
        onSnapshot: @escaping @MainActor @Sendable (ChatRoomDetail) -> Void
    ) async {
        var quiet = 0
        var failures = 0
        var signature = ""
        var reached = Int.min
        while !Task.isCancelled {
            let asked = await state()
            var wait: TimeInterval
            do {
                let detail = try await client.send(.room(id: roomID, after: asked.cursor))
                if Task.isCancelled { return }
                failures = 0
                await onSnapshot(detail)
                let seen = Self.signature(of: detail)
                quiet = (!detail.messages.isEmpty || seen != signature) ? 0 : quiet + 1
                signature = seen
                // A full page means more behind it: ask again straight away, as long as each page gets further
                // (a caller that does not move the cursor would otherwise be asked the same page for ever).
                let top = detail.messages.map(\.position).max()
                let advanced = top.map { $0 > reached } ?? false
                if let top { reached = Swift.max(reached, top) }
                if detail.messages.count >= Self.pageSize, advanced { continue }
                wait = schedule.delay(quiet: quiet, isActive: asked.isActive)
            } catch HVError.cancelled {
                return
            } catch {
                failures += 1
                wait = schedule.delay(failures: failures)
            }
            // Sleep in short ticks, and look again at once if the room woke (or went to sleep) in the meantime.
            while wait > 0, !Task.isCancelled {
                let step = Swift.min(tick, wait)
                await sleep(step)
                wait -= step
                if await state().isActive != asked.isActive {
                    quiet = 0
                    break
                }
            }
        }
    }

    /// The server's page for a read.
    static let pageSize = 500

    /// What about the room's header tells a change even when no message came with it.
    static func signature(of detail: ChatRoomDetail) -> String {
        let room = detail.room
        return "\(room.running)|\(room.current?.handle ?? "")|\(room.pending.map(\.handle).joined(separator: ","))"
    }
}
