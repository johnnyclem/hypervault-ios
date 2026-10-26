import XCTest
@testable import HyperVaultKit

/// Ported from the web app's lib/__tests__/canvas-commands.test.ts: the same words must
/// give the same answer on either. Generated once; edit by hand from here.
final class CanvasCommandTests: XCTestCase {
    func testCommands() {
        let cases: [(String, CanvasCommand)] = [
            ("Keep this.", .keep),
            ("Show my memories.", .show(.memories)),
            ("Pull the co-parenting notes onto the page.", .pull(query: "co-parenting notes")),
            ("What keys does this agent have?", .agentKeys),
            ("Hide that.", .hideAll),
            ("help", .help),
            ("Help!", .help),
            ("help me", .help),
            ("what does this do?", .help),
            ("What does this page do", .help),
            ("what can you do?", .help),
            ("What do you do?", .help),
            ("what can I do here?", .help),
            ("how does this work?", .help),
            ("how do I use this?", .help),
            ("keep this", .keep),
            ("Keep that", .keep),
            ("keep this one", .keep),
            ("KEEP THIS!", .keep),
            ("  keep   this  ", .keep),
            ("please keep this", .keep),
            ("can you keep this?", .keep),
            ("could you please keep that", .keep),
            ("keep this, please", .keep),
            ("hide that", .hideAll),
            ("Hide this", .hideAll),
            ("hide it", .hideAll),
            ("hide them", .hideAll),
            ("hide everything", .hideAll),
            ("Hide everything!", .hideAll),
            ("hide all", .hideAll),
            ("hide all of it", .hideAll),
            ("hide them all", .hideAll),
            ("hide everything please, thanks", .hideAll),
            ("hide everything on the page", .hideAll),
            ("hide the cards", .hideAll),
            ("hide all cards", .hideAll),
            ("clear the canvas", .hideAll),
            ("clear the page", .hideAll),
            ("can you hide that?", .hideAll),
            ("hide the co-parenting notes", .hide(name: "co-parenting notes")),
            ("Hide Trip plan", .hide(name: "Trip plan")),
            ("hide \"Notes on co-parenting\"", .hide(name: "Notes on co-parenting")),
            ("hide the “Trip to Paris”", .hide(name: "Trip to Paris")),
            ("please hide my OpenAI key", .hide(name: "OpenAI key")),
            ("show my memories", .show(.memories)),
            ("Show me my memories", .show(.memories)),
            ("show me all of my memories", .show(.memories)),
            ("show my files", .show(.files)),
            ("show files", .show(.files)),
            ("show all my keys", .show(.keys)),
            ("show me my stuff", .show(.stuff)),
            ("Show my stuff.", .show(.stuff)),
            ("show me everything", .show(.stuff)),
            ("can you show my memories?", .show(.memories)),
            ("pull the co-parenting notes onto the page", .pull(query: "co-parenting notes")),
            ("Pull my passport scan onto the canvas", .pull(query: "passport scan")),
            ("pull Trip plan on the page", .pull(query: "Trip plan")),
            ("pull a recipe onto my page", .pull(query: "recipe")),
            ("pull \"Q3 budget\" onto the page", .pull(query: "Q3 budget")),
            ("pull the notes from Paris onto the page", .pull(query: "notes from Paris")),
            ("can you pull the budget onto the page please", .pull(query: "budget")),
            ("what keys does this agent have", .agentKeys),
            ("What keys does my agent have?", .agentKeys),
            ("which keys can this agent use", .agentKeys),
            ("What keys does the assistant have access to?", .agentKeys),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(CanvasCommandParser.parse(text), expected, "\(text.debugDescription)")
        }
    }

    func testMessagesThatAreJustMessages() {
        let cases: [String] = [
            "what is this",
            "what is this page about",
            "help me write a cover letter",
            "what does this function do",
            "what can you do with a PDF",
            "can you show my memories of Paris in a poem",
            "show my memories and my files",
            "show my keys to my coworker",
            "show me the weather",
            "show me everything about Paris",
            "keep this in mind when you write the summary",
            "keep this conversation friendly",
            "keep this safe",
            "keep it simple",
            "keep going",
            "hide that and then summarize the thread",
            "hide everything except the notes",
            "hide the sidebar from the design",
            "hide the sidebar when the screen is narrow",
            "hide notes on co-parenting",
            "hide the footer on mobile",
            "hide them behind a modal",
            "hide this behind a toggle",
            "hide your reasoning",
            "hide yourself",
            "hide me",
            "how do I hide a div",
            "I want to keep this",
            "why would you hide that",
            "what keys does a piano have",
            "what keys does this song use",
            "which keys can I use to unlock the door",
            "what keys does this agent have in common with my agent",
            "what keys does this app have",
            "what keys does this agent have to enter",
            "don't hide that",
            "never keep this",
            "git pull origin main",
            "pull the latest changes from main",
            "pull up the quarterly report",
            "pull request review please",
            "pull the notes",
            "pull it onto the page",
            "pull that onto the page",
            "pull everything onto the canvas",
            "hide this one",
            "hide",
            "keep",
            "show",
            "show my",
            "pull onto the page",
            "clear the page of cards",
            "clear the cache",
            "",
            "   ",
            "...",
            "please",
            "thanks",
            "hello",
            "tell me a story about a vault",
            "What is HyperVault?",
        ]
        for text in cases {
            XCTAssertNil(CanvasCommandParser.parse(text), "\(text.debugDescription) should go to chat")
        }
    }

    func testPolitenessIsNotReadOutOfTheEndOfAWord() {
        XCTAssertNil(CanvasCommandParser.parse("show my keysplease"))
        XCTAssertNil(CanvasCommandParser.parse("keep thisthanks"))
    }

    func testLongMessagesAreNeverCommands() {
        let paste = "keep this: " + String(repeating: "the quick brown fox jumps over the lazy dog. ", count: 20)
        XCTAssertNil(CanvasCommandParser.parse(paste))
        XCTAssertNil(CanvasCommandParser.parse("hide that " + String(repeating: "x", count: 200)))
    }

    func testTheEightyCharacterCap() {
        XCTAssertEqual(CanvasCommandParser.maxCommandChars, 80)
        func exactly(_ n: Int) -> String { "pull " + String(repeating: "x", count: n - "pull  onto the page".count) + " onto the page" }
        XCTAssertEqual(exactly(80).count, 80)
        XCTAssertEqual(CanvasCommandParser.parse(exactly(80)), .pull(query: String(repeating: "x", count: 80 - "pull  onto the page".count)))
        XCTAssertNil(CanvasCommandParser.parse(exactly(81)))
        XCTAssertNotNil(CanvasCommandParser.parse("   " + exactly(80) + "   "))
    }

    func testMultiLineMessagesAreNotCommandsWithAPasteUnderThem() {
        XCTAssertNil(CanvasCommandParser.parse("hide that\nthen write a poem"))
        XCTAssertEqual(CanvasCommandParser.parse("hide that\n"), .hideAll)
    }
}
