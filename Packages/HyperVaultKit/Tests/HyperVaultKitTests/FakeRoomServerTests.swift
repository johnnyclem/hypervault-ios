import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

/// The stateful room that the other room tests stand on speaks the server's shapes (docs/rooms.md) and behaves the way
/// the two servers do: what a post and a run answer, what a read reports, what a dead run leaves behind.
final class FakeRoomServerTests: RoomTestCase {
    func api(_ server: FakeRoomServer) -> HVClient {
        client(FakeRoomTransport(server: server))
    }

    // MARK: the server as it was

    func testAnOldServerRunsTheRoundBeforeItAnswersAndIgnoresWhatItDoesNotKnow() async throws {
        let server = FakeRoomServer(style: .legacy, turnSeconds: 0.001)
        let run = try await api(server).send(.postRoomMessage(roomID: "r1", content: "hello", run: false))
        XCTAssertEqual(run.messages.map(\.senderKind), [.human, .agent, .agent], "run: false is ignored")
        XCTAssertEqual(run.messages.compactMap(\.senderHandle), ["claude", "custom"])
        XCTAssertTrue(run.pending.isEmpty)
        XCTAssertNil(run.current, "an old server does not say whose turn it is")
        let room = try await api(server).send(.room(id: "r1")).room
        XCTAssertNil(room.current)
        XCTAssertFalse(room.running)
        XCTAssertEqual(room.budget, 10)
    }

    func testAnOldServersRunIgnoresHowManyTurnsAreAskedFor() async throws {
        let server = FakeRoomServer(handles: ["a", "b", "c", "d"], style: .legacy, turnSeconds: 0.001)
        // A post that runs three turns leaves the fourth queued.
        let first = try await api(server).send(.postRoomMessage(roomID: "r1", content: "hello"))
        XCTAssertEqual(first.pending.map(\.handle), ["d"])
        let run = try await api(server).send(.runRoom(id: "r1", turns: 1))
        XCTAssertEqual(run.messages.compactMap(\.senderHandle), ["d"])
    }

    func testAnOldServerKeepsSayingRunningForARunThatDiedAndForgetsItsTurn() async throws {
        let server = FakeRoomServer(style: .legacy, turnSeconds: 0.001)
        await server.set(failure: .init(dieDuringTurn: 1))
        let api = api(server)
        do {
            _ = try await api.send(.postRoomMessage(roomID: "r1", content: "hello"))
            XCTFail("the run died")
        } catch let error as HVError { XCTAssertEqual(error.status, 504) }
        await server.lapseLease()
        let room = try await api.send(.room(id: "r1")).room
        XCTAssertTrue(room.running, "the flag only ever said a lease had been written")
        XCTAssertNil(room.current)
        let run = try await api.send(.runRoom(id: "r1"))
        XCTAssertFalse(run.busy, "a lapsed lease can be taken over")
        XCTAssertEqual(run.messages.compactMap(\.senderHandle), ["custom"], "claude's turn is gone, without a word")
    }

    // MARK: the server that queues

    func testAPostWithoutRunningAnswersAtOnceWithTheQueue() async throws {
        let server = FakeRoomServer(style: .queued)
        let run = try await api(server).send(.postRoomMessage(roomID: "r1", content: "hello", run: false))
        XCTAssertEqual(run.messages.map(\.senderKind), [.human])
        XCTAssertEqual(run.pending.map(\.handle), ["claude", "custom"])
        XCTAssertEqual(run.budget, 12)
        XCTAssertFalse(run.busy)
        XCTAssertNil(run.current)
        let positions = await server.positions
        XCTAssertEqual(positions, [0])
    }

    func testAPostThatDoesNotSayNotToRunStillRunsTheTurnsFirst() async throws {
        let server = FakeRoomServer(style: .queued, turnSeconds: 0.001)
        let run = try await api(server).send(.postRoomMessage(roomID: "r1", content: "hello"))
        XCTAssertEqual(run.messages.map(\.senderKind), [.human, .agent, .agent])
    }

    func testARunTakesAsManyTurnsAsItIsAskedForUpToThree() async throws {
        let server = FakeRoomServer(handles: ["a", "b", "c", "d", "e"], style: .queued, turnSeconds: 0.001)
        let api = api(server)
        _ = try await api.send(.postRoomMessage(roomID: "r1", content: "hello", run: false))
        let one = try await api.send(.runRoom(id: "r1", turns: 1))
        XCTAssertEqual(one.messages.compactMap(\.senderHandle), ["a"])
        XCTAssertEqual(one.pending.map(\.handle), ["b", "c", "d", "e"])
        let two = try await api.send(.runRoom(id: "r1", turns: 2))
        XCTAssertEqual(two.messages.compactMap(\.senderHandle), ["b", "c"])
        let most = try await api.send(.runRoom(id: "r1", turns: 9))
        XCTAssertEqual(most.messages.compactMap(\.senderHandle), ["d", "e"])
        XCTAssertTrue(most.pending.isEmpty)
        let nothing = try await api.send(.runRoom(id: "r1"))
        XCTAssertTrue(nothing.messages.isEmpty)
        XCTAssertFalse(nothing.busy)
    }

