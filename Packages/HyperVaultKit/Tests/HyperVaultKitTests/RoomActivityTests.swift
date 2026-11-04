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
        // A run holds the room and the server does not say whose turn it is (an older server, or the moment between
        // two turns of one run): the room is working, with the rest of the queue behind it.
        let between = detail([], running: true, pending: ["custom"]).room
        XCTAssertEqual(ChatRoomActivity.resolve(header: between, sending: false), .working(then: ["custom"]))
        XCTAssertEqual(ChatRoomActivity.resolve(header: detail([], running: true).room, sending: false), .working(then: []))
        // A turn was started and its run died: nobody is thinking, whatever the queue says.
        let cutOff = detail([], running: false, pending: ["custom"], current: "claude").room
        XCTAssertEqual(ChatRoomActivity.resolve(header: cutOff, sending: false), .cutOff(handle: "claude"))
        XCTAssertTrue(cutOff.canBeContinued)
        XCTAssertFalse(thinking.canBeContinued)
        XCTAssertFalse(detail([]).room.canBeContinued)
    }

    func testARoomThatDoesNotSayWhoseTurnItIsKeepsItsDotsWhileTurnsAreQueued() {
        // An older server never reports `current` and takes a turn off the queue before it runs it, so for a round of
        // three the queue is not empty until the last turn. It is working all that time, not waiting for anybody.
        let midRound = detail([], running: true, pending: ["b", "c"]).room
        let working = ChatRoomActivity.resolve(header: midRound, sending: false)
        XCTAssertEqual(working, .working(then: ["b", "c"]))
        XCTAssertTrue(working.isBusy)
        XCTAssertEqual(working.line(), "The room is working... then @b, @c")
        // The same queue with nobody running it is waiting, and does not claim to be at work.
        let waiting = ChatRoomActivity.resolve(header: detail([], running: false, pending: ["b", "c"]).room, sending: false)
        XCTAssertEqual(waiting, .next(handle: "b", then: ["c"]))
        XCTAssertFalse(waiting.isBusy)
    }

    func testAQueueThisPhoneIsWorkingThroughIsNotWaitingForAnybody() {
        // Between two of the phone's requests no run holds the room: the turn before has been written and the next has
        // not been claimed. The line stays on the room at work instead of flickering to "is next" and back.
        let gap = detail([], running: false, pending: ["b", "c"]).room
        let driving = ChatRoomActivity.resolve(header: gap, sending: false, driving: true)
        XCTAssertEqual(driving, .working(then: ["b", "c"]))
        XCTAssertTrue(driving.isBusy)
        XCTAssertEqual(ChatRoomActivity.resolve(header: gap, sending: false, driving: false), .next(handle: "b", then: ["c"]))
        // Nothing queued: nothing to be at work on, whoever is asking.
        XCTAssertEqual(ChatRoomActivity.resolve(header: detail([]).room, sending: false, driving: true), .idle)
        // A lost turn is still lost, and the message on its way still comes first.
        let lost = detail([], running: false, pending: ["b"], current: "a").room
        XCTAssertEqual(ChatRoomActivity.resolve(header: lost, sending: false, driving: true), .cutOff(handle: "a"))
        XCTAssertEqual(ChatRoomActivity.resolve(header: gap, sending: true, driving: true), .sending)
        // A member who is thinking is named, driving or not.
        let thinking = detail([], running: true, pending: ["c"], current: "b").room
        XCTAssertEqual(ChatRoomActivity.resolve(header: thinking, sending: false, driving: true), .thinking(handle: "b", since: nil, then: ["c"]))
    }

    func testTurnsLeftWaitingWithNobodyRunningThemCanBeContinued() {
        XCTAssertTrue(detail([], running: false, pending: ["claude", "custom"]).room.canBeContinued)
        XCTAssertFalse(detail([], running: true, pending: ["claude"]).room.canBeContinued, "a run is at work on them")
        XCTAssertTrue(detail([], running: false, pending: [], current: "claude").room.canBeContinued, "a lost turn with nothing left")
        let queued = detail([], running: false, pending: ["claude"]).room
        XCTAssertEqual(ChatRoomActivity.resolve(header: queued, sending: false), .next(handle: "claude", then: []))
    }

    // MARK: the header after an answer

    func testTheAnswerToAPostThatNamesAnotherDevicesTurnLeavesTheRoomRunning() {
        // The screen last read a quiet room. Another device then started a run, and this phone posts without running:
        // the answer names the turn in flight and says nothing of the lease.
        let quiet = detail([]).room
        let post = ChatRoomRun(
            messages: [], pending: [ChatRoomTurn(handle: "custom")], budget: 11, busy: false,
            current: ChatRoomCurrentTurn(handle: "claude")
        )
        let after = quiet.applying(post)
        XCTAssertTrue(after.running)
        XCTAssertEqual(after.current?.handle, "claude")
        XCTAssertEqual(after.pending.map(\.handle), ["custom"])
        XCTAssertEqual(after.budget, 11)
        XCTAssertEqual(ChatRoomActivity.resolve(header: after, sending: false), .thinking(handle: "claude", since: nil, then: ["custom"]))
        XCTAssertFalse(after.canBeContinued, "a run that is alive is not something to continue")
        XCTAssertEqual(after.id, quiet.id)
        XCTAssertEqual(after.title, quiet.title)
    }

    func testARunAnswerThatSaysBusyKeepsTheRoomRunning() {
        let busy = ChatRoomRun(
            messages: [], pending: [ChatRoomTurn(handle: "custom")], budget: 10, busy: true, current: ChatRoomCurrentTurn(handle: "claude")
        )
        let after = detail([]).room.applying(busy)
        XCTAssertTrue(after.running)
        XCTAssertEqual(ChatRoomActivity.resolve(header: after, sending: false), .thinking(handle: "claude", since: nil, then: ["custom"]))
        // A server that does not report the turn: busy alone is enough.
        let plain = detail([]).room.applying(ChatRoomRun(pending: [ChatRoomTurn(handle: "custom")], busy: true))
        XCTAssertEqual(ChatRoomActivity.resolve(header: plain, sending: false), .working(then: ["custom"]))
    }

    func testTheAnswerToThisPhonesOwnRunEndsIt() {
        // The screen read the room while the run was going (running, claude thinking); the run's answer says it is over.
        let reading = detail([], running: true, pending: ["custom"], current: "claude").room
        let finished = reading.applying(ChatRoomRun(messages: [message("a1", 3)], pending: [], budget: 9))
        XCTAssertFalse(finished.running)
        XCTAssertNil(finished.current)
        XCTAssertEqual(ChatRoomActivity.resolve(header: finished, sending: false), .idle)
        XCTAssertFalse(finished.canBeContinued)
        // Turns left over (the budget ran out, say) are for the person to continue.
        let leftOver = reading.applying(ChatRoomRun(pending: [ChatRoomTurn(handle: "custom")], budget: 0))
        XCTAssertEqual(ChatRoomActivity.resolve(header: leftOver, sending: false), .next(handle: "custom", then: []))
        XCTAssertTrue(leftOver.canBeContinued)
    }

    func testTheSentenceUnderTheThreadNamesTheMemberWhoIsThinking() {
        let started = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertNil(ChatRoomActivity.idle.line())
        XCTAssertEqual(ChatRoomActivity.sending.line(), "Sending...")
        XCTAssertEqual(ChatRoomActivity.working(then: []).line(), "The room is working...")
        XCTAssertEqual(ChatRoomActivity.working(then: ["a", "b"]).line(), "The room is working... then @a, @b")
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

    func testTheEdgesOfWhatCanBeShownAreExact() {
        let started = Date(timeIntervalSince1970: 1_000_000)
        let thinking = ChatRoomActivity.thinking(handle: "claude", since: started, then: [])
        XCTAssertEqual(thinking.line(now: started.addingTimeInterval(4.9)), "@claude is thinking...")
        XCTAssertEqual(thinking.line(now: started.addingTimeInterval(5)), "@claude is thinking... 5s")
        XCTAssertEqual(thinking.line(now: started.addingTimeInterval(59.9)), "@claude is thinking... 59s")
        XCTAssertEqual(thinking.line(now: started.addingTimeInterval(60)), "@claude is thinking... 1m 0s")
        XCTAssertEqual(thinking.line(now: started.addingTimeInterval(180.9)), "@claude is thinking... 3m 0s")
        XCTAssertEqual(thinking.line(now: started.addingTimeInterval(181)), "@claude is thinking...")
    }

    func testAStartTimeNoTurnCouldHaveDoesNotCrashTheLine() throws {
        // The wire reads a number as a date, so a start like this gets through the lenient decode of `current`.
        let wild = #"{"room":{"id":"r1","title":"T","pending":[],"budget":1,"running":true,"current":{"handle":"claude","reason":"","started_at":1e300}},"members":[],"messages":[]}"#
        let room = try HVCoding.decoder().decode(ChatRoomDetail.self, from: Data(wild.utf8)).room
        XCTAssertEqual(ChatRoomActivity.resolve(header: room, sending: false).line(), "@claude is thinking...")
        for start in [Date(timeIntervalSince1970: -1e300), .distantPast, .distantFuture, Date(timeIntervalSince1970: .infinity)] {
            XCTAssertEqual(ChatRoomActivity.thinking(handle: "claude", since: start, then: []).line(), "@claude is thinking...", "\(start)")
        }
        XCTAssertNil(ChatRoomActivity.elapsed(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: .nan)))
    }

    func testOnlyAModelAtWorkOrAMessageOnItsWayMovesTheDots() {
        XCTAssertTrue(ChatRoomActivity.sending.isBusy)
        XCTAssertTrue(ChatRoomActivity.thinking(handle: "a", since: nil, then: []).isBusy)
        XCTAssertTrue(ChatRoomActivity.working(then: []).isBusy)
        XCTAssertTrue(ChatRoomActivity.working(then: ["a"]).isBusy)
        XCTAssertFalse(ChatRoomActivity.next(handle: "a", then: []).isBusy)
        XCTAssertFalse(ChatRoomActivity.cutOff(handle: "a").isBusy)
        XCTAssertFalse(ChatRoomActivity.idle.isBusy)
    }
}
