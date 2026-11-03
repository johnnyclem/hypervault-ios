import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

/// What a screen holds, kept the way the room model keeps it (a transcript fed by reads, posts and runs; a header from
/// the last of them), so the rounds below can ask what the person would see. It is not the app's model: that is
/// `Tests/AppTests/RoomModelTests.swift`.
final class RoomScreenProbe: @unchecked Sendable {
    struct Seen {
        var transcript = ChatRoomTranscript()
        var header: ChatRoomHeader?
        /// Set while the phone is driving a round or the person's message is travelling: the follower asks quickly.
        var moving = false
        /// Every distinct line the person would have read under the thread, in order.
        var lines: [String] = []
        /// What each post or run carried, in the order the driver heard it (whether or not a read had shown it already).
        var progress: [[String]] = []
    }

    private let lock = NSLock()
    private var seen = Seen()

    var snapshot: Seen { lock.lock(); defer { lock.unlock() }; return seen }
    var positions: [Int] { snapshot.transcript.messages.map(\.position) }
    var activity: ChatRoomActivity { ChatRoomActivity.resolve(header: snapshot.header, sending: false) }

    func setMoving(_ moving: Bool) { lock.lock(); seen.moving = moving; lock.unlock() }

    func state() -> ChatRoomFollowState {
        lock.lock(); defer { lock.unlock() }
        return ChatRoomFollowState(cursor: seen.transcript.cursor, isActive: seen.moving || seen.header?.running == true)
    }

    /// A read of the room.
    func apply(_ detail: ChatRoomDetail) {
        lock.lock(); defer { lock.unlock() }
        seen.transcript.apply(detail)
        seen.header = detail.room
        note()
    }

    /// The answer to a post or a run.
    func apply(_ run: ChatRoomRun) {
        lock.lock(); defer { lock.unlock() }
        seen.progress.append(run.messages.map { $0.senderHandle ?? $0.senderKind.rawValue })
        seen.transcript.merge(run.messages)
        if var header = seen.header {
            header.pending = run.pending
            header.budget = run.budget
            header.running = run.busy
            header.current = run.current
            seen.header = header
            note()
        }
    }

    private func note() {
        guard let line = ChatRoomActivity.resolve(header: seen.header, sending: false).line(now: Date()), seen.lines.last != line else { return }
        seen.lines.append(line)
    }

    /// Follows the room for as long as the returned task lives.
    func follow(_ client: HVClient, pace: ChatRoomPace) -> Task<Void, Never> {
        let follower = ChatRoomFollower(client: client, roomID: "r1", pace: pace)
        return Task {
            await follower.follow(state: { self.state() }, onSnapshot: { self.apply($0) })
        }
    }
}

/// Whole rounds against a stateful room: the screen follows the server whatever became of the request that set the
/// round off. These are the cases of "in a new room the first reply never shows until the second message".
final class RoomRoundTests: RoomTestCase {
    func client(_ server: FakeRoomServer) -> HVClient {
        HVClient(baseURL: base, transport: FakeRoomTransport(server: server), tokens: StaticTokenProvider(), retry: .none, sleep: { _ in })
    }

    /// Asks every 10 ms while a round moves, and notices within 5 ms that one started.
    let quick = ChatRoomPace(
        schedule: ChatRoomPollSchedule(active: [0.01], idle: 0.02, failureCeiling: 0.02), tick: 0.005, busySteps: [0.01],
        sleep: ChatRoomPace.realSleep
    )

    // MARK: the server as it is today

