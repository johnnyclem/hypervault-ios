import XCTest
@testable import HyperVaultKit

final class VaultLimitsTests: XCTestCase {
    func testTheLimitsAreTheHandoffs() {
        XCTAssertEqual(VaultLimits.maxEntries, 100)
        XCTAssertEqual(VaultLimits.maxValueBytes, 65_536)
        XCTAssertEqual(VaultLimits.maxDescription, 500)
        XCTAssertEqual(VaultLimits.maxNameLength, 100)
        XCTAssertEqual(VaultLimits.maxHint, 120)
        XCTAssertEqual(VaultLimits.maxHint, VaultItems.hintMax)
    }

    func testTheNameLimitIsTheNameRules() {
        XCTAssertTrue(VaultItems.isValidName(String(repeating: "a", count: VaultLimits.maxNameLength)))
        XCTAssertFalse(VaultItems.isValidName(String(repeating: "a", count: VaultLimits.maxNameLength + 1)))
    }

    func testTheServersSentencesAreVerbatim() {
        XCTAssertEqual(VaultLimits.valueTooLargeMessage, "value is too large (max 64 KB).")
        XCTAssertEqual(VaultLimits.entryLimitMessage, "Limit of 100 secrets reached.")
        XCTAssertEqual(VaultLimits.valueRequiredMessage, "value is required.")
        // With the en dash of the rule's hint (U+2013), as the server writes it.
        XCTAssertEqual(VaultLimits.invalidNameMessage, "name must be 1\u{2013}100 chars: letters, digits, dot, dash, or underscore.")
        XCTAssertTrue(VaultLimits.invalidNameMessage.hasSuffix(VaultItems.nameHint.dropFirst(6).description))
    }

    // MARK: Value size

    func testTheValueLimitIsInUTF8BytesAtTheBoundary() {
        let atLimit = String(repeating: "a", count: 65_536)
        let over = atLimit + "a"
        XCTAssertEqual(VaultLimits.valueByteCount(atLimit), 65_536)
        XCTAssertFalse(VaultLimits.valueTooLarge(atLimit))
        XCTAssertTrue(VaultLimits.valueTooLarge(over))
        XCTAssertNil(VaultLimits.valueProblem(atLimit))
        XCTAssertEqual(VaultLimits.valueProblem(over), "value is too large (max 64 KB).")
        XCTAssertNil(VaultLimits.valueProblem(""))
    }

    func testMultiByteCharactersCountTheirBytes() {
        // 2 bytes each: 32,768 of them are exactly 64 KB, and one more is over, though the string is far under 64K characters.
        let twoByte = String(repeating: "\u{E9}", count: 32_768)
        XCTAssertEqual(twoByte.count, 32_768)
        XCTAssertEqual(twoByte.utf16.count, 32_768)
        XCTAssertEqual(VaultLimits.valueByteCount(twoByte), 65_536)
        XCTAssertFalse(VaultLimits.valueTooLarge(twoByte))
        XCTAssertTrue(VaultLimits.valueTooLarge(twoByte + "a"))
        // 3 bytes each (U+4F8B), 4 bytes each (an emoji): the same string length is a different byte length.
        XCTAssertEqual(VaultLimits.valueByteCount(String(repeating: "\u{4F8B}", count: 100)), 300)
        XCTAssertEqual(VaultLimits.valueByteCount(String(repeating: "\u{1F600}", count: 100)), 400)
        XCTAssertTrue(VaultLimits.valueTooLarge(String(repeating: "\u{1F600}", count: 16_385)))
        XCTAssertFalse(VaultLimits.valueTooLarge(String(repeating: "\u{1F600}", count: 16_384)))
        // A flag is two scalars and one Character; the bytes are what count.
        XCTAssertEqual(VaultLimits.valueByteCount("\u{1F1FA}\u{1F1F8}"), 8)
    }

    func testTheSerializedEntryIsWhatIsMeasured() {
        // The notes are 44,000 bytes, under the limit; as JSON each line break is the two bytes "\\n", so the value
        // that is sent is over it. The limit is on the value as sent.
        let notes = String(repeating: "a\n", count: 22_000)
        XCTAssertFalse(VaultLimits.valueTooLarge(notes))
        let value = VaultItems.serialize(.login, ["username": "jane", "password": "pw", "notes": notes])
        XCTAssertGreaterThan(VaultLimits.valueByteCount(value), 65_536)
        XCTAssertTrue(VaultLimits.valueTooLarge(value))
        XCTAssertEqual(VaultLimits.valueProblem(value), "value is too large (max 64 KB).")
    }

    // MARK: Entries

    func testTheEntryLimit() {
        XCTAssertFalse(VaultLimits.entryLimitReached(count: 0))
        XCTAssertFalse(VaultLimits.entryLimitReached(count: 99))
        XCTAssertTrue(VaultLimits.entryLimitReached(count: 100))
        XCTAssertTrue(VaultLimits.entryLimitReached(count: 101))
        XCTAssertNil(VaultLimits.entryLimitProblem(count: 99))
        XCTAssertEqual(VaultLimits.entryLimitProblem(count: 100), "Limit of 100 secrets reached.")
    }

    // MARK: Description

    func testTheDescriptionIsCountedInUTF16Units() {
        // The server cuts with `slice(0, 500)`, which counts UTF-16 units.
        XCTAssertEqual(VaultLimits.descriptionLength(""), 0)
        XCTAssertEqual(VaultLimits.descriptionLength("abc"), 3)
        XCTAssertEqual(VaultLimits.descriptionLength("\u{1F600}"), 2)
        XCTAssertEqual(VaultLimits.descriptionLength("\u{1F1FA}\u{1F1F8}"), 4)
        XCTAssertEqual(VaultLimits.descriptionLength("e\u{301}"), 2)
        XCTAssertFalse(VaultLimits.descriptionTooLong(String(repeating: "\u{1F600}", count: 250)))
        XCTAssertTrue(VaultLimits.descriptionTooLong(String(repeating: "\u{1F600}", count: 251)))
        XCTAssertFalse(VaultLimits.descriptionTooLong(String(repeating: "a", count: 500)))
        XCTAssertTrue(VaultLimits.descriptionTooLong(String(repeating: "a", count: 501)))
    }

    func testClampingKeepsWhatTheServerWouldKeepAndNeverSplitsAPair() {
        let long = String(repeating: "\u{1F600}", count: 600)
        let clamped = VaultLimits.clampedDescription(long)
        XCTAssertEqual(clamped.unicodeScalars.count, 250)
        XCTAssertEqual(clamped.utf16.count, 500)
        XCTAssertTrue(clamped.unicodeScalars.allSatisfy { $0.value == 0x1F600 })
        // 499 units and an emoji that needs two: it does not fit, so it is dropped whole (the server would keep
        // its high half).
        let edge = String(repeating: "a", count: 499) + "\u{1F600}"
        XCTAssertEqual(VaultLimits.clampedDescription(edge), String(repeating: "a", count: 499))
        let short = "hello"
        XCTAssertEqual(VaultLimits.clampedDescription(short), short)
        XCTAssertEqual(VaultLimits.clampedDescription(String(repeating: "a", count: 500)).count, 500)
        XCTAssertEqual(VaultLimits.clampedDescription(String(repeating: "a", count: 501)).count, 500)
    }
}
