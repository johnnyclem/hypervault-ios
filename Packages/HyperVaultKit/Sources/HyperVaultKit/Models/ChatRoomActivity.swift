import Foundation

/// What the room is doing right now, from what the server says and what this phone is doing, and nothing else. The
/// line under the thread ("@claude is thinking...") is drawn from this, so it can only say what is true:
///
/// - `thinking` only while the server holds a fresh lease and a turn is in flight (`current`);
/// - `next` for the head of a queue that nobody is working on yet, or between two turns;
/// - `cutOff` for a turn the server started and lost (its run died), which the next run records;
/// - `working` when a run holds the room and nothing says whose turn it is (a server that does not report `current`).
///
/// The old line was the head of the queue with "thinking" whenever this phone was driving. The server takes a turn off
/// the queue before it runs it, so that line named the wrong member while one thought, named nobody during the last
/// turn, and kept its dots for a run that had died.
public enum ChatRoomActivity: Sendable, Equatable {
    case idle
    /// The person's message is on its way to the server.
    case sending
    case thinking(handle: String, since: Date?, then: [String])
    case next(handle: String, then: [String])
    case working
    case cutOff(handle: String)

    /// - Parameters:
    ///   - header: the room as the server last reported it (a read, or the end of a post or a run).
    ///   - sending: the person's message has not been acknowledged yet.
    public static func resolve(header: ChatRoomHeader?, sending: Bool) -> ChatRoomActivity {
        if sending { return .sending }
        guard let header else { return .idle }
        let queued = header.pending.map(\.handle)
        if let current = header.current {
            return header.running
                ? .thinking(handle: current.handle, since: current.startedAt, then: queued)
                : .cutOff(handle: current.handle)
        }
        if let first = queued.first { return .next(handle: first, then: Array(queued.dropFirst())) }
        return header.running ? .working : .idle
    }

    /// A model is at work (or the message is travelling): the line carries the moving dots.
    public var isBusy: Bool {
        switch self {
        case .sending, .thinking, .working: return true
        case .idle, .next, .cutOff: return false
        }
    }

    /// The sentence for the line under the thread; nil when there is nothing to say.
    ///
    /// A turn lasts at most about two minutes (the server cuts a run off there), so a stretch outside what a turn can
    /// last is a clock that disagrees with the server's, not thinking: the seconds are left out rather than shown wrong.
    public func line(now: Date = Date()) -> String? {
        switch self {
        case .idle:
            return nil
        case .sending:
            return "Sending..."
        case .working:
            return "The room is working..."
        case .cutOff(let handle):
            return "@\(handle)'s turn was cut off"
        case .next(let handle, let then):
            return "@\(handle) is next" + Self.tail(then, joiner: ", ")
        case .thinking(let handle, let since, let then):
            var line = "@\(handle) is thinking..."
            if let since, let elapsed = Self.elapsed(from: since, to: now) { line += " " + elapsed }
            return line + Self.tail(then, joiner: " ")
        }
    }

    /// Seconds a turn may be shown to have lasted: from five (before that the number only flickers) to the server's
    /// own limit with a margin.
    static let shownSeconds = 5...180

    static func elapsed(from start: Date, to now: Date) -> String? {
        // The interval is judged as a Double and only then made an Int: the wire accepts a number as a date, so a
        // start of 1e300 reaches here, and `Int(_:)` of that traps instead of being left out.
        let interval = now.timeIntervalSince(start)
        guard interval.isFinite, interval >= Double(shownSeconds.lowerBound), interval < Double(shownSeconds.upperBound + 1)
        else { return nil }
        let seconds = Int(interval)
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }

    private static func tail(_ handles: [String], joiner: String) -> String {
        handles.isEmpty ? "" : joiner + "then " + handles.map { "@" + $0 }.joined(separator: ", ")
    }
}

extension ChatRoomHeader {
    /// Turns wait and nothing is running them (here or elsewhere), or a turn was lost: the person can carry on.
    public var canBeContinued: Bool {
        !running && (!pending.isEmpty || current != nil)
    }
}
