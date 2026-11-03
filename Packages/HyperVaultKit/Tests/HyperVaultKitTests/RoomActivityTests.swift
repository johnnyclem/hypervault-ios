import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

/// The line under the thread, and when a room can be continued.
final class RoomActivityTests: RoomTestCase {
    func testTheTypingLineSaysOnlyWhatIsSo() {
        let none = ChatRoomActivity.resolve(header: nil, sending: false)
        XCTAssertEqual(none, .idle)
        // The person's message is on its way: nothing else is known yet.
        XCTAssertEqual(ChatRoomActivity.resolve(header: detail([]).room, sending: true), .sending)
        // A turn is in flight and the lease is fresh: that member is thinking, and the rest are waiting.
        let thinking = detail([], running: true, pending: ["custom"], current: "claude").room
        XCTAssertEqual(ChatRoomActivity.resolve(header: thinking, sending: false), .thinking(handle: "claude", since: nil, then: ["custom"]))
        // Between two turns nobody is thinking: the next one is next.
        let between = detail([], running: true, pending: ["custom"]).room
        XCTAssertEqual(ChatRoomActivity.resolve(header: between, sending: false), .next(handle: "custom", then: []))
        // A run holds the room and the server does not say whose turn it is (an older server).
        XCTAssertEqual(ChatRoomActivity.resolve(header: detail([], running: true).room, sending: false), .working)
        // A turn was started and its run died: nobody is thinking, whatever the queue says.
        let cutOff = detail([], running: false, pending: ["custom"], current: "claude").room
        XCTAssertEqual(ChatRoomActivity.resolve(header: cutOff, sending: false), .cutOff(handle: "claude"))
        XCTAssertTrue(cutOff.canBeContinued)
        XCTAssertFalse(thinking.canBeContinued)
        XCTAssertFalse(detail([]).room.canBeContinued)
    }

    func testTurnsLeftWaitingWithNobodyRunningThemCanBeContinued() {
        XCTAssertTrue(detail([], running: false, pending: ["claude", "custom"]).room.canBeContinued)
        XCTAssertFalse(detail([], running: true, pending: ["claude"]).room.canBeContinued, "a run is at work on them")
        XCTAssertTrue(detail([], running: false, pending: [], current: "claude").room.canBeContinued, "a lost turn with nothing left")
        let queued = detail([], running: false, pending: ["claude"]).room
        XCTAssertEqual(ChatRoomActivity.resolve(header: queued, sending: false), .next(handle: "claude", then: []))
    }

    func testTheSentenceUnderTheThreadNamesTheMemberWhoIsThinking() {
        let started = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertNil(ChatRoomActivity.idle.line())
        XCTAssertEqual(ChatRoomActivity.sending.line(), "Sending...")
        XCTAssertEqual(ChatRoomActivity.working.line(), "The room is working...")
        XCTAssertEqual(ChatRoomActivity.cutOff(handle: "claude").line(), "@claude's turn was cut off")
        XCTAssertEqual(ChatRoomActivity.next(handle: "custom", then: []).line(), "@custom is next")
        XCTAssertEqual(ChatRoomActivity.next(handle: "a", then: ["b", "c"]).line(), "@a is next, then @b, @c")
        // Not worth a number for the first few seconds, then the seconds, then minutes.
        let thinking = ChatRoomActivity.thinking(handle: "claude", since: started, then: ["custom"])
        XCTAssertEqual(thinking.line(now: started.addingTimeInterval(2)), "@claude is thinking... then @custom")
        XCTAssertEqual(thinking.line(now: started.addingTimeInterval(42)), "@claude is thinking... 42s then @custom")
        XCTAssertEqual(thinking.line(now: started.addingTimeInterval(95)), "@claude is thinking... 1m 35s then @custom")
        XCTAssertEqual(ChatRoomActivity.thinking(handle: "claude", since: nil, then: []).line(), "@claude is thinking...")
    }

    func testAClockThatDisagreesWithTheServersDoesNotInventAnElapsedTime() {
        let started = Date(timeIntervalSince1970: 1_000_000)
        let thinking = ChatRoomActivity.thinking(handle: "claude", since: started, then: [])
        XCTAssertEqual(thinking.line(now: started.addingTimeInterval(-30)), "@claude is thinking...", "a start in the future")
        XCTAssertEqual(thinking.line(now: started.addingTimeInterval(3_600)), "@claude is thinking...", "longer than a turn can last")
    }

    func testOnlyAModelAtWorkOrAMessageOnItsWayMovesTheDots() {
        XCTAssertTrue(ChatRoomActivity.sending.isBusy)
        XCTAssertTrue(ChatRoomActivity.thinking(handle: "a", since: nil, then: []).isBusy)
        XCTAssertTrue(ChatRoomActivity.working.isBusy)
        XCTAssertFalse(ChatRoomActivity.next(handle: "a", then: []).isBusy)
        XCTAssertFalse(ChatRoomActivity.cutOff(handle: "a").isBusy)
        XCTAssertFalse(ChatRoomActivity.idle.isBusy)
    }
}
