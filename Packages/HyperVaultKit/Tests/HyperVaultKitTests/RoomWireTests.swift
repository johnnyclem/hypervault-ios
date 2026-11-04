import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

/// What the server says about the turn in flight, and what the room endpoints send.
final class RoomWireTests: RoomTestCase {
    // MARK: what the server says

    func testTheRoomHeaderReadsTheTurnInFlight() throws {
        let json = #"""
        {"room":{"id":"r1","title":"T","pending":[{"handle":"custom","reason":""}],"budget":11,"running":true,
          "current":{"handle":"claude","reason":"The user spoke to the room.","started_at":"2026-11-03T10:00:01.000Z"}},
         "members":[],"messages":[]}
        """#
        let room = try HVCoding.decoder().decode(ChatRoomDetail.self, from: Data(json.utf8)).room
        XCTAssertEqual(room.current?.handle, "claude")
        XCTAssertEqual(room.current?.reason, "The user spoke to the room.")
        XCTAssertEqual(room.current?.startedAt, HVDate.parse("2026-11-03T10:00:01.000Z"))
        XCTAssertTrue(room.running)
        XCTAssertEqual(room.pending.map(\.handle), ["custom"])
    }

    func testAnOlderServerThatSaysNothingOfTheTurnInFlightStillReads() throws {
        let room = try HVCoding.decoder().decode(ChatRoomDetail.self, from: Data(Self.emptyRoom.utf8)).room
        XCTAssertNil(room.current)
        let nulled = #"{"room":{"id":"r1","title":"T","pending":[],"budget":12,"running":false,"current":null},"members":[],"messages":[]}"#
        XCTAssertNil(try HVCoding.decoder().decode(ChatRoomDetail.self, from: Data(nulled.utf8)).room.current)
    }

    func testATurnTheServerDescribesBadlyCostsTheLineItsNameNotTheRoom() throws {
        let noHandle = #"{"room":{"id":"r1","title":"T","pending":[],"budget":1,"running":true,"current":{"reason":"x"}},"members":[],"messages":[]}"#
        let room = try HVCoding.decoder().decode(ChatRoomDetail.self, from: Data(noHandle.utf8)).room
        XCTAssertNil(room.current)
        XCTAssertTrue(room.running)
        // The server writes an empty time when it did not know it.
        let noTime = #"{"room":{"id":"r1","title":"T","pending":[],"budget":1,"running":true,"current":{"handle":"claude","reason":"","started_at":""}},"members":[],"messages":[]}"#
        let timeless = try HVCoding.decoder().decode(ChatRoomDetail.self, from: Data(noTime.utf8)).room.current
        XCTAssertEqual(timeless?.handle, "claude")
        XCTAssertNil(timeless?.startedAt)
    }

    func testAPostOrARunSaysWhichTurnIsInFlight() throws {
        let queued = #"{"messages":[{"id":"h1","position":0,"sender_kind":"human","content":"hi"}],"pending":[{"handle":"claude","reason":""}],"budget":12,"current":null}"#
        let first = try HVCoding.decoder().decode(ChatRoomRun.self, from: Data(queued.utf8))
        XCTAssertNil(first.current)
        XCTAssertEqual(first.pending.map(\.handle), ["claude"])
        let held = #"{"messages":[],"pending":[],"budget":10,"busy":true,"current":{"handle":"claude","reason":"","started_at":"2026-11-03T10:00:01Z"}}"#
        let busy = try HVCoding.decoder().decode(ChatRoomRun.self, from: Data(held.utf8))
        XCTAssertTrue(busy.busy)
        XCTAssertEqual(busy.current?.handle, "claude")
        let old = try HVCoding.decoder().decode(ChatRoomRun.self, from: Data(#"{"messages":[],"pending":[],"budget":0}"#.utf8))
        XCTAssertNil(old.current)
    }

    // MARK: what the endpoints send

    func testAPostSendsOnlyTheWordsUnlessItAsksNotToRunTheTurns() async throws {
        let transport = MockTransport(routes: [.json(.post, "/api/rooms/r1/messages", #"{"messages":[],"pending":[],"budget":12}"#)])
        let api = client(transport)
        _ = try await api.send(.postRoomMessage(roomID: "r1", content: "hello"))
        _ = try await api.send(.postRoomMessage(roomID: "r1", content: "hello", run: false))
        let sent = await transport.requests.map { requestJSON($0) }
        XCTAssertEqual(sent[0], ["content": .string("hello")], "the body an older server and the web already know")
        XCTAssertEqual(sent[1], ["content": .string("hello"), "run": .bool(false)])
    }

    func testARunAsksForFewerTurnsOnlyWhenTold() async throws {
        let transport = MockTransport(routes: [.json(.post, "/api/rooms/r1/run", #"{"messages":[],"pending":[],"budget":0}"#)])
        let api = client(transport)
        _ = try await api.send(.runRoom(id: "r1"))
        _ = try await api.send(.runRoom(id: "r1", turns: 1))
        _ = try await api.send(.runRoom(id: "r1", turns: 0))
        let queries = await transport.requests.map { $0.url?.query }
        XCTAssertEqual(queries, [nil, "turns=1", "turns=1"], "nothing, one, and never less than one")
    }

    func testAPostIsNeverRetriedByTheClient() {
        XCTAssertFalse(Endpoint<ChatRoomRun>.postRoomMessage(roomID: "r1", content: "hi", run: false).idempotent, "a retry would say it twice")
        XCTAssertTrue(Endpoint<ChatRoomRun>.runRoom(id: "r1", turns: 1).idempotent)
    }
}
