import HyperVaultKit
import XCTest
@testable import HyperVault

/// The room model against a fake server that keeps state and takes time: what the phone shows, and when, from the first
/// message of a new room to a round that dies half way. The Kit has the same rounds without the model
/// (`RoomRoundTests`); these are the model's part of them: the person's message at once, what is said about a message
/// that may not have been sent, and the lifetime of the follower.
@MainActor
final class RoomModelTests: XCTestCase {
    private let base = URL(string: "https://hv.test")!

    /// Asks every 10 ms while a round moves and notices within 5 ms that one started; a wait for a busy room is 10 ms.
    private let quick = ChatRoomPace(
        schedule: ChatRoomPollSchedule(active: [0.01], idle: 0.02, failureCeiling: 0.02), tick: 0.005, busySteps: [0.01],
        sleep: ChatRoomPace.realSleep
    )

    private func client(_ transport: any HTTPTransport) -> HVClient {
        HVClient(baseURL: base, transport: transport, tokens: StaticTokenProvider(), retry: .none, sleep: { _ in })
    }

    private func make(_ transport: any HTTPTransport) -> (model: ChatRoomModel, speech: RecordingAnnouncer) {
        let speech = RecordingAnnouncer()
        return (ChatRoomModel(roomID: "r1", client: client(transport), announcer: speech, pace: quick), speech)
    }

    private func make(_ server: FakeRoomServer) -> (model: ChatRoomModel, speech: RecordingAnnouncer) {
        make(FakeRoomTransport(server: server))
    }

    /// Fails the test, rather than hanging it, when `condition` does not come true in time.
    private func eventually(
        _ what: String, timeout: Double = 4, _ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for: \(what)", file: file, line: line)
    }

    private func requests(_ server: FakeRoomServer, prefix: String) async -> [String] {
        await server.requests.filter { $0.hasPrefix(prefix) }
    }

    /// Waits until a member's turn is under way on the server.
    private func waitForATurn(on server: FakeRoomServer) async {
        let deadline = Date().addingTimeInterval(4)
        while await server.turnsInFlight == nil, Date() < deadline { try? await Task.sleep(nanoseconds: 2_000_000) }
    }

    // MARK: The first message of a new room

    /// The server of today answers a post only after the turns, so the person used to see nothing until then: not their
    /// own message, not the first answer, not who was thinking.
    func testTheFirstMessageAndEachAnswerAppearWhileTheRequestIsStillOpen() async {
        let server = FakeRoomServer(style: .legacy, turnSeconds: 0.01)
        await server.holdTurn(2)
        let (model, _) = make(server)
        await model.load()
        let following = Task { await model.follow() }
        model.draft = "introduce yourselves"
        model.send()

        // At once, before any request has come back: the person's words, and the line that they are on their way.
        XCTAssertEqual(model.outgoing.map(\.text), ["introduce yourselves"])
        XCTAssertEqual(model.activity, .sending)
        XCTAssertEqual(model.draft, "")

        // The server keeps the message first; the follower finds it while the post is still open, and it takes the
        // place of the one that was travelling.
        await eventually("the person's message in the thread, from the server") { model.messages.first?.senderKind == .human }
        XCTAssertTrue(model.isDriving, "the post is still waiting for the turns")
        XCTAssertTrue(model.outgoing.isEmpty)

        // The first member's answer shows when it is written, not when the third turn ends; turn 2 is held.
        await eventually("the first answer") { model.messages.contains { $0.senderHandle == "claude" } }
        XCTAssertTrue(model.isDriving)
        XCTAssertFalse(model.messages.contains { $0.senderHandle == "custom" })
        // The server of today does not say whose turn it is, only that it is at work.
        await eventually("the room shown as working") { model.activity == .working(then: []) }

        await server.releaseTurn()
        await eventually("the round to end") { !model.isDriving && model.messages.count == 3 }
        XCTAssertEqual(model.messages.compactMap(\.senderHandle), ["claude", "custom"])
        await eventually("the line under the thread to go") { model.activity == .idle }
        XCTAssertNil(model.notice)
        XCTAssertEqual(model.draft, "")
        following.cancel()
    }

