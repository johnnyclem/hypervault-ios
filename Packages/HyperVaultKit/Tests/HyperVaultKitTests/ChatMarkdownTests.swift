import XCTest
@testable import HyperVaultKit

final class ChatMarkdownTests: XCTestCase {
    func testParagraphsHeadingsAndRules() {
        let blocks = ChatMarkdown.parse("# Title\n\nFirst line\nsecond line\n\n---\n\n### Smaller ###\nAfter")
        XCTAssertEqual(blocks, [
            .heading(level: 1, text: "Title"),
            .paragraph("First line\nsecond line"),
            .rule,
            .heading(level: 3, text: "Smaller"),
            .paragraph("After"),
        ])
    }

    func testFencedCodeKeepsItsLanguageAndBlankLines() {
        let text = "Here:\n\n```swift\nlet a = 1\n\nlet b = 2\n```\nDone."
        XCTAssertEqual(ChatMarkdown.parse(text), [
            .paragraph("Here:"),
            .code(language: "swift", code: "let a = 1\n\nlet b = 2"),
            .paragraph("Done."),
        ])
    }

    func testAnUnclosedFenceRunsToTheEndWhileAReplyIsStillBeingWritten() {
        XCTAssertEqual(ChatMarkdown.parse("```py\nprint(1)\nprint(2"), [.code(language: "py", code: "print(1)\nprint(2")])
        // A longer fence is not closed by a shorter one inside it.
        XCTAssertEqual(
            ChatMarkdown.parse("````md\n```\ninner\n```\n````"),
            [.code(language: "md", code: "```\ninner\n```")]
        )
        XCTAssertEqual(ChatMarkdown.parse("~~~\nx\n~~~"), [.code(language: nil, code: "x")])
    }

    func testInlineBackticksAreNotAFence() {
        XCTAssertEqual(ChatMarkdown.parse("```not a fence``` really"), [.paragraph("```not a fence``` really")])
    }

    func testListsNestAndNumber() {
        let blocks = ChatMarkdown.parse("- one\n- two\n  - nested\n    - deeper\n- three\n\n1. first\n2) second\n   wraps here\n3. third")
        guard case .list(let bullets) = blocks[0], case .list(let numbers) = blocks[1] else { return XCTFail("\(blocks)") }
        XCTAssertEqual(bullets.map(\.text), ["one", "two", "nested", "deeper", "three"])
        XCTAssertEqual(bullets.map(\.depth), [0, 0, 1, 2, 0])
        XCTAssertEqual(bullets[0].marker, "\u{2022}")
        XCTAssertEqual(numbers.map(\.marker), ["1.", "2.", "3."])
        XCTAssertEqual(numbers[1].text, "second\nwraps here")
    }

    func testTaskItemsAndLooseLists() {
        let blocks = ChatMarkdown.parse("- [ ] write\n\n- [x] ship")
        guard case .list(let items) = blocks[0] else { return XCTFail("\(blocks)") }
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(items.map(\.checked), [false, true])
        XCTAssertEqual(items.map(\.text), ["write", "ship"])
    }

    func testRulesAreNotBullets() {
        XCTAssertEqual(ChatMarkdown.parse("* * *"), [.rule])
        XCTAssertEqual(ChatMarkdown.parse("-- not a list"), [.paragraph("-- not a list")])
    }

    func testQuotesRecurse() {
        XCTAssertEqual(
            ChatMarkdown.parse("> Wise words\n> - one\n> - two"),
            [.quote([.paragraph("Wise words"), .list([
                ChatMarkdownListItem(marker: "\u{2022}", depth: 0, text: "one"),
                ChatMarkdownListItem(marker: "\u{2022}", depth: 0, text: "two"),
            ])])]
        )
    }

    func testTables() {
        let text = "| Name | Qty |\n| --- | ---: |\n| Apples | 3 |\n| Pears \\| ripe | 4 |\n\nAfter"
        XCTAssertEqual(ChatMarkdown.parse(text), [
            .table(header: ["Name", "Qty"], rows: [["Apples", "3"], ["Pears | ripe", "4"]]),
            .paragraph("After"),
        ])
        // A pipe in prose is not a table.
        XCTAssertEqual(ChatMarkdown.parse("a | b\nplain"), [.paragraph("a | b\nplain")])
    }

