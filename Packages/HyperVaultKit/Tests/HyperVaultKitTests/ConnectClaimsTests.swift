import XCTest
@testable import HyperVaultKit

/// The web's connect page promises that a key's row "reads Agent connected" once its setup challenge has passed. No route
/// tells the app that, so none of the prose it lays out may make the promise (handoff 5.10 and 10).
final class ConnectClaimsTests: XCTestCase {
    private static let pages: [(name: String, markdown: String)] = [
        ("Cursor", ConnectFixtures.cursor),
        ("Claude.ai", ConnectFixtures.claudeAI),
        ("Notion", ConnectFixtures.notion),
        ("Codex CLI", ConnectFixtures.codexCLI),
        ("HTTP", ConnectFixtures.http),
    ]

    func testNoPageLeavesTheClaimInItsProse() {
        for page in Self.pages {
            let guide = ConnectGuide.parse(page.markdown)
            let prose = guide.steps + guide.caveats + [guide.check, guide.warning].compactMap { $0 }
            XCTAssertFalse(prose.isEmpty, page.name)
            for line in prose {
                XCTAssertFalse(line.contains("Agent connected"), "\(page.name): \(line)")
            }
        }
    }

    func testTheFixturesDoCarryTheClaimToBeginWith() {
        // Without this the test above could pass on pages that never made the claim.
        for page in Self.pages {
            XCTAssertTrue(page.markdown.contains("Agent connected"), page.name)
        }
    }

    func testTheSentencesAroundTheClaimStay() {
        let cursor = ConnectGuide.parse(ConnectFixtures.cursor)
        XCTAssertEqual(
            cursor.check,
            "In a new Agent chat send: Run the HyperVault setup_challenge tool and complete the challenge it returns. Approve the tool call. An enabled toggle in Customize proves nothing about the key. If the call errors, open the Output panel and pick MCP Logs."
        )
        XCTAssertEqual(cursor.steps.count, 4, "no step was lost")

        // The claim was the last clause of the sentence: the clause before it stays.
        let claude = ConnectGuide.parse(ConnectFixtures.claudeAI)
        XCTAssertEqual(
            claude.check,
            "In a new chat with HyperVault switched on (+ then Connectors), send: Run the HyperVault setup_challenge tool and complete the challenge it returns. Claude should call setup_challenge, then read and write the challenge page."
        )

        // The claim was the first sentence of a step: the step keeps its second.
        let http = ConnectGuide.parse(ConnectFixtures.http)
        XCTAssertEqual(http.steps.count, 7)
        XCTAssertTrue(http.steps[5].hasPrefix("After that use /api/save, /api/memories and the rest;"))
        XCTAssertTrue(http.check?.hasSuffix("is the REST form of asking an MCP agent to run setup_challenge.") ?? false)
    }

    func testAnEntireCheckThatWasTheClaimGoesAway() {
        let guide = ConnectGuide(
            steps: ["Do it.", "The key's row now shows Agent connected."],
            check: "The key's row reads Agent connected.",
            caveats: ["Never paste the key into a shared chat."]
        ).withoutVerdictClaims()
        XCTAssertEqual(guide.steps, ["Do it."])
        XCTAssertNil(guide.check)
        XCTAssertEqual(guide.caveats, ["Never paste the key into a shared chat."])
    }

    func testOnlyTheClaimIsTakenOut() {
        let text = "Approve the tool call. An agent connected to a chat is not proof. Agents connected through MCP can list tools."
        XCTAssertEqual(ConnectGuide.removingVerdictClaims(text), text)
        XCTAssertNil(ConnectGuide.removingVerdictClaims("Once it is written, the key's row reads Agent connected."))
        XCTAssertEqual(
            ConnectGuide.removingVerdictClaims("Send it. Then the row reads Agent connected. Then use the API."),
            "Send it. Then use the API."
        )
    }

    // MARK: The instruction in front of the claim stays

    /// The sentence the live page of Amazon Bedrock AgentCore Gateway ends its check with: no comma before "and".
    func testTheInstructionBeforeAnAndWithNoCommaStays() {
        let check = "After the target reaches READY, send tools/list to the gateway's MCP endpoint. Then ask your agent to run setup_challenge through the gateway; a result with the key's challenge slug means the key works. Finish the challenge and the key's row in the Agent keys card on the Account page reads Agent connected."
        let guide = ConnectGuide(steps: ["Do it."], check: check).withoutVerdictClaims()
        XCTAssertEqual(
            guide.check,
            "After the target reaches READY, send tools/list to the gateway's MCP endpoint. Then ask your agent to run setup_challenge through the gateway; a result with the key's challenge slug means the key works. Finish the challenge."
        )
    }

    /// Each way the web (or a page like it) can join the instruction to the claim, and the instruction that has to survive.
    func testNoSentenceLosesItsInstructionToTheClaimThatFollowsIt() {
        let cases: [(sentence: String, kept: String)] = [
            ("Finish the challenge and the key's row reads Agent connected.", "Finish the challenge."),
            ("Finish the challenge, and the key's row reads Agent connected.", "Finish the challenge."),
            ("Run the tool; the key's row then shows Agent connected.", "Run the tool."),
            ("Complete it, then check that the row says Agent connected.", "Complete it."),
            ("Complete it, then check that the row says Agent connected; if not, retry.", "Complete it."),
            ("Send the request: the key's row in the Agent keys card shows Agent connected.", "Send the request."),
            ("Then let the agent finish the challenge (read_artifact, edit, write_artifact), and the key's row in the Agent keys card on the Account page reads Agent connected.", "Then let the agent finish the challenge (read_artifact, edit, write_artifact)."),
            // The join inside the claim's own clause is not where the instruction ends.
            ("Finish it and the key's row and its card read Agent connected.", "Finish it."),
        ]
        for (sentence, kept) in cases {
            XCTAssertEqual(ConnectGuide.removingVerdictClaims(sentence), kept, sentence)
        }
    }

    func testASentenceThatIsOnlyTheClaimStillGoesWholeEvenWithAJoinInIt() {
        for sentence in [
            "Once the challenge is written, the key's row in the Agent keys card on the Account page reads Agent connected.",
            "The key's row in the Agent keys card now shows Agent connected.",
            // A lead-in between the join and the claim: the words before the join would be left hanging.
            "Once you finish and open the page, the key's row reads Agent connected.",
        ] {
            XCTAssertNil(ConnectGuide.removingVerdictClaims(sentence), sentence)
        }
    }

    func testStringsToPasteAreNeverTouched() {
        let paste = ConnectGuide.Paste(label: "A line", language: "text", text: "The row reads Agent connected.")
        let guide = ConnectGuide(steps: ["One."], pastes: [paste]).withoutVerdictClaims()
        XCTAssertEqual(guide.pastes, [paste])
    }
}