    /// The bug itself: the post runs the whole round before it answers, and the old screen asked for nothing meanwhile.
    func testAnOldServersFirstReplyShowsWhileThePostIsStillOpen() async throws {
        let server = FakeRoomServer(style: .legacy, turnSeconds: 0.01)
        await server.holdTurn(2)
        let api = client(server)
        let probe = RoomScreenProbe()
        let following = probe.follow(api, pace: quick)
        probe.setMoving(true)
        let finished = TestBox<ChatRoomDriver.Outcome?>(nil)
        let driver = ChatRoomDriver(client: api, roomID: "r1", pace: quick)
        let driving = Task {
            let outcome = try await driver.send("introduce yourselves") { probe.apply($0) }
            finished.value = outcome
            probe.setMoving(false)
        }

        // Turn 2 is held, so the post cannot have answered. The first reply must already be on the screen.
        await eventually("the first reply on screen") { probe.snapshot.transcript.messages.contains { $0.senderHandle == "claude" } }
        XCTAssertNil(finished.value, "the post is still open")
        XCTAssertEqual(probe.positions, [0, 1], "the person's message and the first answer")
        // The old server does not say whose turn it is, only that the room is at work.
        await eventually("the room shown as working") { probe.activity == .working }
        let whileOpen = await server.requests
        XCTAssertEqual(whileOpen.filter { $0.hasPrefix("POST") }, ["POST /api/rooms/r1/messages"])

        await server.releaseTurn()
        await eventually("the round to end") { finished.value != nil }
        XCTAssertEqual(finished.value, .finished)
        following.cancel()
        let everything = await server.requests
        XCTAssertEqual(everything.filter { $0.hasPrefix("POST") }, ["POST /api/rooms/r1/messages"], "the post answered the whole round; nothing to run")
        XCTAssertEqual(probe.positions, [0, 1, 2])
        _ = try await driving.value
    }

    /// The post ran its turns and the phone never heard back. The server has the round; the screen must too.
    func testALostAnswerToThePostStillLeavesEverythingOnScreen() async throws {
        let server = FakeRoomServer(style: .legacy, turnSeconds: 0.01)
        await server.set(failure: .init(losePostAnswer: true))
        let api = client(server)
        let probe = RoomScreenProbe()
        let following = probe.follow(api, pace: quick)
        probe.setMoving(true)
        let driver = ChatRoomDriver(client: api, roomID: "r1", pace: quick)
        do {
            _ = try await driver.send("introduce yourselves") { probe.apply($0) }
            XCTFail("the answer was lost on the way")
        } catch let error as HVError {
            XCTAssertTrue(error.isOffline, "the phone sees a dropped connection: \(error)")
        }
        await eventually("every message the server wrote") { probe.positions == [0, 1, 2] }
        following.cancel()
        XCTAssertEqual(probe.snapshot.transcript.cursor, 2)
    }

    /// A run died in the middle of a turn, the person said it again, and the second run answered both. The old
    /// screen polled from the highest position it held and never fetched the answer written before the run died.
    func testARoundThatDiesAndIsSaidAgainEndsWithEverythingOnScreen() async throws {
        let server = FakeRoomServer(style: .legacy, turnSeconds: 0.01)
        await server.set(failure: .init(dieDuringTurn: 2))
        let api = client(server)
        let probe = RoomScreenProbe()
        let following = probe.follow(api, pace: quick)
        probe.setMoving(true)
        let first = ChatRoomDriver(client: api, roomID: "r1", pace: quick)
        do {
            _ = try await first.send("first") { probe.apply($0) }
            XCTFail("the run died")
        } catch let error as HVError {
            XCTAssertEqual(error.status, 504)
        }
        // The lease of the dead run lapses while the person's second message waits for the room.
        let second = ChatRoomDriver(
            client: api, roomID: "r1",
            pace: ChatRoomPace(schedule: quick.schedule, tick: quick.tick, busySteps: [0.01], sleep: { _ in await server.lapseLease() })
        )
        let outcome = try await second.send("again") { probe.apply($0) }
        XCTAssertEqual(outcome, .finished)
        await eventually("the screen to hold what the server holds") { await probe.positions == server.positions }
        following.cancel()
        let held = await server.positions
        XCTAssertEqual(held, [0, 1, 2, 3, 4], "first, claude's answer to it, again, then claude and custom")
        XCTAssertEqual(probe.positions, held, "position 1 was written before the run died and must not be stepped over")
    }