    /// With a server that only keeps the message and queues the turns, the phone drives them one request at a time and
    /// shows each answer as it lands.
    func testAServerThatOnlyQueuesIsDrivenOneTurnAtATime() async {
        let server = FakeRoomServer(style: .queued, turnSeconds: 0.01)
        await server.holdTurn(2)
        let (model, speech) = make(server)
        await model.load()
        let following = Task { await model.follow() }
        model.draft = "introduce yourselves"
        model.send()

        await eventually("the first answer alone") { model.messages.contains { $0.senderHandle == "claude" } }
        XCTAssertFalse(model.messages.contains { $0.senderHandle == "custom" }, "the second turn is a separate request")
        await eventually("the second member shown as thinking") {
            if case .thinking(let handle, _, _) = model.activity { return handle == "custom" }
            return false
        }
        XCTAssertTrue(model.isDriving)
        XCTAssertFalse(model.canContinue)

        await server.releaseTurn()
        await eventually("the round to end") { !model.isDriving && model.messages.count == 3 }
        await eventually("the line under the thread to go") { model.activity == .idle }
        following.cancel()
        let posts = await requests(server, prefix: "POST /api/rooms/r1/messages")
        let runs = await requests(server, prefix: "POST /api/rooms/r1/run?turns=1")
        XCTAssertEqual(posts.count, 1)
        XCTAssertGreaterThanOrEqual(runs.count, 2, "the post only queued the turns, so each took a request of its own")
        XCTAssertNil(model.notice)
        XCTAssertTrue(speech.spoken.contains { $0.contains("@claude") && $0.hasSuffix("replied.") })
    }

    /// The answer that finds a reply first says it; the one that finds it second does not say it again.
    func testAnAnswerIsSaidOnceWhoeverFindsItFirst() async {
        let server = FakeRoomServer(style: .legacy, turnSeconds: 0.01)
        await server.holdTurn(2)
        let (model, speech) = make(server)
        await model.load()
        let following = Task { await model.follow() }
        model.draft = "introduce yourselves"
        model.send()
        await eventually("the first answer") { model.messages.contains { $0.senderHandle == "claude" } }
        await server.releaseTurn()
        await eventually("the round to end") { !model.isDriving && model.messages.count == 3 }
        following.cancel()
        XCTAssertEqual(speech.spoken.filter { $0.contains("@claude") }.count, 1, "\(speech.spoken)")
        XCTAssertEqual(speech.spoken.filter { $0.contains("@custom") }.count, 1, "\(speech.spoken)")
    }