    func testWindowsLineEndingsAndEmptyText() {
        XCTAssertEqual(ChatMarkdown.parse("a\r\n\r\nb"), [.paragraph("a"), .paragraph("b")])
        XCTAssertEqual(ChatMarkdown.parse(""), [])
        XCTAssertEqual(ChatMarkdown.parse("   \n  "), [])
    }

    func testPlainTextForReadingAloud() {
        let text = "## Plan\n\nUse **bold**, _soft_ and `code`, see [the docs](https://x.test).\n\n```js\nrun()\n```\n\n- one\n- two"
        XCTAssertEqual(
            ChatMarkdown.plainText(text),
            "Plan\n\nUse bold, soft and code, see the docs.\n\nCode block.\n\none\ntwo"
        )
        XCTAssertEqual(ChatMarkdown.plainInline("snake_case_name and 2*3*4"), "snake_case_name and 2*3*4")
    }
}

final class ChatToolProtocolTests: XCTestCase {
    func testParsesTheFirstToolRequestAndTheWordsBeforeIt() throws {
        let text = "Checking.\n\n```tool\n{\"intent\": \"fetch a url\", \"args\": {\"url\": \"https://x.test\"}}\n```"
        let call = try XCTUnwrap(ChatToolProtocol.parseIntentCall(text))
        XCTAssertEqual(call.intent, "fetch a url")
        XCTAssertEqual(call.args["url"], "https://x.test")
        XCTAssertEqual(call.visibleText, "Checking.")
    }

    func testBackticksInsideJSONStringsDoNotCutTheBlock() throws {
        let text = "```tool\n{\"intent\":\"save html\",\"args\":{\"content\":\"<pre>```html\\n<b>x</b>\\n```</pre>\"}}\n```"
        let call = try XCTUnwrap(ChatToolProtocol.parseIntentCall(text))
        XCTAssertEqual(call.intent, "save html")
        XCTAssertEqual(call.args["content"]?.string?.contains("```html"), true)
    }

    func testMalformedBlocksAreJustText() {
        XCTAssertNil(ChatToolProtocol.parseIntentCall("no block here"))
        XCTAssertNil(ChatToolProtocol.parseIntentCall("```tool\n{\"intent\": \"x\"\n```"))        // never closes
        XCTAssertNil(ChatToolProtocol.parseIntentCall("```tool\n{\"args\": {}}\n```"))             // no intent
        XCTAssertNil(ChatToolProtocol.parseIntentCall("```tool\n{\"intent\":\"x\",\"args\":[1]}\n```"))  // args not an object
        XCTAssertNil(ChatToolProtocol.parseIntentCall("```tool-result\n{\"intent\":\"x\"}\n```"))  // a result, not a request
    }

    func testToolResultsBecomeSteps() throws {
        let ok = "```tool-result\n{\"intent\":\"list tasks\",\"tool\":\"tasks.list\",\"ok\":true,\"confidence\":0.5,\"tier\":\"low\",\"content\":{\"n\":3}}\n```"
        let step = try XCTUnwrap(ChatToolProtocol.parseToolResult(ok))
        XCTAssertTrue(step.ok)
        XCTAssertEqual(step.preview, "{\"n\":3}")
        XCTAssertEqual(step.tierLabel, "low 50%")

        let refine = "```tool-result\n{\"intent\":\"mail\",\"tool\":null,\"ok\":false,\"refinement\":{\"question\":\"Which?\",\"options\":[{\"label\":\"Gmail\",\"intent\":\"send gmail\",\"canonical\":\"p.send\"}]}}\n```"
        let asked = try XCTUnwrap(ChatToolProtocol.parseToolResult(refine))
        XCTAssertFalse(asked.ok)
        XCTAssertEqual(asked.refinement?.question, "Which?")
        XCTAssertEqual(asked.refinement?.options.first?.canonical, "p.send")

        let failed = "```tool-result\n{\"intent\":\"x\",\"tool\":null,\"ok\":false,\"error\":\"timed out\"}\n```"
        XCTAssertEqual(ChatToolProtocol.parseToolResult(failed)?.detail, "timed out")
        XCTAssertNil(ChatToolProtocol.parseToolResult("plain words"))
    }
}
