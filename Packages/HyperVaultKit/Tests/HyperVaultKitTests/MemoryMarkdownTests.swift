import XCTest
@testable import HyperVaultKit

final class MemoryMarkdownTests: XCTestCase {
    func testHeadingsParagraphsAndRules() {
        let blocks = MarkdownBlocks.parse("# Trip notes\n\nBook the ferry.\nBring passports.\n\n---\n\n### Later ###\nSome more")
        XCTAssertEqual(blocks, [
            .heading(level: 1, text: "Trip notes"),
            .paragraph("Book the ferry.\nBring passports."),
            .rule,
            .heading(level: 3, text: "Later"),
            .paragraph("Some more"),
        ])
    }

    func testListsBulletedAndNumbered() {
        let blocks = MarkdownBlocks.parse("- one\n- two\n  - nested\n* three\n\n1. first\n2. second\n3) third")
        XCTAssertEqual(blocks, [
            .list(items: [
                MarkdownListItem(text: "one"), MarkdownListItem(text: "two"),
                MarkdownListItem(text: "nested", depth: 1), MarkdownListItem(text: "three"),
            ], ordered: false),
            .list(items: [
                MarkdownListItem(text: "first", number: 1), MarkdownListItem(text: "second", number: 2), MarkdownListItem(text: "third", number: 3),
            ], ordered: true),
        ])
    }

    func testAWrappedListItemJoinsItsContinuation() {
        let blocks = MarkdownBlocks.parse("- a long item that\n  wraps onto a second line\n- next")
        XCTAssertEqual(blocks, [.list(items: [MarkdownListItem(text: "a long item that wraps onto a second line"), MarkdownListItem(text: "next")], ordered: false)])
    }

    func testCodeFencesKeepTheirTextAndNothingInsideIsParsed() {
        let blocks = MarkdownBlocks.parse("Before\n```swift\n# not a heading\n- not a list\n```\nAfter")
        XCTAssertEqual(blocks, [
            .paragraph("Before"),
            .code(language: "swift", text: "# not a heading\n- not a list"),
            .paragraph("After"),
        ])
        // An unclosed fence runs to the end.
        XCTAssertEqual(MarkdownBlocks.parse("```\nlet x = 1"), [.code(language: nil, text: "let x = 1")])
    }

    func testQuotes() {
        XCTAssertEqual(MarkdownBlocks.parse("> said one\n> said two\n\nafter"), [.quote("said one\nsaid two"), .paragraph("after")])
    }

    func testPlainTextAndTranscriptsStayParagraphs() {
        let transcript = "User: What did we decide?\nAssistant: Passkeys.\n\nUser: And the fallback?"
        XCTAssertEqual(MarkdownBlocks.parse(transcript), [
            .paragraph("User: What did we decide?\nAssistant: Passkeys."),
            .paragraph("User: And the fallback?"),
        ])
        XCTAssertEqual(MarkdownBlocks.parse(""), [])
        XCTAssertEqual(MarkdownBlocks.parse("   \n\n  "), [])
    }

    func testThingsThatLookLikeMarkersButAreNot() {
        XCTAssertEqual(MarkdownBlocks.parse("#hashtag stays text"), [.paragraph("#hashtag stays text")])
        XCTAssertEqual(MarkdownBlocks.parse("**bold** start"), [.paragraph("**bold** start")])
        XCTAssertEqual(MarkdownBlocks.parse("2026. A year."), [.paragraph("2026. A year.")])
        XCTAssertEqual(MarkdownBlocks.parse("* * *"), [.rule])
        XCTAssertEqual(MarkdownBlocks.parse("####### seven"), [.paragraph("####### seven")])
    }

    func testWindowsLineEndings() {
        XCTAssertEqual(MarkdownBlocks.parse("# T\r\n\r\ntext"), [.heading(level: 1, text: "T"), .paragraph("text")])
    }
}
