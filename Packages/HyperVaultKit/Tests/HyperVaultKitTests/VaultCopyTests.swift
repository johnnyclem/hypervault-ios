import XCTest
@testable import HyperVaultKit

/// The Vault screens' sentences, pinned to the text they come from. Each string is copied from `lib/copy.ts` (the
/// file and line are beside it) or from the handoff section that quotes the vault component's own words.
final class VaultCopyTests: XCTestCase {
    // MARK: lib/copy.ts

    func testTheRenameStrings() {
        XCTAssertEqual(VaultCopy.renameLabel, "Rename")  // lib/copy.ts:302 RENAME_LABEL
        XCTAssertEqual(VaultCopy.renameFieldLabel("visa-4242"), "New name for visa-4242")  // :320 renameFieldLabel
        XCTAssertEqual(VaultCopy.renameFieldLabel(""), "New name for ")
        XCTAssertEqual(VaultCopy.renameWarning, "Agents that ask for the old name will stop finding it.")  // :325 RENAME_WARNING
        XCTAssertEqual(VaultCopy.renameHint, "Use 1 to 100 letters, digits, dots, dashes or underscores.")  // :326 RENAME_HINT
    }

    func testTheRenameHintIsNotTheAddFormsHint() {
        XCTAssertNotEqual(VaultCopy.renameHint, VaultItems.nameHint)
        // The add form's has an en dash (U+2013); the rename field's is plain ASCII.
        XCTAssertTrue(VaultItems.nameHint.unicodeScalars.contains { $0.value == 0x2013 })
        XCTAssertTrue(VaultCopy.renameHint.unicodeScalars.allSatisfy { $0.value < 0x80 })
        XCTAssertEqual(VaultItems.nameHint, "1\u{2013}100 chars: letters, digits, dot, dash, or underscore.")  // name.ts:12 SECRET_NAME_HINT
    }

    func testTheLinesForAChangeThatDidNotGoThrough() {
        XCTAssertEqual(VaultCopy.keyChangeFailedLine, "That did not go through. Try again.")  // lib/copy.ts:329
        XCTAssertEqual(VaultCopy.keyChangeOfflineLine, "Network hiccup. That did not go through. Try again.")  // :330
        XCTAssertTrue(VaultCopy.keyChangeOfflineLine.unicodeScalars.allSatisfy { $0.value < 0x80 })
    }

    func testTheLoadingLine() {
        XCTAssertEqual(VaultCopy.loadingLine, "Loading...")  // lib/copy.ts:112 YOURS_LOADING_LINE
        XCTAssertEqual(VaultCopy.loadingLine.count, 10)  // three ASCII dots, not an ellipsis
    }

    func testTheLoadLinesTheVaultReusesAreTheWebs() {
        XCTAssertEqual(HVCopy.yoursFailedLine, "That did not load. Try again.")  // lib/copy.ts:113 YOURS_FAILED_LINE
        XCTAssertEqual(HVCopy.yoursOfflineLine, "Network hiccup. That did not load. Try again.")  // :114 YOURS_OFFLINE_LINE
    }

    // MARK: The handoff

    func testTheDetailSheetsLines() {
        XCTAssertEqual(VaultCopy.createdLabel, "Created")  // handoff 5.10 item 2
        XCTAssertEqual(VaultCopy.sheetNeverUsedLine, "Never")  // 5.10 "Last used" ("Never" when no agent has read it)
        XCTAssertEqual(VaultCopy.valueNeverShownLine, "The value is encrypted and never shown again.")  // 5.10 item 3
        XCTAssertEqual(VaultCopy.allowedKeysHeading, "Allowed keys")  // 5.10 item 4
        XCTAssertEqual(VaultCopy.allowedKeysLine, "Only the agent keys switched on here can read it.")
        XCTAssertEqual(VaultCopy.howAgentReadsHeading, "How an agent reads it")  // 5.10 item 5
        XCTAssertEqual(VaultCopy.allowedKeyGetsLine, "An allowed key gets back { name, kind, value }.")
        XCTAssertEqual(VaultCopy.exactValueLine, "The value is exactly what you saved.")
        XCTAssertEqual(
            VaultCopy.jsonValueLine(fields: VaultItems.valueFieldsLine(.card)),
            "The value is JSON with cardholder, number, expMonth, expYear and cvc; empty fields are left out."
        )
        XCTAssertEqual(VaultCopy.deleteConfirmationMessage, "Deleting it cuts off every agent at once.")  // 4.7, 5.10 item 6
    }

