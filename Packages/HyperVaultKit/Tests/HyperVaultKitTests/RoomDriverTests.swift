import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

/// The driver: a message posted without running the turns, then one turn per request.
final class RoomDriverTests: RoomTestCase {
    /// A pace that waits for nothing.
    let instant = ChatRoomPace(
        schedule: ChatRoomPollSchedule(active: [0.001], idle: 0.001, failureCeiling: 0.001), tick: 0.001, busySteps: [0.001],
        sleep: { _ in await Task.yield() }
    )

    func testAMessageIsPostedWithoutRunningAndTurnsAreAskedForOneAtATime() async throws {
        let transport = MockTransport(routes: [
            .json(.post, "/api/rooms/r1/messages", #"{"messages":[{"id":"h1","position":0,"sender_kind":"human","content":"hello"}],"pending":[{"handle":"claude","reason":""}],"budget":12}"#),
            .json(.post, "/api/rooms/r1/run", #"{"messages":[{"id":"a1","position":1,"sender_kind":"agent","sender_handle":"claude","content":"hi"}],"pending":[],"budget":11}"#),
        ])
        let driver = ChatRoomDriver(client: client(transport), roomID: "r1", pace: instant)
        let outcome = try await driver.send("hello") { _ in }
        XCTAssertEqual(outcome, .finished)
        let all = await transport.requests
        XCTAssertEqual(all.first?.url?.path, "/api/rooms/r1/messages")
        XCTAssertEqual(requestJSON(all.first)?["run"]?.bool, false)
        XCTAssertEqual(requestJSON(all.first)?["content"]?.string, "hello")
        XCTAssertEqual(all.last?.url?.query, "turns=1")
    }

    func testResumingAlsoAsksForOneTurnPerRequest() async throws {
        let transport = MockTransport(routes: [
            .json(.post, "/api/rooms/r1/run", #"{"messages":[],"pending":[],"budget":0}"#),
        ])
        let driver = ChatRoomDriver(client: client(transport), roomID: "r1", pace: instant)
        _ = try await driver.resume { _ in }
        let all = await transport.requests
        XCTAssertEqual(all.map { $0.url?.path }, ["/api/rooms/r1/run"])
        XCTAssertEqual(all.first?.url?.query, "turns=1")
    }

    func testARoomAnotherRunHoldsIsAskedAgainWithGrowingWaitsAndThenGivenUpOn() async throws {
        let transport = MockTransport(routes: [
            .json(.post, "/api/rooms/r1/run", #"{"messages":[],"pending":[{"handle":"claude","reason":""}],"budget":12,"busy":true}"#),
        ])
        let waits = TestBox<[Double]>([])
        let pace = ChatRoomPace(busySteps: [3, 4, 5, 6], sleep: { waits.value.append($0) })
        let driver = ChatRoomDriver(client: client(transport), roomID: "r1", pace: pace, maxBusyAsks: 6)
        let outcome = try await driver.resume { _ in }
        XCTAssertEqual(outcome, .stalled)
        XCTAssertEqual(waits.value, [3, 4, 5, 6, 6, 6])
    }

    func testTheDefaultWaitsOutAHeldRoomForLongerThanTheServerKeepsALease() {
        let driver = ChatRoomDriver(client: client(MockTransport()), roomID: "r1")
        let steps = driver.busySteps
        XCTAssertEqual(steps, [3, 4, 5, 6])
        let total = (0..<driver.maxBusyAsks).map { steps[min($0, steps.count - 1)] }.reduce(0, +)
        XCTAssertGreaterThan(total, 180, "the old lease was 180 s and the new one 140 s; giving up sooner hides Continue")
    }

    func testARunThatSaysATurnIsStillInFlightIsNotTheEnd() async throws {
        let calls = Counter()
        let transport = MockTransport(routes: [
            MockRoute(.post, "/api/rooms/r1/run") { _ in
                calls.bump()
                return HTTPResponse(status: 200, data: Data(#"{"messages":[],"pending":[],"budget":10}"#.utf8))
            },
        ])
        // A post that answers "queue empty" while a turn is recorded as in flight comes back for another look.
        let queued = ChatRoomRun(messages: [], pending: [], budget: 10, busy: false, current: ChatRoomCurrentTurn(handle: "claude"))
        let driver = ChatRoomDriver(client: client(transport), roomID: "r1", pace: instant)
        let outcome = try await driver.drive(after: queued) { _ in }
        XCTAssertEqual(outcome, .finished)
        XCTAssertEqual(calls.value, 1)
    }

    func testRunsThatTookTurnsOffTheQueueWithoutWritingAreNotAStall() async throws {
        // A member left the room after being queued: the server takes the turn and writes nothing. One turn per
        // request must not turn three of those into "the room stopped answering".
        @Sendable func run(_ pending: [String]) -> String {
            #"{"messages":[],"pending":[\#(pending.map { #"{"handle":"\#($0)","reason":""}"# }.joined(separator: ","))],"budget":8}"#
        }
        let script = TestBox<[String]>([run(["b", "c", "d", "e"]), run(["c", "d", "e"]), run(["d", "e"]), run(["e"]), run([])])
        let transport = MockTransport(routes: [
            .json(.post, "/api/rooms/r1/messages", #"{"messages":[{"id":"h1","position":0,"sender_kind":"human","content":"hi"}],"pending":[{"handle":"a","reason":""},{"handle":"b","reason":""},{"handle":"c","reason":""},{"handle":"d","reason":""},{"handle":"e","reason":""}],"budget":12}"#),
            MockRoute(.post, "/api/rooms/r1/run") { _ in
                var rest = script.value
                let next = rest.isEmpty ? run([]) : rest.removeFirst()
                script.value = rest
                return HTTPResponse(status: 200, data: Data(next.utf8))
            },
        ])
        let driver = ChatRoomDriver(client: client(transport), roomID: "r1", pace: instant)
        let outcome = try await driver.send("hi") { _ in }
        XCTAssertEqual(outcome, .finished)
        XCTAssertEqual(script.value, [])
    }

    func testRunsThatNeitherWriteNorMoveTheQueueStillStall() async throws {
        let stall = #"{"messages":[],"pending":[{"handle":"claude","reason":""},{"handle":"custom","reason":""}],"budget":9}"#
        let transport = MockTransport(routes: [.json(.post, "/api/rooms/r1/run", stall)])
        let driver = ChatRoomDriver(client: client(transport), roomID: "r1", pace: instant)
        let outcome = try await driver.resume { _ in }
        XCTAssertEqual(outcome, .stalled)
        let asked = await transport.requests.count
        XCTAssertEqual(asked, 3)
    }

    func testTheOldSpellingOfTheDriverStillWaitsOnceBetweenAsks() async throws {
        let transport = MockTransport(routes: [
            .json(.post, "/api/rooms/r1/run", #"{"messages":[],"pending":[{"handle":"claude","reason":""}],"budget":12,"busy":true}"#),
        ])
        let waits = TestBox<[Double]>([])
        let driver = ChatRoomDriver(client: client(transport), roomID: "r1", pollDelay: 7, maxRequests: 3, sleep: { waits.value.append($0) })
        let outcome = try await driver.resume { _ in }
        XCTAssertEqual(outcome, .stalled)
        XCTAssertEqual(waits.value, [7, 7])
    }
}
