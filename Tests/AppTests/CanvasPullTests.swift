import HyperVaultKit
import XCTest
@testable import HyperVault

/// Pulling things onto the page notes the open, as a tap in Yours does; showing them does not.
@MainActor
final class CanvasPullTests: CanvasTestCase {
    private func openStamps(_ transport: MockTransport) async -> [URLRequest] {
        await transport.requests(matching: "/api/yours/open")
    }

    func testPullingByNameNotesTheOpen() async throws {
        let (model, transport) = make([
            .json(.get, "/api/yours", tripList), .json(.get, "/api/yours/card", memory), .json(.post, "/api/yours/open", #"{"persisted":true}"#),
        ])
        model.pull("Trip notes")
        let stamped = await eventually { await self.openStamps(transport).count == 1 }
        XCTAssertTrue(stamped)
        let stamp = await openStamps(transport)
        let sent = try body(of: stamp.first)
        XCTAssertEqual(sent["kind"] as? String, "memory")
        XCTAssertEqual(sent["id"] as? String, "m1")
        XCTAssertEqual(model.cards.map(\.title), ["Trip notes"])
    }

    func testChoosingFromWhichOneNotesTheOpen() async throws {
        let (model, transport) = make([
            .json(.get, "/api/yours/card", memory), .json(.post, "/api/yours/open", #"{"persisted":true}"#),
        ])
        let item = KeptItem(id: "m1", kind: .memory, name: "Trip notes", href: "/vault/memory?open=m1")
        let question = model.say(HVCopy.pullWhichLine, choices: ThreadChoices(items: [item], more: false))
        model.choose(item, answering: question)

        let stamped = await eventually { await self.openStamps(transport).count == 1 }
        XCTAssertTrue(stamped)
        XCTAssertTrue(model.messages.isEmpty, "the question is answered")
        XCTAssertEqual(model.cards.count, 1)
    }

    func testPullingByAPastedLinkNotesTheOpen() async throws {
        let (model, transport) = make([
            .json(.get, "/api/yours/card", memory), .json(.post, "/api/yours/open", #"{"persisted":true}"#),
        ])
        model.pullLink(.memory(id: "m1"))
        let stamped = await eventually { await self.openStamps(transport).count == 1 }
        XCTAssertTrue(stamped)
        let stamp = await openStamps(transport)
        XCTAssertEqual(try body(of: stamp.first)["id"] as? String, "m1")
        XCTAssertEqual(model.cards.count, 1)
    }

    func testPullingFromYoursNotesTheOpen() async throws {
        let (model, transport) = make([
            .json(.get, "/api/yours/card", memory), .json(.post, "/api/yours/open", #"{"persisted":true}"#),
        ])
        model.pullItem(KeptItem(id: "m1", kind: .memory, name: "Trip notes", href: "/vault/memory?open=m1"))
        let stamped = await eventually { await self.openStamps(transport).count == 1 }
        XCTAssertTrue(stamped)
    }

    func testShowingThingsDoesNotNoteAnOpen() async {
        let (model, transport) = make([
            .json(.get, "/api/yours", tripList), .json(.get, "/api/yours/card", memory), .json(.post, "/api/yours/open", #"{"persisted":true}"#),
        ])
        model.show(.memories)
        let shown = await eventually { model.cards.count == 1 }
        XCTAssertTrue(shown)
        try? await Task.sleep(nanoseconds: 150_000_000)
        let stamps = await openStamps(transport)
        XCTAssertTrue(stamps.isEmpty, "nothing was opened, only shown")
    }
}
