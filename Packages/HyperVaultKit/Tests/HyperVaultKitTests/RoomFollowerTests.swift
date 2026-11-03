import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

/// How often the follower asks, and what it does when the asking goes wrong or the screen goes.
final class RoomFollowerTests: RoomTestCase {
    /// A pace that waits for nothing.
    let instant = ChatRoomPace(
        schedule: ChatRoomPollSchedule(active: [0.001], idle: 0.001, failureCeiling: 0.001), tick: 0.001, busySteps: [0.001],
        sleep: { _ in await Task.yield() }
    )

    func testTheScheduleAsksQuicklyAtFirstThenLessOftenAndBacksOffFailures() {
        let schedule = ChatRoomPollSchedule.standard
        XCTAssertEqual((0..<8).map { schedule.delay(quiet: $0, isActive: true) }, [1.5, 1.5, 2, 3, 4, 5, 5, 5])
        XCTAssertEqual(schedule.delay(quiet: 0, isActive: false), 20)
        XCTAssertEqual(schedule.delay(quiet: 99, isActive: false), 20)
        XCTAssertEqual((1...6).map { schedule.delay(failures: $0) }, [2, 4, 8, 15, 15, 15])
        XCTAssertEqual(schedule.delay(failures: 0), 2, "never below the first step")
        XCTAssertEqual(ChatRoomPollSchedule(active: []).delay(quiet: 0, isActive: true), 20, "no steps to follow: the slow pace")
    }

    // MARK: the follower

    /// Runs a follower over `transport` until it has waited `count` times; returns the waits it chose.
    func observedWaits(
        _ transport: any HTTPTransport, isActive: Bool, until count: Int, schedule: ChatRoomPollSchedule = .standard
    ) async -> [Double] {
        let slept = TestBox<[Double]>([])
        // A tick longer than any wait: each wait is one sleep, so what was slept is what was decided.
        let pace = ChatRoomPace(schedule: schedule, tick: 1_000, busySteps: [1], sleep: { seconds in
            slept.value.append(seconds)
            try? await Task.sleep(nanoseconds: 1_000_000)
        })
        let follower = ChatRoomFollower(client: client(transport), roomID: "r1", pace: pace)
        let task = Task { await follower.follow(state: { ChatRoomFollowState(cursor: nil, isActive: isActive) }, onSnapshot: { _ in }) }
        await eventually("\(count) waits") { slept.value.count >= count }
        task.cancel()
        _ = await task.value
        return Array(slept.value.prefix(count))
    }

    func testAnActiveRoomThatSaysNothingIsAskedLessAndLessOften() async {
        let transport = MockTransport(routes: [.json(.get, "/api/rooms/r1", Self.emptyRoom)])
        let observed = await observedWaits(transport, isActive: true, until: 7)
        XCTAssertEqual(observed, [1.5, 1.5, 2, 3, 4, 5, 5], "1.5 seconds, backing off to 5")
    }

    func testAQuietRoomIsAskedEveryTwentySeconds() async {
        let transport = MockTransport(routes: [.json(.get, "/api/rooms/r1", Self.emptyRoom)])
        let observed = await observedWaits(transport, isActive: false, until: 3)
        XCTAssertEqual(observed, [20, 20, 20])
    }

    func testFailedAsksBackOffAndNeverEndTheFollower() async {
        let transport = MockTransport(routes: [.failure(.get, "/api/rooms/r1", status: 503, message: "down")])
        let observed = await observedWaits(transport, isActive: true, until: 6)
        XCTAssertEqual(observed, [2, 4, 8, 15, 15, 15])
    }