    /// The same death, with the screen not reading while it happened (the app was in the background, or the follower
    /// was between two asks): what the posts and runs brought is shown, and the next read must still return what they
    /// did not, including the answer written before the run died.
    func testTheNextReadFetchesWhatThePostsAndRunsStepOver() async throws {
        let server = FakeRoomServer(style: .legacy, turnSeconds: 0.01)
        let api = client(server)
        let probe = RoomScreenProbe()
        // The screen opens on the empty room.
        probe.apply(try await api.send(.room(id: "r1")))
        XCTAssertEqual(probe.snapshot.transcript.cursor, -1)

        await server.set(failure: .init(dieDuringTurn: 2))
        let first = ChatRoomDriver(client: api, roomID: "r1", pace: quick)
        do {
            _ = try await first.send("first") { probe.apply($0) }
            XCTFail("the run died")
        } catch let error as HVError {
            XCTAssertEqual(error.status, 504)
        }
        XCTAssertEqual(probe.positions, [], "the post never answered, so the person's words are not shown from it")
        let second = ChatRoomDriver(
            client: api, roomID: "r1",
            pace: ChatRoomPace(schedule: quick.schedule, tick: quick.tick, busySteps: [0.01], sleep: { _ in await server.lapseLease() })
        )
        _ = try await second.send("again") { probe.apply($0) }
        XCTAssertEqual(probe.positions, [2, 3, 4], "what the second post and its run brought")
        XCTAssertEqual(probe.snapshot.transcript.cursor, -1, "posts and runs never move the place the next read starts from")

        probe.apply(try await api.send(.room(id: "r1", after: probe.snapshot.transcript.cursor)))
        let held = await server.positions
        XCTAssertEqual(held, [0, 1, 2, 3, 4])
        XCTAssertEqual(probe.positions, held)
        XCTAssertEqual(probe.snapshot.transcript.cursor, 4)
    }

    // MARK: the server that queues

    /// Each answer comes back on its own request, and between them the screen says who is thinking.
    func testANewServerAnswersOneTurnPerRequestAndTheLineNamesWhoIsThinking() async throws {
        let server = FakeRoomServer(style: .queued, turnSeconds: 0.01)
        await server.holdTurn(2)
        let api = client(server)
        let probe = RoomScreenProbe()
        let following = probe.follow(api, pace: quick)
        probe.setMoving(true)
        let finished = TestBox<ChatRoomDriver.Outcome?>(nil)
        let driver = ChatRoomDriver(client: api, roomID: "r1", pace: quick)
        let driving = Task {
            finished.value = try await driver.send("introduce yourselves") { probe.apply($0) }
            probe.setMoving(false)
        }

        await eventually("custom shown as thinking") {
            if case .thinking(let handle, _, _) = probe.activity { return handle == "custom" }
            return false
        }
        XCTAssertNil(finished.value)
        XCTAssertEqual(probe.positions, [0, 1])
        XCTAssertEqual(probe.snapshot.progress, [["human"], ["claude"]], "the post answered at once with the person's words; claude's turn came back alone")

        await server.releaseTurn()
        await eventually("the round to end") { finished.value != nil }
        following.cancel()
        _ = try await driving.value
        XCTAssertEqual(finished.value, .finished)
        XCTAssertEqual(probe.positions, [0, 1, 2])
        XCTAssertEqual(probe.snapshot.progress, [["human"], ["claude"], ["custom"]])
        let requests = await server.requests
        XCTAssertEqual(requests.filter { $0.hasPrefix("POST") }, [
            "POST /api/rooms/r1/messages", "POST /api/rooms/r1/run?turns=1", "POST /api/rooms/r1/run?turns=1",
        ])
        let lines = probe.snapshot.lines
        XCTAssertTrue(lines.contains { $0.hasPrefix("@custom is thinking...") }, "lines the person read: \(lines)")
        XCTAssertFalse(lines.contains { $0.hasPrefix("@custom is thinking...") && lines.first == $0 }, "never named custom first: claude had the turn")
    }

    /// A run that dies leaves the room looking busy until its lease runs out; then the person is told the turn was
    /// cut off, can continue, and the note the server writes arrives like any message.
    func testADeadRunReadsAsThinkingUntilItsLeaseLapsesThenAsCutOffAndContinueRecordsIt() async throws {
        let server = FakeRoomServer(style: .queued, turnSeconds: 0.01)
        await server.set(failure: .init(dieDuringTurn: 2))
        let api = client(server)
        let probe = RoomScreenProbe()
        let following = probe.follow(api, pace: quick)
        probe.setMoving(true)
        let driver = ChatRoomDriver(client: api, roomID: "r1", pace: quick)
        do {
            _ = try await driver.send("introduce yourselves") { probe.apply($0) }
            XCTFail("the run died")
        } catch let error as HVError {
            XCTAssertEqual(error.status, 504)
        }
        probe.setMoving(false)
        await eventually("custom still shown as thinking: its lease has not lapsed") {
            if case .thinking(let handle, _, _) = probe.activity { return handle == "custom" }
            return false
        }
        XCTAssertFalse(probe.snapshot.header?.canBeContinued ?? true)

        await server.lapseLease()
        await eventually("the turn shown as cut off") { probe.activity == .cutOff(handle: "custom") }
        XCTAssertTrue(probe.snapshot.header?.canBeContinued ?? false)

        // Nothing continues by itself: the person presses Continue.
        let before = await server.requests.filter { $0.hasPrefix("POST") }.count
        try await Task.sleep(nanoseconds: 100_000_000)
        let after = await server.requests.filter { $0.hasPrefix("POST") }.count
        XCTAssertEqual(before, after, "the follower reads; it never drives")

        probe.setMoving(true)
        let outcome = try await driver.resume { probe.apply($0) }
        XCTAssertEqual(outcome, .finished)
        probe.setMoving(false)
        await eventually("the note on screen and the line gone") { await probe.positions == server.positions && probe.activity == .idle }
        following.cancel()
        let note = probe.snapshot.transcript.messages.last
        XCTAssertEqual(note?.senderKind, .system)
        XCTAssertTrue(note?.content.contains("@custom") ?? false)
    }

