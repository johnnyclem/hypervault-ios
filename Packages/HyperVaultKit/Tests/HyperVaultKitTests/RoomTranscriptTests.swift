import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

/// The transcript a screen keeps and the place it polls from.
final class RoomTranscriptTests: RoomTestCase {
    func testAnAnswerMergedFromARunDoesNotMoveThePlaceThePollStartsFrom() {
        var transcript = ChatRoomTranscript()
        transcript.apply(detail([message("h1", 0, kind: .human, handle: nil)]))
        XCTAssertEqual(transcript.cursor, 0)
        // The phone lost the answer to its first message (position 1), then said something else (2); the run it
        // drove brought back only its own answer (3). The old rule, "past the highest position I hold", polls from 3.
        transcript.merge([message("h2", 2, kind: .human, handle: nil), message("c2", 3)])
        XCTAssertEqual(transcript.messages.map(\.position), [0, 2, 3])
        XCTAssertEqual(transcript.cursor, 0, "only a read of the room moves the place; position 1 is still to be fetched")
        let poll = detail([message("c1", 1), message("h2", 2, kind: .human, handle: nil), message("c2", 3)])
        let fresh = transcript.apply(poll)
        XCTAssertEqual(fresh.map(\.id), ["c1"])
        XCTAssertEqual(transcript.messages.map(\.position), [0, 1, 2, 3])
        XCTAssertEqual(transcript.cursor, 3)
    }

    func testAnEmptyRoomThatWasReadIsPolledFromBeforeTheFirstMessage() {
        var transcript = ChatRoomTranscript()
        XCTAssertNil(transcript.cursor, "never read: ask for the whole room")
        transcript.apply(detail([]))
        XCTAssertEqual(transcript.cursor, -1)
        XCTAssertEqual(Endpoint<ChatRoomDetail>.room(id: "r1", after: transcript.cursor).query.first?.value, "-1")
    }

    func testTheSameMessageTwiceIsOneMessage() {
        var transcript = ChatRoomTranscript()
        XCTAssertEqual(transcript.merge([message("a", 1)]).count, 1)
        XCTAssertEqual(transcript.merge([message("a", 1)]).count, 0)
        XCTAssertEqual(transcript.apply(detail([message("a", 1)])).count, 0)
        XCTAssertEqual(transcript.messages.count, 1)
        XCTAssertTrue(transcript.contains(id: "a"))
        XCTAssertFalse(transcript.contains(id: "b"))
    }

    func testTheCursorOnlyMovesForwardAndAReadWithNothingNewLeavesItAlone() {
        var transcript = ChatRoomTranscript()
        transcript.apply(detail([message("a", 4), message("b", 5)]))
        XCTAssertEqual(transcript.cursor, 5)
        transcript.apply(detail([]))
        XCTAssertEqual(transcript.cursor, 5, "an empty poll does not send the place back to the start")
        transcript.apply(detail([message("old", 2)]))
        XCTAssertEqual(transcript.cursor, 5, "a late read of something older does not either")
        XCTAssertEqual(transcript.messages.map(\.position), [2, 4, 5])
    }

    func testMessagesComeBackInPositionOrderWhateverOrderTheyArriveIn() {
        var transcript = ChatRoomTranscript()
        let fresh = transcript.merge([message("c", 3), message("a", 1), message("b", 2)])
        XCTAssertEqual(fresh.map(\.id), ["a", "b", "c"])
        transcript.merge([message("d", 0)])
        XCTAssertEqual(transcript.messages.map(\.id), ["d", "a", "b", "c"])
    }

    func testAnOpeningReadOfAFullPageHoldsItAndPollsFromItsEnd() {
        var transcript = ChatRoomTranscript()
        let page = (100..<600).map { message("m\($0)", $0) }
        transcript.apply(detail(page))
        XCTAssertEqual(transcript.messages.count, 500)
        XCTAssertEqual(transcript.cursor, 599)
    }
}