    /// Between two of its requests the phone is still working through the round: the line under the thread does not fall
    /// back to "is next" and come up again.
    func testARoundThePhoneIsDrivingNeverReadsAsWaiting() async {
        let server = FakeRoomServer(handles: ["a", "b", "c"], style: .queued, turnSeconds: 0.02)
        let (model, _) = make(server)
        await model.load()
        let following = Task { await model.follow() }
        model.draft = "go"
        model.send()
        var waiting = false
        let deadline = Date().addingTimeInterval(4)
        while model.messages.count < 4, Date() < deadline {
            if case .next = model.activity { waiting = true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(model.messages.count, 4, "the round ran")
        XCTAssertFalse(waiting)
        following.cancel()
    }

    // MARK: A reply that never comes back

    /// The owner's report: the first answer only appears after a second message. A post whose answer is lost used to
    /// leave the thread empty and the draft back in the box, and the server's work was never fetched.
    func testALostAnswerToTheFirstPostStillShowsEverythingTheRoomSaid() async {
        let server = FakeRoomServer(style: .legacy, turnSeconds: 0.05)
        await server.set(failure: .init(losePostAnswer: true))
        await server.holdTurn(1)
        let (model, _) = make(server)
        await model.load()
        let following = Task { await model.follow() }
        model.draft = "introduce yourselves"
        model.send()
        // The room is at work on the first turn when the phone finds out that the answer is gone.
        await eventually("the request to have ended") { !model.isDriving }
        XCTAssertEqual(model.draft, "", "the message is in the room; it does not come back into the box to be sent twice")
        XCTAssertTrue(model.outgoing.isEmpty)
        XCTAssertNil(model.notice, "the room carries on, so there is nothing to apologise for")
        XCTAssertEqual(model.messages.map(\.senderKind), [.human])

        await server.releaseTurn()
        await eventually("the whole round in the thread") { model.messages.count == 3 }
        XCTAssertEqual(model.messages.compactMap(\.senderHandle), ["claude", "custom"])
        following.cancel()
    }

    /// Without the follower (the screen is gone) a request that ends badly is still followed by a read.
    func testTheThreadIsReadOnceMoreWhenARequestEndsBadly() async {
        let server = FakeRoomServer(style: .legacy, turnSeconds: 0.01)
        await server.set(failure: .init(losePostAnswer: true))
        let (model, _) = make(server)
        await model.load()
        model.draft = "introduce yourselves"
        model.send()
        await eventually("the request to have ended") { !model.isDriving }
        XCTAssertEqual(model.messages.first?.senderKind, .human, "the person's words, from the room")
        XCTAssertTrue(model.outgoing.isEmpty)
        XCTAssertEqual(model.draft, "")
    }

    // MARK: A run that died

    func testARunThatDiedIsNotRunningForEverAndCanBeContinued() async {
        let server = FakeRoomServer(style: .queued, turnSeconds: 0.02)
        await server.set(failure: .init(dieDuringTurn: 2))
        let (model, speech) = make(server)
        await model.load()
        let following = Task { await model.follow() }
        model.draft = "introduce yourselves"
        model.send()
        await eventually("the request to have failed") { !model.isDriving }
        XCTAssertEqual(model.messages.compactMap(\.senderHandle), ["claude"])
        // The lease is still fresh: the room is reported as running a turn, so nothing offers to continue yet, and the
        // person is not told the message was lost: it was not.
        if case .thinking(let handle, _, _) = model.activity { XCTAssertEqual(handle, "custom") } else { XCTFail("\(model.activity)") }
        XCTAssertFalse(model.canContinue)
        XCTAssertNil(model.notice)

        await server.lapseLease()
        await eventually("the phone to know that the turn was cut off") { model.activity == .cutOff(handle: "custom") }
        XCTAssertTrue(model.canContinue)
        XCTAssertTrue(speech.spoken.contains("A turn was cut off and nobody is running this round. Continue is under the messages."))

        model.resume()
        await eventually("the round to be over") { !model.isDriving && !model.canContinue && model.activity == .idle }
        XCTAssertTrue(model.messages.contains { $0.senderKind == .system && $0.content.contains("@custom's turn was cut off") })
        following.cancel()
    }

    // MARK: Coming back to a room

    /// Turns left over by a round are offered, not run: nothing is spent on the person's behalf by looking at a room.
    func testAnUnfinishedRoundIsOfferedWhenTheRoomIsOpenedAndNotResumed() async {
        let transport = MockTransport(routes: [.json(.get, "/api/rooms/r1", RoomJSON.json(pending: ["claude", "custom"]))])
        let (model, speech) = make(transport)
        await model.load()
        let following = Task { await model.follow() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        following.cancel()
        XCTAssertTrue(model.canContinue)
        XCTAssertEqual(model.activity, .next(handle: "claude", then: ["custom"]))
        XCTAssertEqual(speech.spoken, ["2 turns still waiting. Nobody is running this round. Continue is under the messages."])
        let posts = await transport.requests.filter { $0.httpMethod == "POST" }
        XCTAssertTrue(posts.isEmpty, "no auto-resume")
    }

    // MARK: The follower's lifetime

    func testLeavingTheScreenStopsTheAsking() async {
        let server = FakeRoomServer(style: .queued, turnSeconds: 0.01)
        let (model, _) = make(server)
        await model.load()
        let following = Task { await model.follow() }
        try? await Task.sleep(nanoseconds: 80_000_000)
        following.cancel()
        _ = await following.value
        let before = await server.requests.count
        try? await Task.sleep(nanoseconds: 150_000_000)
        let after = await server.requests.count
        XCTAssertEqual(before, after)
    }

    func testARoomThatCouldNotBeOpenedOpensItselfWhenTheServerComesBack() async {
        let counter = ReadCounter()
        let transport = MockTransport(routes: [
            MockRoute(.get, "/api/rooms/r1") { _ in
                if counter.bump() <= 2 { return RoomJSON.answer(status: 503, #"{"error":"down"}"#) }
                return RoomJSON.answer(RoomJSON.json(title: "All hands"))
            },
        ])
        let (model, _) = make(transport)
        await model.load()
        XCTAssertEqual(model.phase, .failed("down"))
        let following = Task { await model.follow() }
        await eventually("the room to open") { model.phase == .ready }
        XCTAssertEqual(model.title, "All hands")
        following.cancel()
    }

    /// The screen reads the room again each time it comes back to the front; a read that fails then does not turn a room the
    /// person is looking at into an error.
    func testAReloadThatFailsLeavesAnOpenRoomOpen() async {
        let counter = ReadCounter()
        let transport = MockTransport(routes: [
            MockRoute(.get, "/api/rooms/r1") { _ in
                counter.bump() == 1 ? RoomJSON.answer(RoomJSON.json()) : RoomJSON.answer(status: 503, #"{"error":"down"}"#)
            },
        ])
        let (model, _) = make(transport)
        await model.load()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertTrue(model.messages.isEmpty, "an empty room: nothing said yet")
        await model.load()
        XCTAssertEqual(model.phase, .ready)
    }

    /// A room deleted on another device answers 404 for good; the screen says so. A server in the middle of a deploy
    /// answers one too, and the room is open again when it answers properly, with what was said before still there.
    func testARoomThatIsGoneIsSaidSoAndOpensAgainWhenItAnswers() async {
        let counter = ReadCounter()
        let transport = MockTransport(routes: [
            MockRoute(.get, "/api/rooms/r1") { _ in
                switch counter.bump() {
                case 1: return RoomJSON.answer(RoomJSON.json(messages: [RoomJSON.message("x1", 0, "human", nil)]))
                case 2...4: return RoomJSON.answer(status: 404, #"{"error":"Room not found."}"#)
                default: return RoomJSON.answer(RoomJSON.json(messages: [RoomJSON.message("x1", 0, "human", nil), RoomJSON.message("x2", 1, "agent", "claude")]))
                }
            },
        ])
        let (model, _) = make(transport)
        await model.load()
        XCTAssertEqual(model.phase, .ready)
        let following = Task { await model.follow() }
        await eventually("the room to be called gone") {
            if case .failed = model.phase { return true }
            return false
        }
        XCTAssertEqual(model.messages.count, 1, "what was said is kept")
        await eventually("the room to open again") { model.phase == .ready && model.messages.count == 2 }
        XCTAssertEqual(model.messages.map(\.id), ["x1", "x2"], "the read after the gap added to the thread and did not replace it")
        following.cancel()
    }

    // MARK: What a message that did not get through says

    /// The server refused the post: it says why, in its own words, and the message goes back into a fresh box.
    func testAMessageTheServerRefusedComesBackIntoTheBox() async {
        let transport = MockTransport(routes: [
            .json(.get, "/api/rooms/r1", RoomJSON.json()),
            .failure(.post, "/api/rooms/r1/messages", status: 503, message: "The database is missing agent-room support."),
        ])
        let (model, _) = make(transport)
        await model.load()
        let start = model.composerEpoch
        model.draft = "hello"
        model.send()
        XCTAssertEqual(model.outgoing.map(\.text), ["hello"], "in the thread while it travels")
        await eventually("the request to have ended") { !model.isDriving }
        XCTAssertEqual(model.draft, "hello")
        XCTAssertEqual(model.composerEpoch, start &+ 2, "once when it was sent and once when it was given back")
        XCTAssertTrue(model.outgoing.isEmpty)
        XCTAssertEqual(model.notice, "The database is missing agent-room support.")
        XCTAssertTrue(model.messages.isEmpty)
    }

    /// The post never left the phone and the room can be read: it was not sent, and the notice says that.
    func testAMessageThatNeverLeftThePhoneIsSaidNotToBeSent() async {
        let server = FakeRoomServer(style: .queued)
        let network = RoomTestNetwork(server)
        network.drop("POST /api/rooms/r1/messages")
        let (model, _) = make(network)
        await model.load()
        model.draft = "hello"
        model.send()
        await eventually("the request to have ended") { !model.isDriving }
        XCTAssertEqual(model.draft, "hello")
        XCTAssertEqual(model.notice, "Network hiccup. Your message was not sent. Try again.")
        XCTAssertTrue(model.messages.isEmpty)
        let held = await server.positions
        XCTAssertEqual(held, [])
    }

    /// Neither the post nor the read got through: the phone cannot say, so it says that, and the words are not lost.
    func testAMessageWhoseFateIsNotKnownComesBackWithANoticeThatSaysSo() async {
        let server = FakeRoomServer(style: .queued)
        let network = RoomTestNetwork(server)
        let (model, _) = make(network)
        await model.load()
        network.goOffline()
        model.draft = "hello"
        model.send()
        await eventually("the request to have ended") { !model.isDriving }
        XCTAssertEqual(model.draft, "hello")
        XCTAssertTrue(model.outgoing.isEmpty)
        XCTAssertEqual(model.notice, "Network hiccup. Your message may not have been sent. Check the room, then try again.")
    }

    /// The message is in the room and the run that should answer it failed: not a lost message, and Continue is offered.
    func testAMessageThatArrivedIsNeverPutBackWhateverHappenedToTheRun() async {
        let server = FakeRoomServer(style: .queued, turnSeconds: 0.01)
        let network = RoomTestNetwork(server)
        network.drop("POST /api/rooms/r1/run")
        let (model, _) = make(network)
        await model.load()
        model.draft = "introduce yourselves"
        model.send()
        await eventually("the request to have ended") { !model.isDriving }
        XCTAssertEqual(model.draft, "", "the message is in the room")
        XCTAssertEqual(model.messages.map(\.senderKind), [.human])
        XCTAssertTrue(model.outgoing.isEmpty)
        XCTAssertEqual(model.notice, "Network hiccup. Check the room for what it has said.")
        XCTAssertTrue(model.canContinue, "the turns are still queued, and nobody is running them")
        XCTAssertEqual(model.pending.map(\.handle), ["claude", "custom"])
    }

    /// Stop ends the request the way the system does: it throws. The message may be in the room all the same, and the
    /// phone looks (in a task of its own, since this one is cancelled and could not ask) before putting words back.
    func testStopDoesNotPutBackAMessageTheRoomHas() async {
        let server = FakeRoomServer(style: .legacy, turnSeconds: 0.01)
        await server.holdTurn(1)
        let network = RoomTestNetwork(server)
        let (model, _) = make(network)
        await model.load()
        model.draft = "introduce yourselves"
        model.send()
        await waitForATurn(on: server)
        model.stop()
        await server.releaseTurn()
        await eventually("the request to have ended") { !model.isDriving }
        XCTAssertEqual(model.notice, "Stopped. Turns still waiting will stay queued.")
        XCTAssertEqual(model.draft, "", "the room has the message; it does not come back")
        XCTAssertEqual(model.messages.first?.senderKind, .human)
        XCTAssertTrue(model.outgoing.isEmpty)
    }

    func testStopBeforeTheMessageGotThereGivesItBack() async {
        let server = FakeRoomServer(style: .queued)
        let network = RoomTestNetwork(server)
        network.hold("POST /api/rooms/r1/messages")
        let (model, _) = make(network)
        await model.load()
        model.draft = "hello"
        model.send()
        model.stop()
        network.release()
        await eventually("the request to have ended") { !model.isDriving }
        XCTAssertEqual(model.notice, "Stopped. Turns still waiting will stay queued.")
        XCTAssertEqual(model.draft, "hello")
        XCTAssertTrue(model.messages.isEmpty)
    }

    // MARK: What the person did here, and a read that is older than it

    func testAReadThatRepeatsTheOldNameDoesNotUndoARename() async throws {
        let transport = MockTransport(routes: [
            .json(.get, "/api/rooms/r1", RoomJSON.json(title: "Old")),
            .json(.patch, "/api/rooms/r1", "{}"),
        ])
        let (model, _) = make(transport)
        await model.load()
        try await model.rename(to: "New")
        XCTAssertEqual(model.title, "New")
        // A read that was answered before the rename got there still says "Old".
        await model.refresh()
        XCTAssertEqual(model.title, "New")
        // The server's own change of name, later, is taken.
        await transport.add(.json(.get, "/api/rooms/r1", RoomJSON.json(title: "Newer")))
        await model.refresh()
        XCTAssertEqual(model.title, "Newer")
    }

    func testARenameTheServerRefusedGivesTheNameBackAndKeepsTheRest() async throws {
        let transport = MockTransport(routes: [
            .json(.get, "/api/rooms/r1", RoomJSON.json(title: "Old", pending: ["claude"])),
            .failure(.patch, "/api/rooms/r1", status: 403, message: "Not yours to rename."),
        ])
        let (model, _) = make(transport)
        await model.load()
        do {
            try await model.rename(to: "New")
            XCTFail("the server refused")
        } catch {
            XCTAssertEqual((error as? ChatActionError)?.message, "Not yours to rename.")
        }
        XCTAssertEqual(model.title, "Old")
        XCTAssertEqual(model.pending.map(\.handle), ["claude"])
    }

    func testAReadThatStillListsAMemberTakenOutDoesNotBringThemBack() async throws {
        let both = RoomJSON.json(members: [RoomJSON.member("m1", "claude", 0), RoomJSON.member("m2", "custom", 1)])
        let transport = MockTransport(routes: [
            .json(.get, "/api/rooms/r1", both),
            .json(.delete, "/api/rooms/r1/members", "{}"),
        ])
        let (model, _) = make(transport)
        await model.load()
        XCTAssertEqual(model.members.map(\.handle), ["claude", "custom"])
        try await model.remove(try XCTUnwrap(model.members.last))
        XCTAssertEqual(model.members.map(\.handle), ["claude"])
        await model.refresh()
        XCTAssertEqual(model.members.map(\.handle), ["claude"], "an older read of the roster")
        // The roster the server reports next is taken as it is.
        await transport.add(.json(.get, "/api/rooms/r1", RoomJSON.json(members: [RoomJSON.member("m1", "claude", 0), RoomJSON.member("m3", "gpt", 1)])))
        await model.refresh()
        XCTAssertEqual(model.members.map(\.handle), ["claude", "gpt"])
    }
}

// MARK: Test support

/// The canned JSON of a room read, in the shape the server sends.
private enum RoomJSON {
    static func json(
        title: String = "All hands", pending: [String] = [], running: Bool = false,
        members: [String] = [], messages: [String] = []
    ) -> String {
        let queued = pending.map { #"{"handle":"\#($0)","reason":""}"# }.joined(separator: ",")
        return #"{"room":{"id":"r1","title":"\#(title)","pending":[\#(queued)],"budget":12,"running":\#(running)},"members":[\#(members.joined(separator: ","))],"messages":[\#(messages.joined(separator: ","))]}"#
    }

    static func member(_ id: String, _ handle: String, _ position: Int) -> String {
        #"{"id":"\#(id)","room_id":"r1","backend_id":"b\#(position)","handle":"\#(handle)","role_brief":"","position":\#(position),"backend":{"name":"\#(handle)","provider":"custom","default_model":"minimax-m3"}}"#
    }

    static func message(_ id: String, _ position: Int, _ kind: String, _ handle: String?) -> String {
        let handleValue = handle.map { "\"\($0)\"" } ?? "null"
        return #"{"id":"\#(id)","room_id":"r1","position":\#(position),"sender_kind":"\#(kind)","sender_handle":\#(handleValue),"member_id":null,"content":"Words.","mentions":[],"tool_turns":[],"model":null,"status":"complete","created_at":"2026-10-25T10:00:00Z"}"#
    }

    static func answer(status: Int = 200, _ body: String) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["content-type": "application/json"], data: Data(body.utf8))
    }
}

/// A count a mock route can bump from any thread.
private final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func bump() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}

/// The network between the phone and a fake room: a request can be dropped before it gets there or held on its way, and
/// the phone can go offline. (An answer lost after the server carried the request out is `FakeRoomServer.Failure`'s.) A
/// request that is cancelled while the server has it throws when the server lets go of it, as the system's does.
private final class RoomTestNetwork: HTTPTransport, @unchecked Sendable {
    private let inner: FakeRoomTransport
    private let lock = NSLock()
    private var offline = false
    private var dropped: Set<String> = []
    private var held: Set<String> = []

    init(_ server: FakeRoomServer) {
        inner = FakeRoomTransport(server: server)
    }

    /// Requests like `"POST /api/rooms/r1/run"` never reach the server.
    func drop(_ request: String) { change { dropped.insert(request) } }
    /// Requests like this wait until `release()`.
    func hold(_ request: String) { change { held.insert(request) } }
    func release() { change { held.removeAll() } }
    func goOffline() { change { offline = true } }

    private func change(_ edit: () -> Void) {
        lock.lock()
        edit()
        lock.unlock()
    }

    private func plan(for key: String) -> (offline: Bool, dropped: Bool, held: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (offline, dropped.contains(key), held.contains(key))
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let key = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
        var now = plan(for: key)
        if now.offline || now.dropped { throw URLError(.notConnectedToInternet) }
        while now.held {
            try await Task.sleep(nanoseconds: 2_000_000)
            now = plan(for: key)
        }
        let response = try await inner.send(request)
        try Task.checkCancellation()
        return response
    }
}