    /// Leaving the screen mid-round: the screen's tasks end, the server finishes the turn it has in flight, and the
    /// rest stays queued for Continue. Nothing runs it behind the person's back.
    func testLeavingTheScreenLeavesTheRestOfTheRoundQueuedForContinue() async throws {
        let server = FakeRoomServer(style: .queued, turnSeconds: 0.01)
        await server.holdTurn(1)
        let api = client(server)
        let probe = RoomScreenProbe()
        let following = probe.follow(api, pace: quick)
        probe.setMoving(true)
        let driver = ChatRoomDriver(client: api, roomID: "r1", pace: quick)
        let driving = Task { try await driver.send("introduce yourselves") { probe.apply($0) } }
        await eventually("claude shown as thinking, custom waiting") {
            if case .thinking(let handle, _, let then) = probe.activity { return handle == "claude" && then == ["custom"] }
            return false
        }

        // The person leaves: SwiftUI cancels the screen's tasks.
        driving.cancel()
        following.cancel()
        await server.releaseTurn()
        do {
            _ = try await driving.value
            XCTFail("a cancelled drive says so")
        } catch {
            XCTAssertEqual(error as? HVError, .cancelled)
        }
        await eventually("the turn in flight to be written") { await server.agentCount == 1 }
        try await Task.sleep(nanoseconds: 100_000_000)
        let queued = await server.queued
        XCTAssertEqual(queued, ["custom"], "the second turn waits")
        let runs = await server.requests.filter { $0.contains("/run") }.count
        XCTAssertEqual(runs, 1, "no run was started on the person's behalf after they left")

        // Back in the room: a read says there are turns waiting and nobody running them.
        let reopened = try await api.send(.room(id: "r1"))
        XCTAssertTrue(reopened.room.canBeContinued)
        XCTAssertEqual(ChatRoomActivity.resolve(header: reopened.room, sending: false), .next(handle: "custom", then: []))
        XCTAssertEqual(reopened.messages.map(\.position), [0, 1])
    }

    /// Another device (or an agent holding an API key) speaks while this screen sits quiet.
    func testAMessageFromElsewhereReachesAScreenThatIsOnlyWatching() async throws {
        let server = FakeRoomServer(style: .queued)
        let api = client(server)
        let probe = RoomScreenProbe()
        let following = probe.follow(api, pace: quick)
        await eventually("an opening read") { probe.snapshot.header != nil }
        await server.speak("from my other phone")
        await eventually("the message from the other phone") { probe.positions == [0] }
        following.cancel()
    }

    func testAReadThatFailsWhileTheRoundIsMovingIsRetriedAndNothingIsMissed() async throws {
        let server = FakeRoomServer(style: .queued, turnSeconds: 0.01)
        await server.set(failure: .init(failReads: 3))
        let api = client(server)
        let probe = RoomScreenProbe()
        let following = probe.follow(api, pace: quick)
        probe.setMoving(true)
        let driver = ChatRoomDriver(client: api, roomID: "r1", pace: quick)
        _ = try await driver.send("hello") { probe.apply($0) }
        probe.setMoving(false)
        await eventually("the screen to hold what the server holds") { await probe.positions == server.positions && probe.snapshot.header != nil }
        following.cancel()
        let held = await server.positions
        XCTAssertEqual(held, [0, 1, 2])
    }
}