    func testTheNoAgentKeysLineIsTheWebsAndNotTheOldOne() {
        XCTAssertEqual(VaultCopy.noAgentKeysLine, "No agent keys yet. Generate one under Agent keys, then allow it here.")  // handoff 4.6
        // It points at the pane the You page calls "Agent keys".
        XCTAssertTrue(VaultCopy.noAgentKeysLine.contains(AccountPane.keys.label))
        XCTAssertNotEqual(VaultCopy.noAgentKeysLine, "No agent keys yet. Connect an agent, then allow it here.")
    }

    func testTheCopyNeverNamesWhatTheyAreNot() {
        // Allow and revoke, never "grant", to a person (handoff 8.2); nothing says it is connected or verified.
        let all = [
            VaultCopy.renameLabel, VaultCopy.renameFieldLabel("x"), VaultCopy.renameWarning, VaultCopy.renameHint,
            VaultCopy.keyChangeFailedLine, VaultCopy.keyChangeOfflineLine, VaultCopy.loadingLine, VaultCopy.createdLabel,
            VaultCopy.valueNeverShownLine, VaultCopy.allowedKeysHeading, VaultCopy.allowedKeysLine, VaultCopy.noAgentKeysLine,
            VaultCopy.howAgentReadsHeading, VaultCopy.allowedKeyGetsLine, VaultCopy.exactValueLine,
            VaultCopy.deleteConfirmationMessage,
        ]
        for line in all {
            XCTAssertFalse(line.lowercased().contains("grant"), line)
            XCTAssertFalse(line.lowercased().contains("connected"), line)
        }
    }

    // MARK: Last used

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    func testTheRowsLastUsedLine() {
        XCTAssertEqual(VaultCopy.rowLastUsedLine(nil, now: now), "Never used")
        let cases: [(TimeInterval, String)] = [
            (0, "Last used just now"), (59, "Last used just now"), (60, "Last used 1 min ago"), (3 * 3600, "Last used 3 hr ago"),
            (30 * 3600, "Last used yesterday"), (5 * 86_400, "Last used 5 days ago"), (40 * 86_400, "Last used 1 month ago"),
            (90 * 86_400, "Last used 3 months ago"), (400 * 86_400, "Last used 1 year ago"), (800 * 86_400, "Last used 2 years ago"),
            (-120, "Last used just now"),
        ]
        for (seconds, line) in cases { XCTAssertEqual(VaultCopy.rowLastUsedLine(ago(seconds), now: now), line, "\(seconds)") }
    }

    func testTheRowsLineLowersCaseTheAgoText() {
        XCTAssertEqual(VaultCopy.rowLastUsedLine(ago: "Just now"), "Last used just now")
        XCTAssertEqual(VaultCopy.rowLastUsedLine(ago: "Yesterday"), "Last used yesterday")
        XCTAssertEqual(VaultCopy.rowLastUsedLine(ago: "2 days ago"), "Last used 2 days ago")
        // The same words the account lists use, so the two cannot drift.
        XCTAssertEqual(VaultCopy.rowLastUsedLine(ago(5 * 86_400), now: now), AccountWords.lastUsedLine(ago(5 * 86_400), now: now))
        XCTAssertEqual(VaultCopy.rowLastUsedLine(ago(10), now: now), AccountWords.lastUsedLine(ago(10), now: now))
        XCTAssertEqual(VaultCopy.rowLastUsedLine(ago(30 * 3600), now: now), AccountWords.lastUsedLine(ago(30 * 3600), now: now))
    }

    func testTheSheetsLastUsedLine() {
        XCTAssertEqual(VaultCopy.sheetLastUsedLine(nil, now: now), "Never")
        XCTAssertEqual(VaultCopy.sheetLastUsedLine(ago(5 * 86_400), now: now), "5 days ago")
        XCTAssertEqual(VaultCopy.sheetLastUsedLine(ago(5), now: now), "Just now")
        XCTAssertEqual(VaultCopy.sheetLastUsedLine(ago(30 * 3600), now: now), "Yesterday")
    }

