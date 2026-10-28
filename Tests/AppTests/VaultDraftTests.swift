import HyperVaultKit
import XCTest
@testable import HyperVault

/// What the add and replace forms know about what is typed (App/Features/Vault/VaultDraft.swift): when Save is on, what the line
/// under the form says, what the name is and what is wrong with it, and when closing the form would lose something.
final class VaultDraftTests: XCTestCase {
    private func login(username: String = "sam@example.com", password: String = "pw-1") -> VaultDraft {
        var draft = VaultDraft(kind: .login)
        draft.fields = ["username": username, "password": password]
        return draft
    }

    private func card(number: String) -> VaultDraft {
        var draft = VaultDraft(kind: .card)
        draft.fields = ["number": number, "expMonth": "12", "expYear": "2030"]
        return draft
    }

    // MARK: The value

    func testAKeyNeedsAValueAndKeepsItExactlyAsTyped() {
        var draft = VaultDraft(kind: .opaque)
        XCTAssertEqual(draft.problem, "Add the value.")
        draft.value = " sk-live  "
        XCTAssertNil(draft.problem)
        XCTAssertEqual(draft.serialized, " sk-live  ", "a leading space stays")
    }

    func testAValueOver64KBIsRefusedBeforeTheRequestByItsUTF8Bytes() {
        var draft = VaultDraft(kind: .opaque)
        // 22,000 characters, 66,000 bytes: under the limit by `count`, over it by bytes.
        draft.value = String(repeating: "\u{20AC}", count: 22_000)
        XCTAssertEqual(draft.value.count, 22_000)
        XCTAssertEqual(draft.problem, "value is too large (max 64 KB).")

        draft.value = String(repeating: "a", count: 64 * 1024)
        XCTAssertNil(draft.problem, "exactly 64 KB is allowed")
        draft.value += "a"
        XCTAssertEqual(draft.problem, "value is too large (max 64 KB).")
    }

    func testATypedEntryOver64KBIsRefusedToo() {
        var draft = login()
        draft.fields["notes"] = String(repeating: "n", count: 66_000)
        XCTAssertNil(VaultItems.validate(.login, draft.fields), "the Kit validator has no size rule")
        XCTAssertEqual(draft.problem, "value is too large (max 64 KB).")
    }

    func testATypedEntryNamesTheFirstThingMissing() {
        var draft = VaultDraft(kind: .login)
        XCTAssertEqual(draft.problem, "Add the username.")
        XCTAssertFalse(draft.isTouched, "the line under the form stays quiet until someone has started")
        draft.fields["username"] = "sam"
        XCTAssertTrue(draft.isTouched)
        XCTAssertEqual(draft.problem, "Add the password.")
    }

    // MARK: The name

    func testTheNameIsSuggestedUntilThePersonTypesOne() {
        var draft = login(username: "sam@example.com")
        XCTAssertEqual(draft.name, "sam-example.com")
        draft.typedName = "work-login"
        XCTAssertEqual(draft.name, "work-login")
        draft.typedName = ""
        XCTAssertEqual(draft.name, "", "clearing the field is not the same as never having typed in it")
        XCTAssertFalse(draft.canSave)
    }

    func testTheNameIsTrimmedTheWayTheWebTrimsIt() {
        var draft = login()
        draft.typedName = "  github.com\n"
        XCTAssertEqual(draft.name, "github.com")
        XCTAssertTrue(draft.canSave)
        draft.typedName = "\u{FEFF}github.com"
        XCTAssertEqual(draft.name, "github.com", "JavaScript trims a byte order mark; Foundation does not")
    }

    func testAServersLineAboutANameIsSaidOnlyWhileTheFieldHoldsThatName() {
        // The server called the suggested name taken. Correcting the card number moves the suggestion, and the new one is a
        // name nobody has tried.
        var draft = card(number: "4242 4242 4242 4242")
        let refusal = VaultNameRefusal(name: draft.name, message: "A secret with that name already exists.")
        XCTAssertEqual(draft.name, "visa-4242")
        XCTAssertEqual(refusal.line(whenNamed: draft.name), "A secret with that name already exists.")

        draft.fields["number"] = "4111 1111 1111 1111"
        XCTAssertEqual(draft.name, "visa-1111")
        XCTAssertNil(refusal.line(whenNamed: draft.name), "the line is about visa-4242, which is no longer the name")

        draft.typedName = "visa-4242"
        XCTAssertNotNil(refusal.line(whenNamed: draft.name), "typed back, it is the name the server refused")
    }