    func testAnAskThatWorksAfterFailuresStartsTheBackoffOver() async {
        let calls = Counter()
        let transport = MockTransport(routes: [
            MockRoute(.get, "/api/rooms/r1") { _ in
                calls.bump()
                if calls.value == 1 || calls.value == 2 { return HTTPResponse(status: 503, data: Data(#"{"error":"down"}"#.utf8)) }
                if calls.value == 4 { return HTTPResponse(status: 503, data: Data(#"{"error":"down"}"#.utf8)) }
                return HTTPResponse(status: 200, data: Data(RoomTestCase.emptyRoom.utf8))
            },
        ])
        let observed = await observedWaits(transport, isActive: true, until: 4)
        XCTAssertEqual(observed, [2, 4, 1.5, 2], "two failures, an answer (1.5), a failure that starts again from 2")
    }

    func testAFailedAskIsTriedAgainAndDoesNotEndTheFollower() async throws {
        let calls = Counter()
        let transport = MockTransport(routes: [
            MockRoute(.get, "/api/rooms/r1") { _ in
                calls.bump()
                if calls.value < 3 { return HTTPResponse(status: 503, data: Data(#"{"error":"down"}"#.utf8)) }
                return HTTPResponse(status: 200, data: Data(RoomTestCase.emptyRoom.utf8))
            },
        ])
        let seen = TestBox<Int>(0)
        let follower = ChatRoomFollower(client: client(transport), roomID: "r1", pace: instant)
        let task = Task { await follower.follow(state: { ChatRoomFollowState(cursor: nil, isActive: true) }, onSnapshot: { _ in seen.value += 1 }) }
        await eventually("an answer after two failures") { seen.value >= 1 }
        task.cancel()
        XCTAssertGreaterThanOrEqual(calls.value, 3)
    }

    func testTheFollowerAsksFromWhereTheScreenSaysItIs() async {
        let transport = MockTransport(routes: [.json(.get, "/api/rooms/r1", Self.emptyRoom)])
        let cursor = TestBox<Int?>(nil)
        let follower = ChatRoomFollower(client: client(transport), roomID: "r1", pace: instant)
        let task = Task { await follower.follow(state: { ChatRoomFollowState(cursor: cursor.value, isActive: true) }, onSnapshot: { _ in }) }
        await eventually("a first ask") { await transport.requests.count >= 1 }
        cursor.value = 7
        await eventually("an ask from 7") { await transport.requests.contains { $0.url?.query == "after=7" } }
        task.cancel()
        let first = await transport.requests.first
        XCTAssertNil(first?.url?.query, "a room never read is asked for whole")
    }

    func testAFullPageIsFollowedByAnotherAskAtOnce() async throws {
        let calls = Counter()
        @Sendable func page(_ from: Int, _ count: Int) -> String {
            let rows = (from..<(from + count)).map { #"{"id":"m\#($0)","position":\#($0),"sender_kind":"agent","content":"x"}"# }.joined(separator: ",")
            return #"{"room":{"id":"r1","title":"T","pending":[],"budget":0,"running":false},"members":[],"messages":[\#(rows)]}"#
        }
        let transport = MockTransport(routes: [
            MockRoute(.get, "/api/rooms/r1") { request in
                calls.bump()
                let after = request.url?.query?.split(separator: "=").last.flatMap { Int($0) } ?? -1
                return HTTPResponse(status: 200, data: Data((after < 0 ? page(0, 500) : page(500, 20)).utf8))
            },
        ])
        let askedBeforeFirstSleep = TestBox<Int?>(nil)
        let pace = ChatRoomPace(schedule: ChatRoomPollSchedule(active: [60], idle: 60, failureCeiling: 60), tick: 60, busySteps: [1], sleep: { _ in
            if askedBeforeFirstSleep.value == nil { askedBeforeFirstSleep.value = calls.value }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        })
        let follower = ChatRoomFollower(client: client(transport), roomID: "r1", pace: pace)
        let total = TestBox<Int>(0)
        let cursor = TestBox<Int?>(nil)
        let task = Task {
            await follower.follow(
                state: { ChatRoomFollowState(cursor: cursor.value, isActive: true) },
                onSnapshot: { total.value += $0.messages.count; cursor.value = $0.messages.map(\.position).max() }
            )
        }
        await eventually("both pages") { total.value == 520 }
        await eventually("the follower to wait") { askedBeforeFirstSleep.value != nil }
        task.cancel()
        XCTAssertEqual(askedBeforeFirstSleep.value, 2, "the second page was asked for before the follower first waited")
    }

    func testAFullPageThatGetsNoFurtherIsNotAskedForInATightLoop() async {
        // A screen that never moves its cursor is handed the same full page again and again.
        let rows = (0..<500).map { #"{"id":"m\#($0)","position":\#($0),"sender_kind":"agent","content":"x"}"# }.joined(separator: ",")
        let full = #"{"room":{"id":"r1","title":"T","pending":[],"budget":0,"running":false},"members":[],"messages":[\#(rows)]}"#
        let transport = MockTransport(routes: [.json(.get, "/api/rooms/r1", full)])
        let slept = Counter()
        // Parked for good once it waits: only the cancel ends the sleep.
        let pace = ChatRoomPace(schedule: .standard, tick: 1_000, busySteps: [1], sleep: { _ in
            slept.bump()
            try? await Task.sleep(nanoseconds: 30_000_000_000)
        })
        let follower = ChatRoomFollower(client: client(transport), roomID: "r1", pace: pace)
        let task = Task { await follower.follow(state: { ChatRoomFollowState(cursor: nil, isActive: true) }, onSnapshot: { _ in }) }
        await eventually("a first wait") { slept.value >= 1 }
        task.cancel()
        let asked = await transport.requests.count
        XCTAssertEqual(asked, 2, "the first page got further, the second did not, so it waited")
    }

    func testTheFollowerHandsOverEverySnapshotAndStopsWhenCancelled() async throws {
        let server = FakeRoomServer(style: .queued, turnSeconds: 0.01)
        let api = client(FakeRoomTransport(server: server))
        let seen = TestBox<[Int]>([])
        let follower = ChatRoomFollower(client: api, roomID: "r1", pace: instant)
        let task = Task { await follower.follow(state: { ChatRoomFollowState(cursor: nil, isActive: true) }, onSnapshot: { seen.value.append($0.messages.count) }) }
        await eventually("some snapshots") { seen.value.count >= 3 }
        task.cancel()
        _ = await task.value
        let asked = await server.requests.count
        try await Task.sleep(nanoseconds: 60_000_000)
        let later = await server.requests.count
        XCTAssertEqual(later, asked, "a cancelled follower asks for nothing more")
    }

    func testALongWaitIsCutShortWhenTheScreenGoes() async {
        let transport = MockTransport(routes: [.json(.get, "/api/rooms/r1", Self.emptyRoom)])
        let follower = ChatRoomFollower(client: client(transport), roomID: "r1", pace: .live)
        let seen = TestBox<Int>(0)
        let finished = TestBox<Bool>(false)
        let task = Task {
            await follower.follow(state: { ChatRoomFollowState(cursor: nil, isActive: false) }, onSnapshot: { _ in seen.value += 1 })
            finished.value = true
        }
        await eventually("a first read") { seen.value >= 1 }
        task.cancel()
        // It is now twenty seconds into nothing; the real wait must not be what ends it.
        await eventually("the follower to return", timeout: 2) { finished.value }
    }

    func testARoundThatStartsWakesAFollowerThatWasWaitingTwentySeconds() async {
        let transport = MockTransport(routes: [.json(.get, "/api/rooms/r1", Self.emptyRoom)])
        let active = TestBox<Bool>(false)
        let pace = ChatRoomPace(
            schedule: ChatRoomPollSchedule(active: [60], idle: 60, failureCeiling: 60), tick: 0.01, busySteps: [1],
            sleep: { _ in try? await Task.sleep(nanoseconds: 10_000_000) }
        )
        let follower = ChatRoomFollower(client: client(transport), roomID: "r1", pace: pace)
        let task = Task { await follower.follow(state: { ChatRoomFollowState(cursor: nil, isActive: active.value) }, onSnapshot: { _ in }) }
        await eventually("a first read") { await transport.requests.count == 1 }
        try? await Task.sleep(nanoseconds: 60_000_000)
        let quietCount = await transport.requests.count
        XCTAssertEqual(quietCount, 1, "nothing is moving: it waits")
        active.value = true
        await eventually("a read within a tick of the round starting") { await transport.requests.count >= 2 }
        task.cancel()
    }
}