    func testALastUsedLineWithAnInfiniteGapDoesNotTrap() {
        // `Int(Double.infinity)` traps, and a clock that is far out can make the gap huge.
        XCTAssertTrue(VaultCopy.rowLastUsedLine(.distantPast, now: .distantFuture).hasSuffix(" years ago"))
        XCTAssertTrue(VaultCopy.sheetLastUsedLine(.distantPast, now: .distantFuture).hasSuffix(" years ago"))
        XCTAssertTrue(VaultCopy.rowLastUsedLine(Date(timeIntervalSinceReferenceDate: -.greatestFiniteMagnitude), now: now).hasPrefix("Last used "))
        XCTAssertEqual(VaultCopy.rowLastUsedLine(.distantFuture, now: .distantPast), "Last used just now")
        XCTAssertEqual(VaultCopy.rowLastUsedLine(Date(timeIntervalSinceReferenceDate: .nan), now: now), "Last used just now")
    }

    // MARK: Errors

    func testErrorTextForAChangeAndForALoad() {
        let offline = HVError.transport("The Internet connection appears to be offline.")
        XCTAssertEqual(VaultErrorText.message(for: offline), "Network hiccup. That did not go through. Try again.")
        XCTAssertEqual(VaultErrorText.loadMessage(for: offline), "Network hiccup. That did not load. Try again.")
        // HVError's own sentence, which other screens and their tests say, is not changed.
        XCTAssertEqual(offline.userMessage, "Network hiccup. Check your connection and try again.")
    }

    func testTheServersSentencesPassThroughWithTheirDashes() {
        let sentences = [
            "A secret with that name already exists.",
            "value is too large (max 64 KB).",
            "name must be 1\u{2013}100 chars: letters, digits, dot, dash, or underscore.",
            "API keys cannot manage the vault \u{2014} use a signed-in session.",
            "Rate limit exceeded \u{2014} slow down a little.",
            "This secret changed while you were saving it. Try again.",
        ]
        for sentence in sentences {
            let error = HVError.api(APIFailure(status: 409, message: sentence))
            XCTAssertEqual(VaultErrorText.message(for: error), sentence)
            XCTAssertEqual(VaultErrorText.loadMessage(for: error), sentence)
        }
    }

    func testNoSuchGrantIsNeverShown() {
        for sentence in ["No such grant.", "no such grant.", "  No such grant.  ", "NO SUCH GRANT"] {
            XCTAssertTrue(VaultErrorText.isNoSuchGrant(sentence), sentence)
            let error = HVError.api(APIFailure(status: 404, message: sentence))
            XCTAssertEqual(VaultErrorText.message(for: error), VaultCopy.keyChangeFailedLine)
            XCTAssertEqual(VaultErrorText.loadMessage(for: error), HVCopy.yoursFailedLine)
        }
        for sentence in ["No such secret.", "No such API key.", "Not found."] {
            XCTAssertFalse(VaultErrorText.isNoSuchGrant(sentence), sentence)
            XCTAssertEqual(VaultErrorText.message(for: HVError.api(APIFailure(status: 404, message: sentence))), sentence)
        }
    }

    func testOtherErrors() {
        XCTAssertEqual(VaultErrorText.message(for: HVError.unauthorized), "Your session ended. Sign in again.")
        XCTAssertEqual(VaultErrorText.message(for: HVError.cancelled), "Cancelled.")
        XCTAssertEqual(VaultErrorText.message(for: HVError.invalidRequest("That request was not accepted.")), "That request was not accepted.")
        XCTAssertEqual(VaultErrorText.message(for: HVError.decoding("x")), HVError.decoding("x").userMessage)
        struct VaultCopyTestsOtherError: Error {}
        XCTAssertEqual(VaultErrorText.message(for: VaultCopyTestsOtherError()), VaultCopy.keyChangeFailedLine)
        XCTAssertEqual(VaultErrorText.loadMessage(for: VaultCopyTestsOtherError()), HVCopy.yoursFailedLine)
    }

    func testAMachineCodeLeadingTheSentenceIsDropped() {
        let failure = APIFailure(status: 403, message: "missing_scope: This key cannot send mail.", code: "missing_scope")
        XCTAssertEqual(VaultErrorText.message(for: HVError.api(failure)), "This key cannot send mail.")
    }

    func testAVaultFailureKeepsTheStatus() {
        let failure = VaultFailure(HVError.api(APIFailure(status: 409, message: "A secret with that name already exists.")))
        XCTAssertEqual(failure.status, 409)
        XCTAssertTrue(failure.isConflict)
        XCTAssertEqual(failure.message, "A secret with that name already exists.")
        let offline = VaultFailure(HVError.transport("x"))
        XCTAssertNil(offline.status)
        XCTAssertFalse(offline.isConflict)
        XCTAssertEqual(offline.message, VaultCopy.keyChangeOfflineLine)
        XCTAssertEqual(VaultFailure(HVError.transport("x"), loading: true).message, HVCopy.yoursOfflineLine)
    }

