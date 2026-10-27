import XCTest
@testable import HyperVaultKit

/// The first-run story's words are the web's (`lib/copy.ts`), and they follow its rules: only agents that can read a
/// saved value are named as readers, nothing a newcomer should not meet yet, plain ASCII.
final class FirstRunCopyTests: XCTestCase {
    private var vaultSection: [String] {
        [
            HVCopy.landingVaultHeading, HVCopy.landingVaultSaveLine, HVCopy.landingVaultUseLine,
            HVCopy.landingVaultLockLine, HVCopy.landingVaultAgents,
        ]
    }

    /// What a first-run surface may say: the vault section, and the lines the story shares with the canvas.
    private var firstRunLines: [String] {
        vaultSection + [HVCopy.landingLine, HVCopy.productSentence, HVCopy.onlyYouLine, HVCopy.keepingLine, HVCopy.keptLine]
    }

    func testTheVaultSectionIsTheWebsVerbatim() {
        XCTAssertEqual(HVCopy.landingVaultHeading, "Not tied to one AI company")
        XCTAssertEqual(HVCopy.landingVaultSaveLine, "Save a login, a card, your contact info or an API key once.")
        XCTAssertEqual(HVCopy.landingVaultAgents, "Claude Code, Codex, Cursor, Gemini CLI, Grok Build or your own script")
        XCTAssertEqual(
            HVCopy.landingVaultUseLine,
            "Your agents can use it, whether that is Claude Code, Codex, Cursor, Gemini CLI, Grok Build or your own script. Each one gets only what you allow."
        )
        XCTAssertEqual(
            HVCopy.landingVaultLockLine,
            "Passwords, card numbers, API keys and each full entry are encrypted when you save them and never shown again. Only the name you give each one and a short label, like a username, an email or a card's brand and last four digits, stay visible so you can tell them apart."
        )
    }

    func testTheReadersAreTheListTheLineNames() {
        XCTAssertEqual(HVCopy.landingVaultReaders.count, 6)
        let head = HVCopy.landingVaultReaders.dropLast().joined(separator: ", ")
        XCTAssertEqual(HVCopy.landingVaultAgents, "\(head) or \(HVCopy.landingVaultReaders.last ?? "")")
        XCTAssertTrue(HVCopy.landingVaultUseLine.contains(HVCopy.landingVaultAgents))
    }

    func testOnlyAgentsThatCanReadAValueAreNamedAndTheLineEndsWithWhatThePersonControls() throws {
        let chatApps = try NSRegularExpression(
            pattern: #"ChatGPT|\bClaude\b(?! Code)|\bGemini\b(?! CLI)|\bGrok\b(?! Build)|\bany AI\b|local model"#,
            options: [.caseInsensitive]
        )
        for line in [HVCopy.landingVaultUseLine, HVCopy.landingVaultAgents] {
            XCTAssertEqual(chatApps.numberOfMatches(in: line, range: NSRange(line.startIndex..., in: line)), 0, line)
        }
        XCTAssertTrue(HVCopy.landingVaultUseLine.contains("only what you allow"))
        let heading = HVCopy.landingVaultHeading.lowercased()
        for word in ["chatbot", "chat app", "assistant", "any ai"] {
            XCTAssertFalse(heading.contains(word), "a chat app can connect but cannot read a saved value")
        }
    }

    func testTheLockLineSaysWhatStaysVisibleInTheSameBreathAsWhatIsHidden() {
        XCTAssertTrue(HVCopy.landingVaultLockLine.contains("never shown again"))
        XCTAssertTrue(HVCopy.landingVaultLockLine.contains("stay visible"))
    }

    func testNothingTheStoryShowsHasAWordFirstRunSurfacesAvoid() throws {
        let banned = try NSRegularExpression(
            pattern: #"\b(?:MCP|tombstone|GraphRAG|grant|artifact\s+node|subdomain|AgentVault|wiki|vault\s+item)"#,
            options: [.caseInsensitive]
        )
        for line in firstRunLines {
            XCTAssertEqual(banned.numberOfMatches(in: line, range: NSRange(line.startIndex..., in: line)), 0, line)
        }
    }

    func testTheStoryHasNoPlanNoPriceAndNoLink() throws {
        let selling = try NSRegularExpression(pattern: #"upgrade|pricing|\bplans?\b|\bpro\b|\$|/|https?:"#, options: [.caseInsensitive])
        for line in vaultSection {
            XCTAssertEqual(selling.numberOfMatches(in: line, range: NSRange(line.startIndex..., in: line)), 0, line)
        }
    }

    func testTheStoryIsPlainASCII() {
        for line in firstRunLines {
            XCTAssertTrue(line.unicodeScalars.allSatisfy(\.isASCII), line)
        }
    }
}
