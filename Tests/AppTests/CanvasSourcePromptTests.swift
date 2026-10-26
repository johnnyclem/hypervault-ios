import HyperVaultKit
import XCTest
@testable import HyperVault

/// What the canvas sends the server as the prompt a kept reply came from: counted as the server counts.
@MainActor
final class CanvasSourcePromptTests: CanvasTestCase {
    func testKeepingAReplyToALongCRLFPromptStaysWithinTheServersLimit() async throws {
        let (model, transport) = make([
            .json(.get, "/api/backends", oneModel), .json(.post, "/api/chat", reply), .json(.post, "/api/keep", kept),
        ])
        await model.loadBackends()
        // 15,000 Characters (a CRLF is one) but 18,000 UTF-16 units, which is what the server counts.
        let prompt = String(repeating: "line\r\n", count: 3_000)
        XCTAssertGreaterThan(prompt.utf16.count, 10_000)
        model.draft = prompt
        await model.send()
        model.keepReply(at: 1)

        let sent = await eventually { await transport.requests(matching: "/api/keep").count == 1 }
        XCTAssertTrue(sent)
        let keep = await transport.requests(matching: "/api/keep")
        let source = try XCTUnwrap(try body(of: keep.first)["source_prompt"] as? String)
        XCTAssertLessThanOrEqual(source.utf16.count, 10_000)
        XCTAssertGreaterThan(source.utf16.count, 9_990, "clipped to the limit, not dropped")
    }

    func testKeepingAReplyToAnEmojiPromptStaysWithinTheServersLimit() async throws {
        let (model, transport) = make([
            .json(.get, "/api/backends", oneModel), .json(.post, "/api/chat", reply), .json(.post, "/api/keep", kept),
        ])
        await model.loadBackends()
        // 6,000 Characters, which the old cut left whole, but 12,000 UTF-16 units.
        model.draft = String(repeating: "\u{1F600}", count: 6_000)
        await model.send()
        model.keepReply(at: 1)

        let sent = await eventually { await transport.requests(matching: "/api/keep").count == 1 }
        XCTAssertTrue(sent)
        let keep = await transport.requests(matching: "/api/keep")
        let source = try XCTUnwrap(try body(of: keep.first)["source_prompt"] as? String)
        XCTAssertEqual(source.utf16.count, 10_000)
        XCTAssertFalse(source.contains("\u{FFFD}"))
    }

    func testAPromptWithinTheLimitIsSentAsItIs() async throws {
        let (model, transport) = make([
            .json(.get, "/api/backends", oneModel), .json(.post, "/api/chat", reply), .json(.post, "/api/keep", kept),
        ])
        await model.loadBackends()
        model.draft = "Plan my week \u{1F600}"
        await model.send()
        model.keepReply(at: 1)

        let sent = await eventually { await transport.requests(matching: "/api/keep").count == 1 }
        XCTAssertTrue(sent)
        let keep = await transport.requests(matching: "/api/keep")
        XCTAssertEqual(try body(of: keep.first)["source_prompt"] as? String, "Plan my week \u{1F600}")
    }

    func testTheSourcePromptIsClippedBetweenCharactersAndTrimmed() {
        let limit = SourcePrompt.limit
        XCTAssertEqual(SourcePrompt.clipped(String(repeating: "a", count: limit))?.utf16.count, limit)
        XCTAssertEqual(SourcePrompt.clipped(String(repeating: "a", count: limit + 5))?.utf16.count, limit)
        XCTAssertEqual(SourcePrompt.clipped("  \n a thought \r\n "), "a thought")
        XCTAssertNil(SourcePrompt.clipped(" \n\t "))
        XCTAssertNil(SourcePrompt.clipped(""))

        // A pair of units, or a family joined by zero-width joiners, is never cut through.
        XCTAssertEqual(SourcePrompt.clipped("\u{1F600}\u{1F600}\u{1F600}", to: 5), "\u{1F600}\u{1F600}")
        XCTAssertEqual(SourcePrompt.clipped("ab\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", to: 8), "ab")
        XCTAssertEqual(SourcePrompt.clipped("a\u{1F600}b", to: 2), "a")
        XCTAssertEqual(SourcePrompt.clipped("a\r\nb", to: 2), "a", "a CRLF is two units and one character")
        XCTAssertEqual(SourcePrompt.clipped("a\r\nb", to: 3), "a\r\n")
    }
}