    // MARK: Spoken hints

    func testTheMaskIsReadAsEndingIn() {
        let cases: [(String, String)] = [
            ("Visa \u{2022}\u{2022}\u{2022}\u{2022} 4242", "Visa ending in 4242"),
            ("Mastercard \u{2022}\u{2022}\u{2022}\u{2022} 4444", "Mastercard ending in 4444"),
            ("Amex \u{2022}\u{2022}\u{2022}\u{2022} 0005", "Amex ending in 0005"),
            ("Discover \u{2022}\u{2022}\u{2022}\u{2022} 1117", "Discover ending in 1117"),
            ("Card \u{2022}\u{2022}\u{2022}\u{2022} 0505", "Card ending in 0505"),
            ("\u{2022}\u{2022}\u{2022}\u{2022} 1234", "ending in 1234"),
        ]
        for (hint, spoken) in cases { XCTAssertEqual(VaultItems.spokenHint(hint), spoken, hint) }
    }

    func testEverythingElseIsLeftAlone() {
        let untouched = [
            "", "jane@appleseed.dev", "Address", "Key", "Jane Appleseed", "Visa", "Visa \u{2022}\u{2022}\u{2022}\u{2022} 42",
            "Visa \u{2022}\u{2022}\u{2022}\u{2022} 42424", "Visa \u{2022}\u{2022}\u{2022} 4242", "Visa\u{2022}\u{2022}\u{2022}\u{2022} 4242",
            "Visa \u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022} 4242", "Visa \u{2022}\u{2022}\u{2022}\u{2022} 424a",
            "Visa \u{2022}\u{2022}\u{2022}\u{2022} \u{664}\u{662}\u{664}\u{662}", "\u{2022}\u{2022}\u{2022}\u{2022} 1234 x",
            "Visa \u{2022}\u{2022}\u{2022}\u{2022} 4242\n", "Visa \u{2022}\u{2022}\u{2022}\u{2022}  4242", "\u{2022}\u{2022}\u{2022}\u{2022}1234",
            "4242", "\u{2022}\u{2022}\u{2022}\u{2022}",
        ]
        for hint in untouched { XCTAssertEqual(VaultItems.spokenHint(hint), hint, hint.debugDescription) }
    }

    func testEveryHintTheKitDerivesIsSpokenWithoutBullets() {
        for (brand, number) in SecretsTests.cards {
            let hint = VaultItems.deriveHint(.card, ["number": number, "expMonth": "04", "expYear": "2027"])
            let spoken = VaultItems.spokenHint(hint)
            XCTAssertFalse(spoken.contains("\u{2022}"), spoken)
            XCTAssertEqual(spoken, "\(brand.label) ending in \(number.suffix(4))")
        }
        let phone = VaultItems.deriveHint(.contact, ["phone": "+1 (555) 010-1234"])
        XCTAssertEqual(VaultItems.spokenHint(phone), "ending in 1234")
        XCTAssertEqual(VaultItems.spokenHint(VaultItems.deriveHint(.contact, ["email": "jane@appleseed.dev"])), "jane@appleseed.dev")
        XCTAssertEqual(VaultItems.spokenHint(VaultItems.deriveHint(.login, ["username": "jane", "password": "pw"])), "jane")
    }

    func testARowSpeaksItsSubtitle() {
        let card = VaultSecret(id: "1", name: "visa-4242", kind: .card, hint: "Visa \u{2022}\u{2022}\u{2022}\u{2022} 4242")
        XCTAssertEqual(card.subtitle, "Visa \u{2022}\u{2022}\u{2022}\u{2022} 4242")
        XCTAssertEqual(card.spokenSubtitle, "Visa ending in 4242")
        let key = VaultSecret(id: "2", name: "stripe", kind: .opaque)
        XCTAssertEqual(key.spokenSubtitle, "Key")
        let login = VaultSecret(id: "3", name: "github.com", kind: .login, hint: "jane@appleseed.dev")
        XCTAssertEqual(login.spokenSubtitle, "jane@appleseed.dev")
    }

    // MARK: The fetch command

    private let placeholderCommand = "curl -s \"https://hypervault.store/api/secrets/github.com\" \\\n  -H \"X-HyperVault-Key: hv_YOUR_KEY\""

