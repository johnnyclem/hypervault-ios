import XCTest
@testable import HyperVaultKit

/// The cases of lib/secrets/__tests__/items.test.ts that SecretsTests did not have, and the three cases the handoff
/// (5.6) asks for on top of them: Arabic-Indic digits, a name ending in a newline, a website with a space in the host.
final class SecretsParityTests: XCTestCase {
    typealias Items = VaultItems

    private func card(_ overrides: [String: String] = [:]) -> [String: String] {
        ["number": "4242424242424242", "expMonth": "04", "expYear": "2027"].merging(overrides) { _, new in new }
    }

    // MARK: The kinds (items.test.ts: "isVaultItemKind accepts exactly the three typed kinds")

    func testTheTypedKindsAreExactlyLoginCardAndContact() {
        XCTAssertEqual(VaultItemKind.allCases.map(\.rawValue), ["login", "card", "contact"])
        for kind in VaultItemKind.allCases {
            XCTAssertTrue(SecretKind.allCases.contains(kind.secretKind), kind.rawValue)
            XCTAssertEqual(kind.secretKind.vaultItemKind, kind)
        }
        for raw in ["opaque", "header", "oauth_grant", "Login", " card", "", "contact ", "CARD", "login\n"] {
            XCTAssertNil(VaultItemKind(rawValue: raw), raw.debugDescription)
        }
        for kind in [SecretKind.opaque, .header, .oauthGrant] { XCTAssertNil(kind.vaultItemKind) }
    }

    func testTheCategoryIdsAreTheWebs() {
        XCTAssertEqual(VaultCategory.allCases.map(\.id), ["logins", "cards", "contact", "keys"])
    }

    // MARK: Shape (items.test.ts: "refuses anything that is not an object")

    func testAValueThatIsNotAnObjectIsRefusedForEveryKind() {
        XCTAssertEqual(Items.parse(.card, value: "[]"), .failure(.init(message: "A card must be a JSON object with a number, expMonth and expYear.")))
        XCTAssertEqual(Items.parse(.card, value: "\"x\""), .failure(.init(message: "A card must be a JSON object with a number, expMonth and expYear.")))
        XCTAssertEqual(Items.parse(.contact, value: "\"x\""), .failure(.init(message: "Contact info must be a JSON object with a fullName, email, phone or address.")))
        XCTAssertEqual(Items.parse(.contact, value: "[\"jane\"]"), .failure(.init(message: "Contact info must be a JSON object with a fullName, email, phone or address.")))
        XCTAssertEqual(Items.parse(.contact, value: "42"), .failure(.init(message: VaultItemKind.contact.shapeError)))
        XCTAssertEqual(Items.parse(.login, value: "[\"jane\",\"pw\"]"), .failure(.init(message: VaultItemKind.login.shapeError)))
    }

    // MARK: parse reports what validate does (items.test.ts: "reports the same message validateVaultItem does")