    func testATurnInFlightIsReportedAndHoldsTheRoom() async throws {
        let server = FakeRoomServer(style: .queued, turnSeconds: 0.001)
        await server.holdTurn(1)
        let api = api(server)
        _ = try await api.send(.postRoomMessage(roomID: "r1", content: "hello", run: false))
        let running = Task { try await api.send(.runRoom(id: "r1", turns: 1)) }
        await eventually("claude's turn to start") { await server.turnsInFlight == "claude" }

        let room = try await api.send(.room(id: "r1")).room
        XCTAssertTrue(room.running)
        XCTAssertEqual(room.current?.handle, "claude")
        XCTAssertNotNil(room.current?.startedAt)
        XCTAssertEqual(room.pending.map(\.handle), ["custom"], "the turn in flight has left the queue")
        let second = try await api.send(.runRoom(id: "r1", turns: 1))
        XCTAssertTrue(second.busy, "a live run holds the room")
        XCTAssertEqual(second.current?.handle, "claude")

        await server.releaseTurn()
        let done = try await running.value
        XCTAssertEqual(done.messages.compactMap(\.senderHandle), ["claude"])
        XCTAssertNil(done.current)
        let after = try await api.send(.room(id: "r1")).room
        XCTAssertFalse(after.running)
        XCTAssertNil(after.current)
    }

    func testARunThatDiesLeavesAFreshLeaseThenALostTurnThatTheNextPostWritesDown() async throws {
        let server = FakeRoomServer(style: .queued, turnSeconds: 0.001)
        await server.set(failure: .init(dieDuringTurn: 1))
        let api = api(server)
        _ = try await api.send(.postRoomMessage(roomID: "r1", content: "hello", run: false))
        do {
            _ = try await api.send(.runRoom(id: "r1", turns: 1))
            XCTFail("the run died")
        } catch let error as HVError { XCTAssertEqual(error.status, 504) }

        var room = try await api.send(.room(id: "r1")).room
        XCTAssertTrue(room.running, "the lease has not run out")
        XCTAssertEqual(room.current?.handle, "claude")
        let busy = try await api.send(.runRoom(id: "r1", turns: 1))
        XCTAssertTrue(busy.busy)

        await server.lapseLease()
        room = try await api.send(.room(id: "r1")).room
        XCTAssertFalse(room.running)
        XCTAssertEqual(room.current?.handle, "claude", "not running, a turn in flight: it was lost")
        XCTAssertTrue(room.canBeContinued)

        // The note is written before the person's words, where the turn was lost.
        let next = try await api.send(.postRoomMessage(roomID: "r1", content: "again", run: false))
        XCTAssertEqual(next.messages.map(\.senderKind), [.system, .human])
        XCTAssertTrue(next.messages[0].content.contains("@claude"))
        XCTAssertNil(next.current)
        XCTAssertEqual(next.pending.map(\.handle), ["custom", "claude"], "what was already waiting keeps its place; nobody is queued twice")
    }

    func testAPostNamingAMemberQueuesOnlyThatMember() async throws {
        let server = FakeRoomServer(style: .queued)
        let run = try await api(server).send(.postRoomMessage(roomID: "r1", content: "@custom what do you think?", run: false))
        XCTAssertEqual(run.pending.map(\.handle), ["custom"])
        XCTAssertEqual(run.messages.first?.mentions, ["custom"])
    }

    // MARK: reading

    func testAReadPastAPositionReturnsOnlyWhatCameAfter() async throws {
        let server = FakeRoomServer(style: .queued)
        for index in 0..<4 { await server.speak("note \(index)") }
        let api = api(server)
        func positions(after: Int? = nil) async throws -> [Int] {
            try await api.send(.room(id: "r1", after: after)).messages.map(\.position)
        }
        let whole = try await positions()
        let past1 = try await positions(after: 1)
        let past3 = try await positions(after: 3)
        let fromBefore = try await positions(after: -1)
        XCTAssertEqual(whole, [0, 1, 2, 3])
        XCTAssertEqual(past1, [2, 3])
        XCTAssertEqual(past3, [])
        XCTAssertEqual(fromBefore, [0, 1, 2, 3])
    }

    func testReadsFailTheNumberOfTimesATestAsksForAndThenWork() async throws {
        let server = FakeRoomServer(style: .queued)
        await server.set(failure: .init(failReads: 2))
        let api = api(server)
        for _ in 0..<2 {
            do {
                _ = try await api.send(.room(id: "r1"))
                XCTFail("a busy database")
            } catch let error as HVError { XCTAssertEqual(error.status, 503) }
        }
        let room = try await api.send(.room(id: "r1")).room
        XCTAssertEqual(room.title, "All hands")
    }

    func testAnAnswerThatIsLostOnTheWayIsAThrownConnectionErrorAndTheWorkGoesOn() async throws {
        let server = FakeRoomServer(style: .legacy, turnSeconds: 0.001)
        await server.set(failure: .init(losePostAnswer: true))
        let api = api(server)
        do {
            _ = try await api.send(.postRoomMessage(roomID: "r1", content: "hello"))
            XCTFail("the answer was lost")
        } catch let error as HVError { XCTAssertTrue(error.isOffline, "\(error)") }
        await eventually("the round to be written all the same") { await server.agentCount == 2 }
    }

    func testTheRequestsSeenAreRecordedWithTheirQueries() async throws {
        let server = FakeRoomServer(style: .queued)
        let api = api(server)
        _ = try await api.send(.room(id: "r1", after: 3))
        _ = try await api.send(.runRoom(id: "r1", turns: 1))
        let seen = await server.requests
        XCTAssertEqual(seen, ["GET /api/rooms/r1?after=3", "POST /api/rooms/r1/run?turns=1"])
    }

    func testAnUnknownRouteIsA404() async throws {
        let server = FakeRoomServer()
        do {
            _ = try await api(server).send(Endpoint<NoContent>(.get, "/api/rooms/other"))
            XCTFail("no such room")
        } catch let error as HVError { XCTAssertTrue(error.isNotFound) }
    }
}