    func testTheCommandIsTheHandoffs() {
        // handoff 5.10 item 5:
        //   curl -s "<app_url>/api/secrets/<name>" \
        //     -H "X-HyperVault-Key: hv_YOUR_KEY"
        XCTAssertEqual(VaultItems.fetchCommand(appURL: "https://hypervault.store", name: "github.com"), placeholderCommand)
        let lines = VaultItems.fetchCommand(appURL: "https://hypervault.store", name: "github.com").components(separatedBy: "\n")
        XCTAssertEqual(lines, ["curl -s \"https://hypervault.store/api/secrets/github.com\" \\", "  -H \"X-HyperVault-Key: hv_YOUR_KEY\""])
    }

    func testTheOriginHasNoTrailingSlashOrWhiteSpace() {
        for appURL in ["https://hypervault.store/", "https://hypervault.store///", " https://hypervault.store \n", "\u{FEFF}https://hypervault.store/"] {
            XCTAssertEqual(VaultItems.fetchCommand(appURL: appURL, name: "github.com"), placeholderCommand, appURL.debugDescription)
        }
    }

    func testTheAppURLIsTheOriginAnAgentMustCall() {
        // www or the bare domain, a staging host or a proxy: whatever capabilities says, not the host the phone reached.
        let command = VaultItems.fetchCommand(appURL: "https://www.hypervault.store", fallbackOrigin: "https://api.example.net", name: "x")
        XCTAssertTrue(command.hasPrefix("curl -s \"https://www.hypervault.store/api/secrets/x\""))
        XCTAssertTrue(VaultItems.fetchCommand(appURL: "http://localhost:3000", name: "x").hasPrefix("curl -s \"http://localhost:3000/api/secrets/x\""))
        XCTAssertTrue(VaultItems.fetchCommand(appURL: "https://hv.example/app/", name: "x").hasPrefix("curl -s \"https://hv.example/app/api/secrets/x\""))
    }

    func testTheFallbackIsUsedOnlyWhenTheAppURLIsNotAWebAddress() {
        let fallback = "https://hypervault.store/"
        for appURL in ["", "   ", "hypervault.store", "ftp://hypervault.store", "not a url", "https://"] {
            XCTAssertEqual(
                VaultItems.fetchCommand(appURL: appURL, fallbackOrigin: fallback, name: "github.com"), placeholderCommand, appURL.debugDescription
            )
        }
        // Neither is an address: the command still says where it was meant to go.
        XCTAssertTrue(VaultItems.fetchCommand(appURL: "hypervault.store", fallbackOrigin: "nope", name: "x").hasPrefix("curl -s \"hypervault.store/api/secrets/x\""))
        XCTAssertTrue(VaultItems.fetchCommand(appURL: "hypervault.store", name: "x").hasPrefix("curl -s \"hypervault.store/api/secrets/x\""))
    }

    func testANameFromBeforeTheRuleCannotBreakTheCommand() {
        XCTAssertTrue(VaultItems.fetchCommand(appURL: "https://h.example", name: "Chase Sapphire").contains("/api/secrets/Chase%20Sapphire\""))
        let nasty = VaultItems.fetchCommand(appURL: "https://h.example", name: "x\"; rm -rf ~; \"")
        XCTAssertTrue(nasty.contains("/api/secrets/x%22%3B%20rm%20-rf%20~%3B%20%22\""))
        XCTAssertEqual(nasty.filter { $0 == "\"" }.count, 4)
        XCTAssertTrue(VaultItems.fetchCommand(appURL: "https://h.example", name: "a/b").contains("/api/secrets/a%2Fb\""))
        XCTAssertTrue(VaultItems.fetchCommand(appURL: "https://h.example", name: "\u{E9}").contains("/api/secrets/%C3%A9\""))
        XCTAssertTrue(VaultItems.fetchCommand(appURL: "https://h.example", name: "a\n").contains("/api/secrets/a%0A\""))
    }

    func testTheCommandNeverHoldsARealKey() {
        XCTAssertEqual(VaultItems.fetchKeyPlaceholder, "hv_YOUR_KEY")
        XCTAssertFalse(AgentKeyRules.looksLikeKey(VaultItems.fetchKeyPlaceholder))
        let command = VaultItems.fetchCommand(appURL: "https://hypervault.store", name: "github.com")
        XCTAssertEqual(command.components(separatedBy: "hv_").count - 1, 1)
        XCTAssertTrue(command.contains("X-HyperVault-Key: hv_YOUR_KEY"))
    }
}
