import XCTest
@testable import HyperVaultKit

/// The text rules the server runs, which are JavaScript's: its white space (`trim()`, `\s`), the email regex over
/// UTF-16 units, and ASCII-only digits. The expected values were taken from Node 22.22.0, not from the standard.
final class VaultTextTests: XCTestCase {
    typealias Items = VaultItems

    // MARK: White space

    /// `[...Array(0x110000).keys()].filter((cp) => /\s/.test(String.fromCodePoint(cp)))` in Node 22, which is also
    /// what `trim()` removes: U+0009 to U+000D, U+0020, U+00A0, U+1680, U+2000 to U+200A, U+2028, U+2029, U+202F,
    /// U+205F, U+3000 and U+FEFF.
    private static func isExpectedWhitespace(_ value: UInt32) -> Bool {
        (0x09...0x0D).contains(value) || value == 0x20 || value == 0xA0 || value == 0x1680 || (0x2000...0x200A).contains(value)
            || value == 0x2028 || value == 0x2029 || value == 0x202F || value == 0x205F || value == 0x3000 || value == 0xFEFF
    }

    func testTheWhiteSpaceSetIsJavaScripts() {
        var count = 0
        for value in UInt32(0)...0x10FFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            if Items.isJSWhitespace(scalar) { count += 1 }
            XCTAssertEqual(Items.isJSWhitespace(scalar), Self.isExpectedWhitespace(value), String(value, radix: 16))
        }
        XCTAssertEqual(count, 25)
    }

    func testWhereJavaScriptAndFoundationDisagree() {
        // Foundation's .whitespacesAndNewlines holds U+0085 and not U+FEFF; JavaScript is the other way round.
        XCTAssertFalse(Items.isJSWhitespace("\u{85}"))
        XCTAssertTrue(Items.isJSWhitespace("\u{FEFF}"))
        XCTAssertFalse(Items.isJSWhitespace("\u{180E}"))
        XCTAssertFalse(Items.isJSWhitespace("\u{200B}"))
        XCTAssertFalse(Items.isJSWhitespace("\u{2060}"))
        XCTAssertFalse(Items.isJSWhitespace("\u{1C}"))
    }

    func testJSTrim() {
        XCTAssertEqual(Items.jsTrim("  a b  "), "a b")
        XCTAssertEqual(Items.jsTrim("\n\t abc\r\n"), "abc")
        XCTAssertEqual(Items.jsTrim("\u{FEFF}abc\u{FEFF}"), "abc")
        XCTAssertEqual(Items.jsTrim("\u{A0}\u{3000}\u{2028}abc\u{2029}\u{202F}\u{205F}"), "abc")
        XCTAssertEqual(Items.jsTrim("\u{85}abc\u{85}"), "\u{85}abc\u{85}")
        XCTAssertEqual(Items.jsTrim("\u{200B}abc"), "\u{200B}abc")
        XCTAssertEqual(Items.jsTrim(""), "")
        XCTAssertEqual(Items.jsTrim(" \t\n\u{FEFF}"), "")
        // A combining mark after the space is a character of its own for trim(), though not for a Swift Character.
        XCTAssertEqual(Array(Items.jsTrim(" \u{301}a").unicodeScalars.map(\.value)), [0x301, 0x61])
        XCTAssertEqual(Array(Items.jsTrim("e\u{301} ").utf8), Array("e\u{301}".utf8))
    }

    func testAPasswordOfOnlyJavaScriptWhiteSpaceIsNoPassword() {
        func problem(_ password: String) -> String? {
            Items.validate(.login, ["username": "jane", "password": password])
        }
        XCTAssertEqual(problem("\u{FEFF}"), "Add the password.")
        XCTAssertEqual(problem(" \u{FEFF} \u{A0}"), "Add the password.")
        XCTAssertEqual(problem(""), "Add the password.")
        // U+0085 is not white space to JavaScript, so it is a password; Foundation would call it none.
        XCTAssertNil(problem("\u{85}"))
        XCTAssertNil(problem(" pw "))
    }

    func testAUsernameOfOnlyJavaScriptWhiteSpaceIsNoUsername() {
        func problem(_ username: String) -> String? {
            Items.validate(.login, ["username": username, "password": "pw"])
        }
        XCTAssertEqual(problem("\u{FEFF}"), "Add the username.")
        XCTAssertEqual(problem("\u{3000}\u{2003}"), "Add the username.")
        XCTAssertNil(problem("\u{85}"))
    }

    func testTheCardNumberStripsJavaScriptWhiteSpaceAndNothingElse() {
        XCTAssertEqual(Items.canonical(.card, ["number": "4242\u{FEFF}4242\u{A0}4242-4242"])["number"], "4242424242424242")
        XCTAssertTrue(Items.luhnValid("4242\u{FEFF}4242 4242 4242"))
        XCTAssertFalse(Items.luhnValid("4242\u{85}4242 4242 4242"))
        XCTAssertEqual(
            Items.validate(.card, ["number": "4242\u{85}4242 4242 4242", "expMonth": "04", "expYear": "2027"]),
            "The card number must be 12 to 19 digits."
        )
        XCTAssertNil(Items.validate(.card, ["number": "4242\u{FEFF}4242 4242 4242", "expMonth": "04", "expYear": "2027"]))
    }

    func testEveryNonPasswordFieldIsTrimmedTheJavaScriptWay() {
        let fields = Items.canonical(.login, ["username": "\u{FEFF} jane\u{3000}", "notes": "\u{A0}hi\u{2028}", "password": "\u{FEFF}pw "])
        XCTAssertEqual(fields["username"], "jane")
        XCTAssertEqual(fields["notes"], "hi")
        XCTAssertEqual(fields["password"], "\u{FEFF}pw ")
        XCTAssertEqual(Items.canonical(.contact, ["fullName": "\u{85}Jane\u{85}"])["fullName"], "\u{85}Jane\u{85}")
    }

    func testTheNameIsTrimmedTheWayTheFormsSendIt() {
        XCTAssertEqual(Items.trimmedName("  github.com\n"), "github.com")
        XCTAssertEqual(Items.trimmedName("\u{FEFF}abc"), "abc")
        XCTAssertEqual(Items.trimmedName("\u{85}abc"), "\u{85}abc")
        XCTAssertTrue(Items.isValidName(Items.trimmedName("abc\n")))
        XCTAssertFalse(Items.isValidName(Items.trimmedName("\u{85}abc")))
        XCTAssertFalse(Items.isValidName(Items.trimmedName("\n")))
    }

    // MARK: Email

    /// (text, what `/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(text)` gave in Node 22)
    private static let emailTable: [(String, Bool)] = [
        ("jane@appleseed.dev", true),
        ("a@b.c", true),
        ("jane", false),
        ("jane@", false),
        ("jane@appleseed", false),
        ("jane doe@appleseed.dev", false),
        ("@appleseed.dev", false),
        ("a@b@c.dev", false),
        ("a@b.\u{301}", true),
        ("a@\u{85}b.c", true),
        ("\u{85}@b.c", true),
        ("a@b.\u{85}", true),
        ("a@b..c", true),
        ("a@.b.c", true),
        ("a@b.", false),
        ("a@.b", false),
        ("a@b.c.", true),
        ("a@..", false),
        ("a@...", true),
        ("a@b.c\u{A}", false),
        ("a@b.c\u{D}\u{A}", false),
        ("a\u{A}@b.c", false),
        ("a@b c.d", false),
        ("a\u{A0}@b.c", false),
        ("a@b.c\u{2028}", false),
        ("a@b.c\u{2029}", false),
        ("a@b.c\u{FEFF}", false),
        ("\u{FEFF}a@b.c", false),
        ("a@b\u{200B}.c", true),
        ("a@\u{E9}.c", true),
        ("a@b.\u{E9}", true),
        ("\u{E9}@b.c", true),
        ("a@b.c\u{301}", true),
        ("a\u{301}@b.c", true),
        ("a@b\u{301}.c", true),
        ("a@\u{301}.c", true),
        ("a@.\u{301}", false),
        ("a@b.\u{1F600}", true),
        ("\u{1F600}@b.c", true),
        ("a.b@c.d", true),
        ("a+b@c-d.e", true),
        ("a@b.c@", false),
        ("a@@", false),
        ("@@", false),
        ("@", false),
        ("", false),
        ("a@b.cd.ef", true),
        ("a@-.-", true),
        ("a@1.2", true),
        ("\u{9}a@b.c", false),
        ("a@b.c\u{9}", false),
        ("a@b\u{180E}.c", true),
        ("a@b.c\u{B}", false),
        ("a@b.c\u{C}", false),
        ("a@b\u{3000}.c", false),
        ("a@b\u{205F}.c", false),
        ("a@b\u{1680}.c", false),
        ("a@b\u{2000}.c", false),
        ("a@b\u{200A}.c", false),
        ("a@b\u{200B}.c", true),
        ("\u{85}", false),
        ("a@\u{85}.\u{85}", true),
    ]

    func testEmailShapeIsTheWebsRegexOverScalars() {
        XCTAssertGreaterThan(Self.emailTable.filter { $0.1 }.count, 20)
        XCTAssertGreaterThan(Self.emailTable.filter { !$0.1 }.count, 20)
        for (text, expected) in Self.emailTable {
            XCTAssertEqual(Items.looksLikeEmail(text), expected, text.debugDescription)
        }
    }

    func testEmailThroughTheContactValidator() {
        let message = "That email address doesn't look right."
        XCTAssertNil(Items.validate(.contact, ["email": "a@b.\u{301}"]))
        XCTAssertNil(Items.validate(.contact, ["email": "a@\u{85}b.c"]))
        XCTAssertNil(Items.validate(.contact, ["email": "a@b..c"]))
        XCTAssertNil(Items.validate(.contact, ["email": "a@.b.c"]))
        XCTAssertEqual(Items.validate(.contact, ["email": "a@b."]), message)
        XCTAssertEqual(Items.validate(.contact, ["email": "a@b\u{3000}.c"]), message)
        XCTAssertEqual(Items.validate(.contact, ["email": "a@b.c@d"]), message)
        // The email is trimmed first (with JavaScript's rules), so a byte order mark around it is not part of it.
        XCTAssertNil(Items.validate(.contact, ["email": "\u{FEFF}a@b.c\u{FEFF}"]))
    }

    // MARK: Names that can be addressed

    func testDotNamesPassTheRuleButCannotBeAddressed() {
        for name in [".", ".."] {
            XCTAssertTrue(Items.isValidName(name), name)
            XCTAssertFalse(Items.isAddressableName(name), name)
        }
        for name in ["...", ".a", "a.", "a..b", "-", "_", "github.com", "visa-4242", String(repeating: "a", count: 100)] {
            XCTAssertTrue(Items.isAddressableName(name), name)
        }
        for name in ["", " ", "a b", "abc\n", String(repeating: "a", count: 101), "\u{E9}"] {
            XCTAssertFalse(Items.isAddressableName(name), name.debugDescription)
        }
    }

    func testASuggestionIsNeverADotName() {
        // The web strips leading and trailing dots and dashes, so nothing that is typed can suggest "." or "..".
        for text in [".", "..", "...", "-.-", ". .", ".-."] {
            let suggestion = Items.suggestName(.login, ["username": text])
            XCTAssertTrue(suggestion.isEmpty || Items.isAddressableName(suggestion), "\(text) -> \(suggestion)")
        }
        XCTAssertEqual(Items.suggestName(.login, ["username": ".."]), "")
    }

    // MARK: ASCII digits

    func testASCIIDigitsKeepsOnlyZeroToNine() {
        XCTAssertEqual(Items.asciiDigits("4242 4242-ab12"), "4242424212")
        XCTAssertEqual(Items.asciiDigits(""), "")
        XCTAssertEqual(Items.asciiDigits("abc"), "")
        // Arabic-Indic, Persian, fullwidth, superscript, fractions, Devanagari: all numbers to Character.isNumber.
        XCTAssertEqual(Items.asciiDigits("\u{664}\u{662}"), "")
        XCTAssertEqual(Items.asciiDigits("\u{6F4}\u{6F2}"), "")
        XCTAssertEqual(Items.asciiDigits("\u{FF14}\u{FF12}"), "")
        XCTAssertEqual(Items.asciiDigits("\u{B2}\u{B9}\u{BD}"), "")
        XCTAssertEqual(Items.asciiDigits("\u{966}\u{967}"), "")
        XCTAssertEqual(Items.asciiDigits("1\u{662}3"), "13")
    }

    func testASCIIDigitsStopsAtTheLimitInDigitsNotCharacters() {
        XCTAssertEqual(Items.asciiDigits("12345", limit: 2), "12")
        XCTAssertEqual(Items.asciiDigits("1a2b3c4", limit: 3), "123")
        XCTAssertEqual(Items.asciiDigits("12", limit: 5), "12")
        XCTAssertEqual(Items.asciiDigits("12345", limit: 0), "")
        XCTAssertEqual(Items.asciiDigits("\u{664}1\u{662}2", limit: 2), "12")
    }

    func testTransliteratingTurnsTheOtherDigitsIntoTheirASCIITwins() {
        XCTAssertEqual(Items.asciiDigits("\u{660}\u{661}\u{662}\u{663}\u{664}\u{665}\u{666}\u{667}\u{668}\u{669}", transliterating: true), "0123456789")
        XCTAssertEqual(Items.asciiDigits("\u{6F0}\u{6F1}\u{6F2}\u{6F3}\u{6F4}\u{6F5}\u{6F6}\u{6F7}\u{6F8}\u{6F9}", transliterating: true), "0123456789")
        XCTAssertEqual(Items.asciiDigits("\u{FF10}\u{FF11}\u{FF12}\u{FF13}\u{FF14}\u{FF15}\u{FF16}\u{FF17}\u{FF18}\u{FF19}", transliterating: true), "0123456789")
        XCTAssertEqual(Items.asciiDigits("\u{664}\u{662}\u{664}\u{662} 4242", transliterating: true), "42424242")
        XCTAssertEqual(Items.asciiDigits("\u{664}\u{662}\u{664}\u{662}", limit: 3, transliterating: true), "424")
        // Superscripts, fractions and the other scripts' digits are not twins of anything and are dropped.
        XCTAssertEqual(Items.asciiDigits("\u{B2}\u{BD}\u{966}", transliterating: true), "")
        XCTAssertEqual(Items.asciiDigits("\u{664}\u{662}"), "")
    }

    func testATransliteratedCardIsOneTheServerTakes() {
        let arabic = "\u{664}\u{662}\u{664}\u{662}\u{664}\u{662}\u{664}\u{662}\u{664}\u{662}\u{664}\u{662}\u{664}\u{662}\u{664}\u{662}"
        XCTAssertEqual(Items.validate(.card, ["number": arabic, "expMonth": "04", "expYear": "2027"]), "The card number must be 12 to 19 digits.")
        let typed = Items.asciiDigits(arabic, transliterating: true)
        XCTAssertEqual(typed, "4242424242424242")
        XCTAssertNil(Items.validate(.card, ["number": typed, "expMonth": "04", "expYear": "2027"]))
    }
}