    func testParseAndValidateGiveTheSameMessage() {
        let invalid: [(VaultItemKind, [String: String])] = [
            (.card, card(["number": "4242424242424241"])),
            (.login, ["username": "jane"]),
            (.contact, ["email": "nope"]),
            (.contact, [:]),
            (.card, card(["expMonth": "13"])),
        ]
        for (kind, fields) in invalid {
            let object = fields.map { "\"\($0.key)\":\"\($0.value)\"" }.sorted().joined(separator: ",")
            let result = Items.parse(kind, value: "{\(object)}")
            XCTAssertEqual(result, .failure(.init(message: Items.validate(kind, fields) ?? "valid")), "\(kind) \(fields)")
        }
        // A number sent as a JSON number is the one case validate cannot be asked: its fields are strings.
        XCTAssertEqual(Items.parse(.card, value: #"{"number":4242,"expMonth":"04","expYear":"2027"}"#), .failure(.init(message: "number must be a string.")))
    }

    // MARK: Hints (items.test.ts: deriveHint)

    func testALongContactEmailIsCutToTheHintLimit() {
        let email = String(repeating: "a", count: 200) + "@appleseed.dev"
        let hint = Items.deriveHint(.contact, ["email": email])
        XCTAssertEqual(hint.unicodeScalars.count, 120)
        XCTAssertTrue(hint.hasSuffix("\u{2026}"))
        XCTAssertTrue(hint.hasPrefix(String(repeating: "a", count: 119)))
    }

    func testAnAddressOnlyHintIsJustAddress() {
        let hint = Items.deriveHint(.contact, ["address": "1 Infinite Loop"])
        XCTAssertEqual(hint, "Address")
        XCTAssertFalse(hint.contains("Infinite"))
    }

    func testAPhoneOnlyHintHoldsOnlyTheLastFourDigits() {
        let hint = Items.deriveHint(.contact, ["phone": "555 010 1234", "address": "1 Infinite Loop"])
        XCTAssertEqual(hint, "\u{2022}\u{2022}\u{2022}\u{2022} 1234")
        XCTAssertEqual(hint.filter { $0.isASCII && $0.isNumber }, "1234")
        XCTAssertFalse(hint.contains("Infinite"))
        XCTAssertEqual(Items.deriveHint(.contact, ["phone": "+1 (555) 010-1234"]), "\u{2022}\u{2022}\u{2022}\u{2022} 1234")
    }

    // MARK: A card hint with a line break is not a card hint

    func testCardBrandFromHintIsNilWhenALineBreakIsAnywhere() {
        let mask = "\u{2022}\u{2022}\u{2022}\u{2022}"
        // /^(.+) •••• \d{4}$/ has no m flag, "." does not match a line break and "$" is the end of the text.
        for hint in ["Visa \(mask) 4242\n", "Visa\n \(mask) 4242", "Visa \(mask) 4242\r\n", "Visa\r \(mask) 4242", "\nVisa \(mask) 4242",
                     "Visa \(mask) 424\n2", "Visa \(mask) 4242\u{2028}", "Visa \(mask) 4242 "] {
            XCTAssertNil(Items.cardBrand(fromHint: hint), hint.debugDescription)
        }
        XCTAssertEqual(Items.cardBrand(fromHint: "Visa \(mask) 4242"), .visa)
    }

    // MARK: Arabic-Indic digits (handoff 5.6: "Digits are ASCII only")

    private let arabicNumber = "\u{664}\u{662}\u{664}\u{662}\u{664}\u{662}\u{664}\u{662}\u{664}\u{662}\u{664}\u{662}\u{664}\u{662}\u{664}\u{662}"

    func testArabicIndicDigitsAreNotACardNumber() {
        XCTAssertEqual(
            Items.validate(.card, card(["number": arabicNumber])), "The card number must be 12 to 19 digits."
        )
        XCTAssertFalse(Items.luhnValid(arabicNumber))
        XCTAssertEqual(Items.formatCardNumber(arabicNumber), "")
        XCTAssertEqual(Items.cardBrand("\u{664}\u{662}"), .other)
        XCTAssertEqual(
            Items.validate(.card, card(["number": "4242 4242 4242 \u{664}\u{662}\u{664}\u{662}"])), "The card number must be 12 to 19 digits."
        )
    }

    func testArabicIndicDigitsAreNotAMonthYearSecurityCodeOrPhone() {
        XCTAssertEqual(Items.validate(.card, card(["expMonth": "\u{660}\u{664}"])), "The expiry month must be 1 to 12.")
        XCTAssertEqual(Items.validate(.card, card(["expMonth": "\u{664}"])), "The expiry month must be 1 to 12.")
        XCTAssertEqual(Items.validate(.card, card(["expYear": "\u{662}\u{667}"])), "The expiry year must be 2 or 4 digits.")
        XCTAssertEqual(Items.validate(.card, card(["expYear": "\u{662}\u{660}\u{662}\u{667}"])), "The expiry year must be 2 or 4 digits.")
        XCTAssertEqual(Items.validate(.card, card(["cvc": "\u{661}\u{662}\u{663}"])), "The security code must be 3 or 4 digits.")
        XCTAssertEqual(
            Items.validate(.contact, ["phone": "\u{660}\u{661}\u{662}\u{663}\u{664}\u{665}\u{666}\u{667}\u{668}"]),
            "The phone number needs at least 5 digits."
        )
        // The canonical form does not widen or pad them either.
        XCTAssertEqual(Items.canonical(.card, ["expMonth": "\u{664}"])["expMonth"], "\u{664}")
        XCTAssertEqual(Items.canonical(.card, ["expYear": "\u{662}\u{667}"])["expYear"], "\u{662}\u{667}")
        XCTAssertEqual(Items.deriveHint(.contact, ["phone": "\u{660}\u{661}\u{662}\u{663}\u{664} 5551234"]), "\u{2022}\u{2022}\u{2022}\u{2022} 1234")
    }

    func testFullwidthAndSuperscriptDigitsAreNotDigitsEither() {
        let fullwidth = "\u{FF14}\u{FF12}\u{FF14}\u{FF12}\u{FF14}\u{FF12}\u{FF14}\u{FF12}\u{FF14}\u{FF12}\u{FF14}\u{FF12}"
        XCTAssertEqual(Items.validate(.card, card(["number": fullwidth])), "The card number must be 12 to 19 digits.")
        XCTAssertEqual(Items.validate(.card, card(["number": "4242 4242 4242 \u{FF14}\u{FF12}\u{FF14}\u{FF12}"])), "The card number must be 12 to 19 digits.")
        XCTAssertEqual(Items.validate(.card, card(["expMonth": "\u{FF10}\u{FF14}"])), "The expiry month must be 1 to 12.")
        XCTAssertEqual(Items.validate(.card, card(["expYear": "\u{FF12}\u{FF17}"])), "The expiry year must be 2 or 4 digits.")
        XCTAssertEqual(Items.validate(.card, card(["cvc": "\u{B2}\u{B2}\u{B2}"])), "The security code must be 3 or 4 digits.")
        XCTAssertEqual(Items.validate(.card, card(["number": "4242 4242 4242 \u{B2}"])), "The card number must be 12 to 19 digits.")
        XCTAssertFalse(Items.luhnValid(fullwidth))
        XCTAssertEqual(Items.formatCardNumber("\u{B2}\u{BD}"), "")
        XCTAssertEqual(Items.validate(.contact, ["phone": "\u{FF11}\u{FF12}\u{FF13}\u{FF14}\u{FF15}"]), "The phone number needs at least 5 digits.")
    }

    // MARK: A name ending in a newline (name.ts: /^...$/ without the m flag, and ICU's "$" matches before a final one)

    func testANameWithALineBreakIsNotAName() {
        for name in ["abc\n", "abc\r\n", "abc\r", "abc\u{2028}", "abc\u{2029}", "\n", "\nabc", "a\nb", "abc\u{85}", "abc\u{0B}", "abc\u{0C}", " abc", "abc "] {
            XCTAssertFalse(Items.isValidName(name), name.debugDescription)
            XCTAssertFalse(Items.isAddressableName(name), name.debugDescription)
        }
    }

    func testTheFormTrimsAHarmlessNewlineBeforeSendingTheName() {
        XCTAssertEqual(Items.jsTrim("abc\n"), "abc")
        XCTAssertTrue(Items.isValidName(Items.jsTrim("abc\n")))
        XCTAssertEqual(Items.jsTrim("abc\r\n"), "abc")
        XCTAssertFalse(Items.isValidName(Items.jsTrim("a\nb")))
    }

    // MARK: Websites with a space (handoff 5.6: "URLs")

    func testAWebsiteWithASpaceInTheHostIsRefusedWhateverSpellsTheSpace() {
        let message = "The website must be a full address starting with http:// or https://."
        for url in ["https://exa mple.com/x", "http://exa mple.com:8080", "https://exa\u{A0}mple.com", "https://exa%20mple.com", "https://a%b.com"] {
            XCTAssertEqual(Items.validate(.login, ["username": "jane", "password": "pw", "url": url]), message, url.debugDescription)
        }
        XCTAssertEqual(Items.suggestName(.login, ["url": "https://exa mple.com", "username": "jane"]), "jane")
    }

    // MARK: Compare bytes, not canonical equivalents (SecretsTests compares Strings, which hides a normalisation bug)

    func testSerializingDoesNotNormalise() {
        let composed = Items.serialize(.contact, ["fullName": "Caf\u{E9}"])
        let decomposed = Items.serialize(.contact, ["fullName": "Cafe\u{301}"])
        XCTAssertEqual(composed, decomposed, "Swift calls these equal")
        XCTAssertNotEqual(Array(composed.utf8), Array(decomposed.utf8))
        XCTAssertEqual(Array(decomposed.utf8), Array(#"{"fullName":"Cafe"#.utf8) + [0xCC, 0x81] + Array(#""}"#.utf8))
        // Nothing else is rewritten either: U+2028 and DEL are written as they are, as JSON.stringify writes them.
        XCTAssertEqual(Array(Items.serialize(.contact, ["address": "a\u{2028}b"]).utf8), Array("{\"address\":\"a\u{2028}b\"}".utf8))
    }

    func testTheHintKeepsTheScalarsItWasGiven() {
        let hint = Items.deriveHint(.login, ["username": "Cafe\u{301}", "password": "pw"])
        XCTAssertEqual(Array(hint.unicodeScalars.map(\.value)), [0x43, 0x61, 0x66, 0x65, 0x301])
    }

    // MARK: Nothing in the vault code reaches for what the audit ruled out

    func testTheVaultSourceDoesNotUseRegexURLParsingOrFoundationsTextRules() throws {
        let models = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/HyperVaultKit/Models")
        guard FileManager.default.fileExists(atPath: models.appendingPathComponent("Secrets.swift").path) else {
            throw XCTSkip("the package sources are not next to the tests")
        }
        // NSRegularExpression and Swift's Regex read `\d` as any Unicode digit and `$` as before a final newline;
        // URL(string:) is RFC 3986 and since iOS 17 encodes what used to fail; CharacterSet, isNumber and
        // wholeNumberValue take other scripts' digits and white space that JavaScript does not; localized
        // comparison follows the device.
        let forbidden = [
            "NSRegularExpression", "Regex", ".regularExpression", "URL(string", "CharacterSet", "wholeNumberValue",
            "trimmingCharacters", "localizedCaseInsensitiveCompare", "localizedStandardCompare", "localizedCompare",
            "properties.isWhitespace", "Locale(",
        ]
        let files = [
            "Secrets.swift", "VaultText.swift", "VaultWebHost.swift", "VaultNameOrder.swift", "VaultLimits.swift", "VaultSpoken.swift",
            "VaultFetchCommand.swift", "VaultCopy.swift", "VaultOutcomes.swift", "AccountPane.swift",
        ]
        for file in files {
            let text = try String(contentsOf: models.appendingPathComponent(file), encoding: .utf8)
            for (number, line) in text.components(separatedBy: "\n").enumerated() {
                let code = line.components(separatedBy: "//").first ?? ""
                for token in forbidden where code.contains(token) {
                    XCTFail("\(file):\(number + 1) uses \(token)")
                }
                // The monogram in Secrets.swift is the one place `isNumber` stays, behind an `isASCII` check.
                if code.contains(".isNumber"), !(file == "Secrets.swift" && code.contains("isASCII")) {
                    XCTFail("\(file):\(number + 1) uses isNumber")
                }
            }
        }
    }
}