    func testANameThatBreaksTheRuleTurnsTheHintIntoTheProblem() {
        var draft = login()
        draft.typedName = "my login"
        XCTAssertEqual(draft.nameProblem, VaultItems.nameHint)
        XCTAssertFalse(draft.canSave)
        draft.typedName = "my-login"
        XCTAssertNil(draft.nameProblem)
        XCTAssertTrue(draft.canSave)
    }

    func testAnEmptyNameIsNotYetAComplaint() {
        var draft = VaultDraft(kind: .opaque)
        XCTAssertNil(draft.nameProblem)
        draft.typedName = ""
        XCTAssertNil(draft.nameProblem)
    }

    func testDotAndDotDotPassTheServersRuleButAreRefusedHere() {
        var draft = login()
        for name in [".", ".."] {
            draft.typedName = name
            XCTAssertTrue(VaultItems.isValidName(name), "the server takes it")
            XCTAssertEqual(draft.nameProblem, VaultScreenCopy.dotsOnlyName)
            XCTAssertFalse(draft.canSave, "\(name) cannot be addressed as a path")
        }
        draft.typedName = "..a"
        XCTAssertNil(draft.nameProblem)
        XCTAssertTrue(draft.canSave)
    }

    func testSaveNeedsAGoodValueAndAGoodName() {
        var draft = login(password: "")
        draft.typedName = "work"
        XCTAssertFalse(draft.canSave, "no password")
        draft.fields["password"] = "pw"
        XCTAssertTrue(draft.canSave)
        draft.typedName = "no spaces allowed"
        XCTAssertFalse(draft.canSave)
    }

    // MARK: Closing

    func testNothingTypedIsNothingToLose() {
        var draft = VaultDraft(kind: .card)
        XCTAssertFalse(draft.isDirty)
        draft.typedName = ""
        XCTAssertFalse(draft.isDirty)
        draft.fields["number"] = ""
        XCTAssertFalse(draft.isDirty)
    }

    func testAFieldOrANameTypedIsSomethingToLose() {
        var draft = VaultDraft(kind: .opaque)
        draft.typedName = "github-mcp-token"
        XCTAssertTrue(draft.isDirty)
        draft.typedName = nil
        draft.value = "x"
        XCTAssertTrue(draft.isDirty)
    }

    // MARK: The card number

    func testTheCardNumberSaysNothingUntilThereIsOne() {
        XCTAssertNil(card(number: "").cardNumberProblem)
    }

    func testAShortCardNumberIsItsOwnProblem() {
        XCTAssertEqual(card(number: "4242 4242").cardNumberProblem, "The card number must be 12 to 19 digits.")
    }

    func testACardNumberThatFailsTheChecksumIsItsOwnProblem() {
        XCTAssertEqual(card(number: "4242 4242 4242 4241").cardNumberProblem, "That card number doesn't look right. Check it for a typo.")
    }

    func testAGoodCardNumberHasNoProblemOfItsOwn() {
        XCTAssertNil(card(number: "4242 4242 4242 4242").cardNumberProblem)
        // A bad expiry is the form's problem, not the number field's.
        var draft = card(number: "4242 4242 4242 4242")
        draft.fields["expMonth"] = "13"
        XCTAssertNil(draft.cardNumberProblem)
        XCTAssertEqual(draft.problem, "The expiry month must be 1 to 12.")
    }

    func testOnlyACardHasACardNumberProblem() {
        var draft = login()
        draft.fields["number"] = "42"
        XCTAssertNil(draft.cardNumberProblem)
    }

    // MARK: The digit fields

    func testTheDigitFieldsKeepAsciiDigitsAndTurnOtherNumeralsIntoThem() {
        // The month, year and security-code fields filter with the Kit's rule: ASCII digits, up to a limit.
        XCTAssertEqual(VaultItems.asciiDigits("1a2b3", limit: 2, transliterating: true), "12")
        XCTAssertEqual(VaultItems.asciiDigits("\u{0661}\u{0662}", limit: 2, transliterating: true), "12", "Arabic-Indic digits")
        XCTAssertEqual(VaultItems.asciiDigits("\u{00B2}\u{00BD}", limit: 4, transliterating: true), "", "superscripts and fractions are not digits")
        XCTAssertEqual(VaultItems.formatCardNumber(VaultItems.asciiDigits("\u{0664}\u{0662}\u{0664}\u{0662}", transliterating: true)), "4242")
    }
}
