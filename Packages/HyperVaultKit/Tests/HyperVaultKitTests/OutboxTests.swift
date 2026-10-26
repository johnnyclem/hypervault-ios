import XCTest
@testable import HyperVaultKit

final class OutboxTests: XCTestCase {
    func item(_ id: String) -> OutboxItem { OutboxItem(id: id, content: "content \(id)") }

    func testWhatIsWorthRetrying() {
        XCTAssertTrue(Outbox.shouldRetain(after: .transport("offline")))
        XCTAssertTrue(Outbox.shouldRetain(after: .unauthorized))
        XCTAssertTrue(Outbox.shouldRetain(after: .api(APIFailure(status: 503, message: "x"))))
        XCTAssertTrue(Outbox.shouldRetain(after: .api(APIFailure(status: 429, message: "x"))))
        XCTAssertTrue(Outbox.shouldRetain(after: .api(APIFailure(status: 403, message: "waitlist"))))
        XCTAssertFalse(Outbox.shouldRetain(after: .api(APIFailure(status: 413, message: "too big"))))
        XCTAssertFalse(Outbox.shouldRetain(after: .api(APIFailure(status: 400, message: "empty"))))
    }

    func testFlushKeepsInOrderAndEmptiesTheOutbox() async {
        let sent = Counter()
        let result = await Outbox.flush([item("a"), item("b")]) { _ in sent.bump() }
        XCTAssertEqual(result.kept.map(\.id), ["a", "b"])
        XCTAssertTrue(result.remaining.isEmpty)
        XCTAssertEqual(sent.value, 2)
    }

    func testFlushStopsAtTheNetworkAndKeepsTheRest() async {
        let result = await Outbox.flush([item("a"), item("b"), item("c")]) { entry in
            if entry.id == "b" { throw HVError.transport("offline") }
        }
        XCTAssertEqual(result.kept.map(\.id), ["a"])
        XCTAssertEqual(result.remaining.map(\.id), ["b", "c"], "the rest would fail the same way")
        XCTAssertTrue(result.dropped.isEmpty)
    }

    func testFlushDropsWhatTheServerWillNeverTake() async {
        let result = await Outbox.flush([item("a"), item("b")]) { entry in
            if entry.id == "a" { throw HVError.api(APIFailure(status: 413, message: "That is over the 1 MB limit.")) }
        }
        XCTAssertEqual(result.dropped.map(\.id), ["a"])
        XCTAssertEqual(result.kept.map(\.id), ["b"])
        XCTAssertTrue(result.remaining.isEmpty)
    }

    func testAddingKeepsOrderReplacesADuplicateAndBoundsTheQueue() {
        var items: [OutboxItem] = []
        for index in 0..<(Outbox.capacity + 5) { items = Outbox.adding(item("n\(index)"), to: items) }
        XCTAssertEqual(items.count, Outbox.capacity)
        XCTAssertEqual(items.first?.id, "n5", "the oldest give way")
        let again = Outbox.adding(OutboxItem(id: "n10", content: "changed"), to: items)
        XCTAssertEqual(again.count, Outbox.capacity)
        XCTAssertEqual(again.last?.content, "changed")
    }
}
