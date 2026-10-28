import XCTest
@testable import HyperVaultKit

/// `shareTitle` of the web app's lib/chat/share.ts, with the cases of lib/__tests__/chat-share.test.ts first.
final class ChatShareTests: XCTestCase {
    // MARK: The web's own cases

    func testThePromptThatProducedTheReplyWins() {
        XCTAssertEqual(ChatShare.title(content: "Sure! Here's the plan...", sourcePrompt: "plan my week"), "plan my week")
    }

    func testWithoutAPromptTheFirstMeaningfulLineNamesItWithoutItsMarkdownLeadIn() {
        XCTAssertEqual(ChatShare.title(content: "## The Plan\nStep one..."), "The Plan")
        XCTAssertEqual(ChatShare.title(content: "\n\n- first bullet\nmore"), "first bullet")
    }

    func testTheTitleIsCappedAtEightyAndHasALastResortDefault() {
        XCTAssertEqual(ChatShare.title(content: String(repeating: "x", count: 200)).count, 80)
        XCTAssertEqual(ChatShare.title(content: "   \n  "), "Chat reply")
    }

    // MARK: The prompt

    func testAPromptHasItsWhiteSpaceRunsMadeIntoSingleSpaces() {
        XCTAssertEqual(ChatShare.title(content: "x", sourcePrompt: "  plan\n\tmy   week \n"), "plan my week")
        XCTAssertEqual(ChatShare.title(content: "x", sourcePrompt: "a\u{00A0}\u{3000}b"), "a b", "JavaScript's white space, not just the ASCII kind")
    }

    func testAPromptOfOnlyWhiteSpaceOrNothingFallsBackToTheReply() {
        XCTAssertEqual(ChatShare.title(content: "# Packing list\n- socks", sourcePrompt: " \n\t "), "Packing list")
        XCTAssertEqual(ChatShare.title(content: "# Packing list", sourcePrompt: ""), "Packing list")
        XCTAssertEqual(ChatShare.title(content: "# Packing list", sourcePrompt: nil), "Packing list")
    }

    func testAPromptIsKeptAsTypedApartFromItsSpacingAndCapped() {
        XCTAssertEqual(ChatShare.title(content: "x", sourcePrompt: "## Not a heading here"), "## Not a heading here", "the lead-in is stripped from a reply, never from the prompt")
        let long = String(repeating: "word ", count: 40)
        let title = ChatShare.title(content: "x", sourcePrompt: long)
        XCTAssertEqual(title.count, 80)
        XCTAssertTrue(long.hasPrefix(title))
    }

    // MARK: The reply

    func testTheLeadInIsEveryHashQuoteDashStarAndSpaceBeforeTheFirstWord() {
        XCTAssertEqual(ChatShare.title(content: "> quoted line"), "quoted line")
        XCTAssertEqual(ChatShare.title(content: "* item"), "item")
        XCTAssertEqual(ChatShare.title(content: " \t#> -*  mixed"), "mixed")
        XCTAssertEqual(ChatShare.title(content: "- [ ] todo"), "[ ] todo", "a bracket is not part of the lead-in")
        XCTAssertEqual(ChatShare.title(content: "**Bold start** rest"), "Bold start** rest", "only the front is stripped")
        XCTAssertEqual(ChatShare.title(content: "1. First"), "1. First")
    }

    func testALineOfOnlyLeadInIsSkipped() {
        XCTAssertEqual(ChatShare.title(content: "---\n***\n> \n# \nReal words"), "Real words")
        XCTAssertEqual(ChatShare.title(content: "---\n***"), "Chat reply")
    }

    func testLinesBreakOnNewlineOnlyAndAWindowsEndingDoesNotMatter() {
        XCTAssertEqual(ChatShare.title(content: "Title\r\nBody"), "Title", "\\r\\n is one character to Swift, two to JavaScript")
        XCTAssertEqual(ChatShare.title(content: "\r\n\r\n# Second try\r\n"), "Second try")
        XCTAssertEqual(ChatShare.title(content: "one\u{2028}two"), "one\u{2028}two", "a line separator is not a line break to split(\"\\n\")")
    }

    func testTheReplysFirstLineIsTrimmedWithJavaScriptsWhiteSpace() {
        XCTAssertEqual(ChatShare.title(content: "\u{FEFF}\u{00A0}Hello\u{2003}"), "Hello", "the byte order mark and no-break space are white space to trim()")
        XCTAssertEqual(ChatShare.title(content: "\u{0085}Hello"), "\u{0085}Hello", "U+0085 is not")
    }

    // MARK: The cap

    func testTheCapCountsUTF16UnitsAndNeverHalvesACharacter() {
        let base = String(repeating: "a", count: 78)
        XCTAssertEqual(ChatShare.title(content: base + "\u{1F600}"), base + "\u{1F600}", "78 units and an emoji of two is exactly 80")
        let tight = String(repeating: "a", count: 79)
        XCTAssertEqual(ChatShare.title(content: tight + "\u{1F600}"), tight, "a pair that straddles the limit is left out whole")
        XCTAssertEqual(ChatShare.title(content: String(repeating: "\u{00E9}", count: 90)).count, 80)
    }

    func testAnExactlyEightyCharacterLineIsLeftAlone() {
        let line = String(repeating: "b", count: 80)
        XCTAssertEqual(ChatShare.title(content: line), line)
        XCTAssertEqual(ChatShare.title(content: line + "c"), line)
    }

    // MARK: Saving it as a memory

    func testAReplySavedAsAMemoryIsSentTaggedChatFromChat() async throws {
        let transport = MockTransport(routes: [.json(.post, "/api/memories", #"{"id":"m1","title":"plan my week","tags":["chat"],"source":"chat","links":0,"branch":"main","message":"Kept in memory."}"#)])
        let api = HVClient(baseURL: URL(string: "https://hv.test")!, transport: transport, tokens: StaticTokenProvider(), retry: .none)
        let reply = "Here is a plan.\n\n- Monday: ferry"
        let draft = MemoryDraft(
            content: reply, title: ChatShare.title(content: reply, sourcePrompt: "plan my week"), tagsText: "chat", source: "chat"
        )
        let kept = try await api.send(.memoryCreate(draft))
        XCTAssertEqual(kept.message, "Kept in memory.")
        let allSent = await transport.requests
        let body = try XCTUnwrap(allSent.first?.httpBody)
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(object?["title"] as? String, "plan my week")
        XCTAssertEqual(object?["content"] as? String, reply)
        XCTAssertEqual(object?["tags"] as? [String], ["chat"])
        XCTAssertEqual(object?["source"] as? String, "chat")
        XCTAssertNil(object?["branch"], "the web names no branch: the server writes to main")
        XCTAssertEqual(HVCopy.keptInMemoryLine, "Kept in memory.")
    }
}
