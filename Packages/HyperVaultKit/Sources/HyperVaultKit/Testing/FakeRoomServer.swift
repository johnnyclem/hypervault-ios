import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A room as the server keeps it, for tests and previews: a queue of turns, a lease, the turn in flight and the
/// transcript, with the failures a real one has (a response that never arrives, a run that dies in the middle of a
/// turn). Unlike `MockTransport`'s canned routes it keeps state between requests and takes time over a turn, so a
/// test can watch the room change while a request is still open. It speaks app/api/rooms/**.
///
/// Positions count up from 0 and a turn answers `"<handle> says hello"`. Hand-offs between members and the round's
/// budget running out are not modelled.
public actor FakeRoomServer {
    public enum Style: Sendable {
        /// The server as it was: a post runs up to three turns before it answers and ignores `run: false`, `/run`
        /// ignores `turns`, `running` stays true for as long as a lease is left behind, and nothing says whose turn
        /// it is (no `current`).
        case legacy
        /// The server that reports the turn in flight (`current`), lets a lease run out, honours `run: false` on a
        /// post and `turns` on `/run`, and writes a note for a turn a dead run lost.
        case queued
    }

    public struct Failure: Sendable, Equatable {
        /// The post is carried out and its answer is lost on the way (the phone sees a dropped connection). Only
        /// meaningful for a post that runs its turns inside the request.
        public var losePostAnswer = false
        /// The run dies in the middle of this turn (1 is the first turn taken): nothing is written for it, the lease
        /// is never released and the turn is off the queue.
        public var dieDuringTurn: Int?
        /// The next this many reads of the room answer 503.
        public var failReads = 0

        public init(losePostAnswer: Bool = false, dieDuringTurn: Int? = nil, failReads: Int = 0) {
            self.losePostAnswer = losePostAnswer
            self.dieDuringTurn = dieDuringTurn
            self.failReads = failReads
        }
    }

    public let roomID: String
    public let handles: [String]
    public let style: Style
    public private(set) var failure = Failure()
    /// How long a turn takes.
    public let turnSeconds: Double
    /// Every request seen, as `"POST /api/rooms/r1/run?turns=1"`.
    public private(set) var requests: [String] = []

    private struct Message {
        var id: String
        var position: Int
        var kind: String
        var handle: String?
        var content: String
        var mentions: [String]
    }

    private var messages: [Message] = []
    private var queue: [String] = []
    private var budget = 0
    private var current: (handle: String, startedAt: Date)?
    private var leaseHeld = false
    private var leaseLapsed = false
    private var turnsTaken = 0
    private var holdAt: Int?

    public init(roomID: String = "r1", handles: [String] = ["claude", "custom"], style: Style = .queued, turnSeconds: Double = 0.05) {
        self.roomID = roomID
        self.handles = handles
        self.style = style
        self.turnSeconds = turnSeconds
    }

    // MARK: Steering a test

    public func set(failure: Failure) { self.failure = failure }

    /// Time passes until the lease of a run that died has run out.
    public func lapseLease() { leaseLapsed = true }

    /// The turn with this number (1 is the first taken) waits, with its member shown as thinking, until
    /// `releaseTurn()`: a model that is slow, held exactly where a test wants to look.
    public func holdTurn(_ number: Int) { holdAt = number }

    public func releaseTurn() { holdAt = nil }

    /// A message from somewhere else (another device, an agent holding an API key): kept, nothing queued or run.
    @discardableResult
    public func speak(as handle: String? = nil, _ content: String) -> Int {
        append(kind: handle == nil ? "human" : "agent", handle: handle, content: content, mentions: []).position
    }

    // MARK: What a test can ask

    /// A live run holds the room.
    public var isRunning: Bool { leaseHeld && !leaseLapsed }
    public var agentCount: Int { messages.filter { $0.kind == "agent" }.count }
    public var positions: [Int] { messages.map(\.position) }
    public var queued: [String] { queue }
    public var turnsInFlight: String? { current?.handle }

    // MARK: Requests

    public func handle(method: String, path: String, query: String?, body: Data?) async -> (status: Int, json: String) {
        requests.append("\(method) \(path)\(query.map { "?" + $0 } ?? "")")
        let base = "/api/rooms/\(roomID)"
        switch (method, path) {
        case ("GET", base):
            if failure.failReads > 0 {
                failure.failReads -= 1
                return (503, Self.text(["error": "The database is busy."]))
            }
            return (200, Self.text(detail(after: query.flatMap { Self.value("after", in: $0) }.flatMap(Int.init))))
        case ("POST", base + "/messages"):
            let sent = (body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
            let content = (sent["content"] as? String) ?? ""
            let runInline = style == .legacy || (sent["run"] as? Bool) != false
            return await post(content, runInline: runInline)
        case ("POST", base + "/run"):
            let asked = query.flatMap { Self.value("turns", in: $0) }.flatMap(Int.init)
            let turns = style == .legacy ? 3 : Swift.min(Swift.max(asked ?? 3, 1), 3)
            return await run(turns: turns)
        default:
            return (404, Self.text(["error": "No fake route for \(method) \(path)"]))
        }
    }

    private enum Ran {
        case produced([Message])
        case busy
        case died
    }

    private func post(_ content: String, runInline: Bool) async -> (status: Int, json: String) {
        // A server that knows about lost turns writes one down before the person's words, so the note sits where the
        // turn was lost; with a live run holding the room it leaves it alone.
        var opening: [Message] = []
        if style == .queued, let lost = current, !isRunning {
            opening.append(append(kind: "system", handle: nil, content: Self.lostNote(lost.handle), mentions: []))
            current = nil
        }
        let mentions = ChatRoomHandles.mentions(in: content, handles: handles)
        opening.append(append(kind: "human", handle: nil, content: content, mentions: mentions))
        queue = Self.dedupe(queue + (mentions.isEmpty ? handles : mentions))
        budget = 12
        guard runInline else { return (200, Self.text(runShape(messages: opening, busy: false))) }
        if failure.losePostAnswer {
            // The work goes on; the answer does not come back.
            Task { _ = await self.runTurns(3) }
            return (599, "")
        }
        switch await runTurns(3) {
        case .produced(let more): return (200, Self.text(runShape(messages: opening + more, busy: false)))
        case .busy: return (200, Self.text(runShape(messages: opening, busy: true)))
        case .died: return (504, "")
        }
    }

    private func run(turns: Int) async -> (status: Int, json: String) {
        switch await runTurns(turns) {
        case .produced(let produced): return (200, Self.text(runShape(messages: produced, busy: false)))
        case .busy: return (200, Self.text(runShape(messages: [], busy: true)))
        case .died: return (504, "")
        }
    }

    private func runTurns(_ turns: Int) async -> Ran {
        guard !queue.isEmpty || current != nil else { return .produced([]) }
        if isRunning { return .busy }
        leaseHeld = true
        leaseLapsed = false
        var produced: [Message] = []
        if let lost = current {
            // The run that held the room is gone. A server that tracks turns says so; the old one just forgot it.
            if style == .queued {
                produced.append(append(kind: "system", handle: nil, content: Self.lostNote(lost.handle), mentions: []))
            }
            current = nil
        }
        for _ in 0..<turns {
            guard !queue.isEmpty, budget > 0 else { break }
            let handle = queue.removeFirst()
            budget -= 1
            turnsTaken += 1
            current = (handle, Date())
            while holdAt == turnsTaken { try? await Task.sleep(nanoseconds: 2_000_000) }
            try? await Task.sleep(nanoseconds: UInt64(turnSeconds * 1_000_000_000))
            if failure.dieDuringTurn == turnsTaken { return .died }
            produced.append(append(kind: "agent", handle: handle, content: "\(handle) says hello", mentions: []))
            current = nil
        }
        leaseHeld = false
        return .produced(produced)
    }

    // MARK: Shapes

    private func append(kind: String, handle: String?, content: String, mentions: [String]) -> Message {
        let message = Message(
            id: "m\(messages.count)", position: messages.count, kind: kind, handle: handle, content: content, mentions: mentions
        )
        messages.append(message)
        return message
    }

    private func detail(after: Int?) -> [String: Any] {
        let shown = messages.filter { $0.position > (after ?? -1) }.map { json($0) }
        let members: [[String: Any]] = handles.enumerated().map { index, handle in
            [
                "id": "mem\(index)", "room_id": roomID, "backend_id": "b\(index)", "handle": handle, "role_brief": "",
                "position": index,
                "backend": ["name": handle, "provider": "custom", "default_model": "minimax-m3"] as [String: Any],
            ]
        }
        var room: [String: Any] = ["id": roomID, "title": "All hands", "pending": pendingJSON(), "budget": budget]
        // The old server's flag only ever said a lease had been written.
        room["running"] = style == .queued ? isRunning : leaseHeld
        if style == .queued { room["current"] = currentJSON() }
        return ["room": room, "members": members, "messages": shown]
    }

    private func runShape(messages shown: [Message], busy: Bool) -> [String: Any] {
        var answer: [String: Any] = ["messages": shown.map { json($0) }, "pending": pendingJSON(), "budget": budget, "busy": busy]
        if style == .queued { answer["current"] = currentJSON() }
        return answer
    }

    private func pendingJSON() -> [[String: Any]] { queue.map { ["handle": $0, "reason": ""] } }

    private func currentJSON() -> Any {
        guard let current else { return NSNull() }
        return ["handle": current.handle, "reason": "", "started_at": HVDate.format(current.startedAt)] as [String: Any]
    }

    private func json(_ m: Message) -> [String: Any] {
        [
            "id": m.id, "room_id": roomID, "position": m.position, "sender_kind": m.kind,
            "sender_handle": m.handle.map { $0 as Any } ?? NSNull(), "member_id": NSNull(), "content": m.content,
            "mentions": m.mentions, "tool_turns": [Any](), "model": NSNull(), "status": "complete",
            "created_at": HVDate.format(Date(timeIntervalSince1970: 1_793_700_000 + Double(m.position))),
        ]
    }

    private static func lostNote(_ handle: String) -> String {
        "@\(handle)'s turn was cut off before they finished, so their reply may not have been saved."
    }

    private static func text(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func dedupe(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }

    private static func value(_ name: String, in query: String) -> String? {
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[0] == name { return parts[1] }
        }
        return nil
    }
}

/// `FakeRoomServer` behind the client's transport seam.
public struct FakeRoomTransport: HTTPTransport {
    public let server: FakeRoomServer
    public init(server: FakeRoomServer) { self.server = server }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let url = request.url
        let answer = await server.handle(
            method: request.httpMethod ?? "GET", path: url?.path ?? "", query: url?.query, body: request.httpBody
        )
        // 599 is the fake's own word for "the connection dropped before the answer got here".
        if answer.status == 599 { throw URLError(.networkConnectionLost) }
        return HTTPResponse(status: answer.status, headers: ["content-type": "application/json"], data: Data(answer.json.utf8))
    }
}
