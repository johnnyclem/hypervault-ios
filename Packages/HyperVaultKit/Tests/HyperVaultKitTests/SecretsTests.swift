import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

/// The typed entries, ported from lib/secrets/__tests__/items.test.ts so the app and the server cannot disagree,
/// and the /api/secrets wire shapes from app/api/secrets/**.
final class SecretsTests: XCTestCase {
    typealias Items = VaultItems

    /// Published test card numbers, one per brand the list draws a tile for.
    static let cards: [Items.CardBrand: String] = [
        .visa: "4242424242424242",
        .mastercard: "5555555555554444",
        .amex: "378282246310005",
        .discover: "6011111111111117",
        .other: "3566002020360505",
    ]

    /// `body` plus the digit that makes it pass Luhn, to build valid numbers of any length.
    func withCheckDigit(_ body: String) -> String {
        for digit in 0...9 where Items.luhnValid("\(body)\(digit)") { return "\(body)\(digit)" }
        XCTFail("no check digit for \(body)")
        return body
    }

    func card(_ overrides: [String: String] = [:]) -> [String: String] {
        ["number": Self.cards[.visa]!, "expMonth": "04", "expYear": "2027"].merging(overrides) { _, new in new }
    }

    func login(_ overrides: [String: String] = [:]) -> [String: String] {
        ["username": "jane@appleseed.dev", "password": "correct horse"].merging(overrides) { _, new in new }
    }

    // MARK: Kinds

    func testKindsAndCategories() {
        XCTAssertEqual(SecretKind.allCases.map(\.rawValue), ["opaque", "header", "oauth_grant", "login", "card", "contact"])
        XCTAssertEqual(SecretKind.allCases.map(\.label), ["Key", "MCP header", "OAuth grant", "Login", "Card", "Contact info"])
        XCTAssertEqual(VaultCategory.allCases.map(\.label), ["Logins", "Cards", "Contact info", "Keys"])
        // Every kind is in exactly one category, and agrees with the kind's own answer.
        let listed = VaultCategory.allCases.flatMap(\.kinds)
        XCTAssertEqual(Set(listed), Set(SecretKind.allCases))
        XCTAssertEqual(listed.count, SecretKind.allCases.count)
        for category in VaultCategory.allCases {
            for kind in category.kinds { XCTAssertEqual(kind.category, category) }
        }
        XCTAssertEqual(SecretKind.login.vaultItemKind, .login)
        XCTAssertNil(SecretKind.opaque.vaultItemKind)
    }

    func testUnknownKindReadsAsKey() throws {
        let row = try HVCoding.decoder().decode(VaultSecret.self, from: Data(#"{"id":"s1","name":"n","kind":"passkey"}"#.utf8))
        XCTAssertEqual(row.kind, .opaque)
        XCTAssertEqual(row.kind.category, .keys)
    }

    // MARK: Luhn and brands

    func testLuhn() {
        for number in Array(Self.cards.values) + ["4111111111111111", "2223003122003222", "371449635398431"] {
            XCTAssertTrue(Items.luhnValid(number), number)
        }
        XCTAssertFalse(Items.luhnValid("4242424242424241"))
        XCTAssertFalse(Items.luhnValid("4242424242422442"))  // a swapped pair
        XCTAssertTrue(Items.luhnValid("4242 4242 4242 4242"))
        XCTAssertTrue(Items.luhnValid("4242-4242-4242-4242"))
        XCTAssertFalse(Items.luhnValid("4242.4242.4242.4242"))
        XCTAssertFalse(Items.luhnValid("4242x24242424242"))
        XCTAssertFalse(Items.luhnValid(""))
        XCTAssertFalse(Items.luhnValid("   "))
    }

    func testCardBrandsFromTheirPublishedNumbers() {
        for (brand, number) in Self.cards { XCTAssertEqual(Items.cardBrand(number), brand, number) }
        let prefixes: [(String, Items.CardBrand)] = [
            ("4", .visa), ("4000056655665556", .visa),
            ("51", .mastercard), ("52", .mastercard), ("53", .mastercard), ("54", .mastercard), ("55", .mastercard),
            ("2221", .mastercard), ("2500", .mastercard), ("2720", .mastercard),
            ("34", .amex), ("37", .amex),
            ("6011", .discover), ("65", .discover), ("644", .discover), ("649", .discover),
            ("50", .other), ("56", .other), ("2220", .other), ("2721", .other), ("222", .other),
            ("35", .other), ("36", .other), ("6010", .other), ("643", .other), ("66", .other), ("", .other),
        ]
        for (prefix, brand) in prefixes { XCTAssertEqual(Items.cardBrand(prefix), brand, prefix) }
        XCTAssertEqual(Items.cardBrand("3782 822463 10005"), .amex)
        XCTAssertEqual(Items.cardBrand(" 2221-0000"), .mastercard)
        XCTAssertEqual(Items.CardBrand.allCases.map(\.label), ["Visa", "Mastercard", "Amex", "Discover", "Card"])
    }

    func testFormatCardNumber() {
        let cases: [(String, String)] = [
            ("4242424242424242", "4242 4242 4242 4242"), ("42424", "4242 4"), ("4242", "4242"),
            ("4242-4242 4242.4242", "4242 4242 4242 4242"),
            ("4242424242424242424", "4242 4242 4242 4242 424"),
            ("42424242424242424241234", "4242 4242 4242 4242 424"),
            ("378282246310005", "3782 822463 10005"), ("3782822463", "3782 822463"), ("37828", "3782 8"),
            ("3782822463100059999", "3782 822463 10005"), ("", ""), ("abc", ""),
        ]
        for (input, shown) in cases { XCTAssertEqual(Items.formatCardNumber(input), shown, input) }
        for number in Self.cards.values {
            let once = Items.formatCardNumber(number)
            XCTAssertEqual(Items.formatCardNumber(once), once)
        }
    }

    // MARK: Validation: login

    func testLoginValidation() {
        XCTAssertNil(Items.validate(.login, login()))
        XCTAssertNil(Items.validate(.login, login(["url": "https://github.com/login"])))
        XCTAssertNil(Items.validate(.login, login(["url": "http://localhost:3000"])))
        XCTAssertNil(Items.validate(.login, login(["notes": "2FA on the phone"])))

        XCTAssertEqual(Items.validate(.login, ["password": "pw"]), "Add the username.")
        XCTAssertEqual(Items.validate(.login, login(["username": "   "])), "Add the username.")
        XCTAssertEqual(Items.validate(.login, ["username": "jane"]), "Add the password.")
        XCTAssertEqual(Items.validate(.login, login(["password": ""])), "Add the password.")
        XCTAssertEqual(Items.validate(.login, login(["password": " \t "])), "Add the password.")

        let message = "The website must be a full address starting with http:// or https://."
        for url in ["github.com", "ftp://github.com", "javascript:alert(1)", "https://", "https://exa mple.com"] {
            XCTAssertEqual(Items.validate(.login, login(["url": url])), message, url)
        }
        XCTAssertNil(Items.validate(.login, login(["url": "  "])), "a blank website is no website")
    }

    // MARK: Validation: card

    func testCardValidation() {
        XCTAssertNil(Items.validate(.card, card()))
        XCTAssertNil(Items.validate(.card, card(["number": "4242 4242 4242 4242", "expMonth": "4", "expYear": "27"])))
        XCTAssertNil(Items.validate(.card, card(["number": "4242-4242-4242-4242", "expMonth": "12"])))
        XCTAssertNil(Items.validate(.card, card(["number": Self.cards[.amex]!, "cardholder": "Jane", "cvc": "1234"])))
        XCTAssertNil(Items.validate(.card, card(["cvc": "123"])))
        // An expired card is still a card someone may want to keep.
        XCTAssertNil(Items.validate(.card, card(["expMonth": "01", "expYear": "2001"])))
        XCTAssertNil(Items.validate(.card, card(["expYear": "99"])))
    }

    func testCardNumberTakesTwelveToNineteenDigits() {
        let message = "The card number must be 12 to 19 digits."
        XCTAssertNil(Items.validate(.card, card(["number": withCheckDigit(String(repeating: "4", count: 11))])))
        XCTAssertNil(Items.validate(.card, card(["number": withCheckDigit(String(repeating: "4", count: 18))])))
        XCTAssertEqual(Items.validate(.card, card(["number": withCheckDigit(String(repeating: "4", count: 10))])), message)
        XCTAssertEqual(Items.validate(.card, card(["number": withCheckDigit(String(repeating: "4", count: 19))])), message)
        XCTAssertEqual(Items.validate(.card, card(["number": "4242.4242.4242.4242"])), message)
        XCTAssertEqual(Items.validate(.card, card(["number": "4242 4242 4242 424x"])), message)
        XCTAssertEqual(Items.validate(.card, ["expMonth": "04", "expYear": "2027"]), message)
    }

    func testCardLuhnMonthYearAndCode() {
        XCTAssertEqual(
            Items.validate(.card, card(["number": "4242424242424241"])),
            "That card number doesn't look right. Check it for a typo."
        )
        for month in ["0", "00", "13", "1a", "012", ""] {
            XCTAssertEqual(Items.validate(.card, card(["expMonth": month])), "The expiry month must be 1 to 12.", month)
        }
        for year in ["7", "202", "20271", "2o27", ""] {
            XCTAssertEqual(Items.validate(.card, card(["expYear": year])), "The expiry year must be 2 or 4 digits.", year)
        }
        for cvc in ["12", "12345", "abc"] {
            XCTAssertEqual(Items.validate(.card, card(["cvc": cvc])), "The security code must be 3 or 4 digits.", cvc)
        }
        XCTAssertNil(Items.validate(.card, card(["cvc": ""])))
    }

    // MARK: Validation: contact

    func testContactValidation() {
        XCTAssertNil(Items.validate(.contact, ["fullName": "Jane Appleseed"]))
        XCTAssertNil(Items.validate(.contact, ["email": "jane@appleseed.dev"]))
        XCTAssertNil(Items.validate(.contact, ["phone": "+1 (555) 010-1234"]))
        XCTAssertNil(Items.validate(.contact, ["address": "1 Infinite Loop\nCupertino"]))

        let empty = "Add a name, email, phone or address."
        XCTAssertEqual(Items.validate(.contact, [:]), empty)
        XCTAssertEqual(Items.validate(.contact, ["fullName": " ", "email": "", "phone": "\n", "address": "  "]), empty)

        for email in ["jane", "jane@", "jane@appleseed", "jane doe@appleseed.dev", "@appleseed.dev", "a@b@c.dev"] {
            XCTAssertEqual(Items.validate(.contact, ["email": email]), "That email address doesn't look right.", email)
        }
        XCTAssertEqual(Items.validate(.contact, ["phone": "1234"]), "The phone number needs at least 5 digits.")
        XCTAssertEqual(Items.validate(.contact, ["phone": "call me"]), "The phone number needs at least 5 digits.")
        XCTAssertNil(Items.validate(.contact, ["phone": "12345"]))
    }

    // MARK: Parse and serialize

    func testParseReturnsTheCanonicalEntry() throws {
        let value = #"{"cvc":" 123 ","expYear":"27","expMonth":"4","number":"4242 4242-4242 4242","cardholder":"  Jane Appleseed "}"#
        let fields = try Items.parse(.card, value: value).get()
        XCTAssertEqual(fields, ["cardholder": "Jane Appleseed", "number": "4242424242424242", "expMonth": "04", "expYear": "2027", "cvc": "123"])
    }

    func testParseDropsUnknownKeysAndEmptyFields() throws {
        let value = #"{"username":"jane","password":"pw","url":"","notes":"  ","number":"4242424242424242","admin":true}"#
        XCTAssertEqual(try Items.parse(.login, value: value).get(), ["username": "jane", "password": "pw"])
    }

    func testParseKeepsThePasswordExactlyAsTyped() throws {
        XCTAssertEqual(try Items.parse(.login, value: #"{"username":" jane ","password":" pw "}"#).get(), ["username": "jane", "password": " pw "])
    }

    func testControlCharactersDoNotCountAsFillingAFieldIn() throws {
        let blank = Items.parse(.login, value: #"{"username":"\u0000\u0001","password":"pw"}"#)
        XCTAssertEqual(blank, .failure(.init(message: "Add the username.")))
        XCTAssertEqual(try Items.parse(.contact, value: #"{"email":"jane@appleseed.dev\u0000"}"#).get(), ["email": "jane@appleseed.dev"])
    }

    func testParseRefusesWhatIsNotAnObject() {
        let message = "A login must be a JSON object with a username and password."
        for value in ["", "not json", "{", "null", "[]", "\"jane\"", "42"] {
            XCTAssertEqual(Items.parse(.login, value: value), .failure(.init(message: message)), value)
        }
        XCTAssertEqual(Items.parse(.card, value: #"{"number":4242424242424242}"#), .failure(.init(message: "number must be a string.")))
        XCTAssertEqual(Items.parse(.login, value: #"{"username":"a","password":"b","url":true}"#), .failure(.init(message: "url must be a string.")))
        // null is absent, not a wrong type
        XCTAssertNoThrow(try Items.parse(.login, value: #"{"username":"a","password":"b","notes":null}"#).get())
    }

    func testSerializeWritesFixedOrderAndTrimmedStrings() {
        let item = ["cvc": "123", "expYear": "27", "expMonth": "4", "number": " 4242 4242 4242 4242 ", "cardholder": " Jane Appleseed "]
        XCTAssertEqual(
            Items.serialize(.card, item),
            #"{"cardholder":"Jane Appleseed","number":"4242424242424242","expMonth":"04","expYear":"2027","cvc":"123"}"#
        )
        XCTAssertEqual(
            Items.serialize(.login, ["url": " ", "username": " jane ", "password": " pw ", "notes": ""]),
            #"{"username":"jane","password":" pw "}"#
        )
        XCTAssertEqual(Items.serialize(.contact, ["email": " jane@appleseed.dev ", "phone": "", "address": " "]), #"{"email":"jane@appleseed.dev"}"#)
    }

    func testTheSameCardTypedTwoWaysStoresTheSameBytes() {
        let spaced = Items.serialize(.card, card(["number": "4242 4242 4242 4242", "expMonth": "4", "expYear": "27"]))
        let dashed = Items.serialize(.card, card(["number": "4242-4242-4242-4242", "expMonth": "04", "expYear": "2027"]))
        XCTAssertEqual(spaced, dashed)
    }

    func testSerializeStripsControlsButKeepsLinesAndThePasswordAsTyped() {
        XCTAssertEqual(
            Items.serialize(.login, ["username": "ja\u{0}ne\u{7}", "password": "p\u{0}w", "notes": "line 1\nline\u{0} 2"]),
            #"{"username":"jane","password":"p\u0000w","notes":"line 1\nline 2"}"#
        )
        XCTAssertEqual(
            Items.serialize(.contact, ["fullName": "Jane\u{1b} Appleseed", "address": "1 Loop\r\nCupertino\u{7f}"]),
            #"{"fullName":"Jane Appleseed","address":"1 Loop\r\nCupertino"}"#
        )
    }

    func testSerializeNeverWritesARawControlCharacter() throws {
        let controls = String((0..<32).map { Character(Unicode.Scalar($0)!) })
        let stored = Items.serialize(.login, ["username": "jane\(controls)", "password": controls, "notes": "a\(controls)b"])
        XCTAssertFalse(stored.unicodeScalars.contains { $0.value < 0x20 })
        let back = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(stored.utf8)) as? [String: String])
        XCTAssertEqual(back, ["username": "jane", "password": controls, "notes": "a\t\n\rb"])
    }

    func testSerializeRoundTripsThroughParse() throws {
        let entries: [(VaultItemKind, [String: String])] = [
            (.login, login(["url": "https://github.com", "notes": "work"])),
            (.card, card(["cardholder": "Jane", "cvc": "123"])),
            (.contact, ["fullName": "Jane", "email": "jane@appleseed.dev", "phone": "+1 555 010 1234", "address": "Home"]),
        ]
        for (kind, item) in entries {
            let stored = Items.serialize(kind, item)
            let parsed = try Items.parse(kind, value: stored).get()
            XCTAssertEqual(Items.serialize(kind, parsed), stored)
        }
    }

    // MARK: Hints

    func testCardHintNamesBrandAndLastFour() {
        XCTAssertEqual(Items.deriveHint(.card, card()), "Visa •••• 4242")
        XCTAssertEqual(Items.deriveHint(.card, card(["number": Self.cards[.mastercard]!])), "Mastercard •••• 4444")
        XCTAssertEqual(Items.deriveHint(.card, card(["number": Self.cards[.amex]!])), "Amex •••• 0005")
        XCTAssertEqual(Items.deriveHint(.card, card(["number": Self.cards[.discover]!])), "Discover •••• 1117")
        XCTAssertEqual(Items.deriveHint(.card, card(["number": Self.cards[.other]!])), "Card •••• 0505")
        XCTAssertEqual(Items.deriveHint(.card, card(["number": "4242 4242 4242 4242"])), "Visa •••• 4242")
    }

    func testCardHintNeverCarriesMoreThanTheLastFour() {
        for number in Self.cards.values {
            let hint = Items.deriveHint(.card, card(["number": number, "cvc": "987", "cardholder": "Jane Appleseed"]))
            XCTAssertFalse(hint.contains(number))
            XCTAssertFalse(hint.contains("987"))
            XCTAssertFalse(hint.contains("Jane"))
            XCTAssertEqual(hint.filter(\.isNumber), String(number.suffix(4)))
        }
    }

    func testLoginAndContactHints() {
        let item = login(["username": " jane ", "password": "hunter2-secret", "url": "https://github.com"])
        let hint = Items.deriveHint(.login, item)
        XCTAssertEqual(hint, "jane")
        XCTAssertFalse(hint.contains("hunter2"))
        XCTAssertFalse(hint.contains("github"))

        let all = ["fullName": "Jane Appleseed", "email": "jane@appleseed.dev", "phone": "+1 (555) 010-1234", "address": "1 Loop"]
        XCTAssertEqual(Items.deriveHint(.contact, all), "jane@appleseed.dev")
        XCTAssertEqual(Items.deriveHint(.contact, all.filter { $0.key != "email" }), "•••• 1234")
        XCTAssertEqual(Items.deriveHint(.contact, ["fullName": "Jane Appleseed", "address": "1 Loop"]), "Jane Appleseed")
        XCTAssertEqual(Items.deriveHint(.contact, ["address": "1 Loop"]), "Address")
        XCTAssertEqual(Items.deriveHint(.contact, ["phone": "555 010 1234", "address": "1 Infinite Loop"]), "•••• 1234")
    }

    func testHintsCarryNoControlCharacters() {
        XCTAssertEqual(Items.deriveHint(.login, login(["username": "jane\u{0}"])), "jane")
        XCTAssertEqual(Items.deriveHint(.contact, ["email": "\u{0}jane@appleseed.dev"]), "jane@appleseed.dev")
        XCTAssertEqual(Items.deriveHint(.contact, ["fullName": "Jane\t\u{0}Appleseed\n"]), "JaneAppleseed")
    }

    func testHintIsCutToTheColumnLimitInCodePoints() {
        let long = Items.deriveHint(.login, login(["username": String(repeating: "j", count: 300)]))
        XCTAssertEqual(long.unicodeScalars.count, Items.hintMax)
        XCTAssertTrue(long.hasSuffix("…"))
        XCTAssertTrue(long.hasPrefix(String(repeating: "j", count: Items.hintMax - 1)))

        let exact = String(repeating: "j", count: Items.hintMax)
        XCTAssertEqual(Items.deriveHint(.login, login(["username": exact])), exact)

        let emoji = Items.deriveHint(.login, login(["username": String(repeating: "😀", count: 200)]))
        XCTAssertEqual(emoji.unicodeScalars.count, Items.hintMax)
        XCTAssertTrue(emoji.hasSuffix("…"))
        XCTAssertTrue(emoji.dropLast().allSatisfy { $0 == "😀" })
    }

    func testCardBrandFromHintRoundTrips() {
        for (brand, number) in Self.cards {
            XCTAssertEqual(Items.cardBrand(fromHint: Items.deriveHint(.card, card(["number": number]))), brand, number)
        }
        let notCardHints: [String?] = [nil, "", "jane@appleseed.dev", "•••• 1234", "Address", "Visa", "Visa •••• 42", "Diners •••• 1234", "Visa •••• 4242 "]
        for hint in notCardHints { XCTAssertNil(Items.cardBrand(fromHint: hint), String(describing: hint)) }
    }

    // MARK: Names

    func testNameRule() {
        for name in ["github.com", "visa-4242", "a", "A_b.c-d", String(repeating: "a", count: 100)] { XCTAssertTrue(Items.isValidName(name), name) }
        for name in ["", "has space", "Chase Sapphire", "slash/y", "ünï", String(repeating: "a", count: 101)] { XCTAssertFalse(Items.isValidName(name), name) }
    }

    func testSuggestedNames() {
        XCTAssertEqual(Items.suggestName(.login, ["url": "https://www.github.com/login", "username": "jane"]), "github.com")
        XCTAssertEqual(Items.suggestName(.login, ["url": "http://WWW.Example.COM:8080/x"]), "example.com")
        XCTAssertEqual(Items.suggestName(.login, ["url": "news.ycombinator.com"]), "news.ycombinator.com")
        XCTAssertEqual(Items.suggestName(.login, ["username": "jane@appleseed.dev"]), "jane-appleseed.dev")
        XCTAssertEqual(Items.suggestName(.login, ["url": "ftp://files.example.com", "username": "jane"]), "jane")
        XCTAssertEqual(Items.suggestName(.login, ["url": "   ", "username": " jane "]), "jane")

        XCTAssertEqual(Items.suggestName(.card, ["number": "4242 4242 4242 4242"]), "visa-4242")
        XCTAssertEqual(Items.suggestName(.card, ["number": Self.cards[.mastercard]!]), "mastercard-4444")
        XCTAssertEqual(Items.suggestName(.card, ["number": Self.cards[.amex]!]), "amex-0005")
        XCTAssertEqual(Items.suggestName(.card, ["number": Self.cards[.discover]!]), "discover-1117")
        XCTAssertEqual(Items.suggestName(.card, ["number": Self.cards[.other]!]), "card-0505")

        XCTAssertEqual(Items.suggestName(.contact, ["email": "jane@appleseed.dev"]), "contact")
        XCTAssertEqual(Items.suggestName(.contact, ["fullName": "Jane", "address": "1 Loop"]), "contact")
        XCTAssertEqual(Items.suggestName(.contact, ["phone": "555 010 1234"]), "contact")
        XCTAssertEqual(Items.suggestName(.contact, ["address": "1 Loop"]), "home")
    }

    func testSuggestionIsEmptyWithNothingToNameItBy() {
        XCTAssertEqual(Items.suggestName(.login, [:]), "")
        XCTAssertEqual(Items.suggestName(.login, ["username": "@@@"]), "")
        XCTAssertEqual(Items.suggestName(.card, [:]), "")
        XCTAssertEqual(Items.suggestName(.card, ["number": "424"]), "")
        XCTAssertEqual(Items.suggestName(.contact, [:]), "")
        XCTAssertEqual(Items.suggestName(.contact, ["fullName": "  "]), "")
    }

    func testSuggestionsAreAlwaysValidNames() {
        let logins: [[String: String]] = [
            ["username": String(repeating: "j", count: 300)], ["username": "...jane..."], ["username": "-_-"],
            ["username": "Jöhn Smith"], ["username": "名前"], ["username": "a/b\\c?d#e"],
            ["url": "https://[::1]:3000/"], ["url": "https://xn--bcher-kva.example/"], ["url": "https://bücher.example/"],
            ["url": "https://\(String(repeating: "a", count: 60)).\(String(repeating: "b", count: 60)).com"],
            ["url": "not a url at all", "username": "x y z"],
        ]
        var suggestions = logins.map { Items.suggestName(.login, $0) }
        suggestions += Self.cards.values.map { Items.suggestName(.card, ["number": $0]) }
        suggestions += [Items.suggestName(.contact, ["address": "x"]), Items.suggestName(.contact, ["email": "x@y.z"])]
        for name in suggestions { XCTAssertTrue(name.isEmpty || Items.isValidName(name), name) }
        XCTAssertGreaterThan(suggestions.filter { !$0.isEmpty }.count, 10)
    }

    // MARK: Rows

    func testRowDecodingFromTheListRoute() throws {
        // app/api/secrets/route.ts: { secrets: SecretMetaRow[] }, oldest first.
        let json = """
        {"secrets":[
          {"id":"a1","name":"github.com","kind":"login","description":null,"created_at":"2026-10-20T10:00:00.123456+00:00","updated_at":"2026-10-20T10:00:00+00:00","last_accessed_at":"2026-10-24T09:30:00.5+00:00","hint":"jane@appleseed.dev"},
          {"id":"b2","name":"visa-4242","kind":"card","description":"work","created_at":"2026-10-21T10:00:00Z","updated_at":"2026-10-21T10:00:00Z","last_accessed_at":null,"hint":"Visa •••• 4242"},
          {"id":"c3","name":"www.stripe.com","kind":"opaque","description":null,"created_at":"2026-10-22T10:00:00Z","updated_at":"2026-10-22T10:00:00Z","last_accessed_at":null,"hint":null}
        ]}
        """
        let list = try HVCoding.decoder().decode(VaultSecretList.self, from: Data(json.utf8))
        XCTAssertEqual(list.secrets.map(\.name), ["github.com", "visa-4242", "www.stripe.com"])
        XCTAssertEqual(list.secrets[0].subtitle, "jane@appleseed.dev")
        XCTAssertNotNil(list.secrets[0].lastAccessedAt)
        XCTAssertEqual(list.secrets[1].cardBrand, .visa)
        XCTAssertNil(list.secrets[0].cardBrand)
        XCTAssertEqual(list.secrets[2].subtitle, "Key")
        XCTAssertEqual(list.secrets[2].monogram, "S")
        XCTAssertEqual(list.secrets[0].monogram, "G")
        XCTAssertEqual(list.secrets[1].description, "work")
    }

    func testRowFromADatabaseWithoutTheHintColumn() throws {
        let json = #"{"secrets":[{"id":"a1","name":"n","kind":"login","description":null,"created_at":"2026-10-20T10:00:00Z","updated_at":"2026-10-20T10:00:00Z","last_accessed_at":null,"hint":null}]}"#
        let row = try HVCoding.decoder().decode(VaultSecretList.self, from: Data(json.utf8)).secrets[0]
        XCTAssertEqual(row.subtitle, "Login")
    }

    // MARK: Wire

    func client(_ transport: MockTransport) -> HVClient {
        HVClient(baseURL: URL(string: "https://hv.test")!, transport: transport, tokens: StaticTokenProvider(), retry: .none)
    }

    func testCreateSendsTheNameKindAndValue() async throws {
        let transport = MockTransport(routes: [
            .json(.post, "/api/secrets", #"{"secret":{"id":"s1","name":"visa-4242","kind":"card","description":null,"created_at":"2026-10-24T01:00:00Z","updated_at":"2026-10-24T01:00:00Z","last_accessed_at":null,"hint":"Visa •••• 4242"}}"#)
        ])
        let value = Items.serialize(.card, card())
        let created = try await client(transport).send(.createVaultSecret(name: "visa-4242", kind: .card, value: value, description: "work"))
        XCTAssertEqual(created.secret.hint, "Visa •••• 4242")

        let requestRequests = await transport.requests(matching: "/api/secrets")

        let request = try XCTUnwrap(requestRequests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer preview-token")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["name": "visa-4242", "kind": "card", "value": value, "description": "work"])
    }

    func testCreateWithATakenNameSurfacesTheServersSentence() async {
        let transport = MockTransport(routes: [.failure(.post, "/api/secrets", status: 409, message: "A secret with that name already exists.")])
        do {
            _ = try await client(transport).send(.createVaultSecret(name: "n", kind: .opaque, value: "v"))
            XCTFail("expected a refusal")
        } catch let error as HVError {
            XCTAssertEqual(error.status, 409)
            XCTAssertEqual(error.userMessage, "A secret with that name already exists.")
        } catch {
            XCTFail("\(error)")
        }
    }

    func testUpdateSendsOnlyWhatChanged() async throws {
        let transport = MockTransport(routes: [
            .json(.patch, "/api/secrets/github.com", #"{"secret":{"id":"a1","name":"gh","kind":"login","description":"work","created_at":"2026-10-20T10:00:00Z","updated_at":"2026-10-24T10:00:00Z","last_accessed_at":null,"hint":"jane"}}"#)
        ])
        let updated = try await client(transport).send(.updateVaultSecret(name: "github.com", newName: "gh", description: "work"))
        XCTAssertEqual(updated.secret.name, "gh")
        let requestRequests = await transport.requests(matching: "/api/secrets/github.com")
        let request = try XCTUnwrap(requestRequests.first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["new_name": "gh", "description": "work"])
    }

    func testGrantsRoundTrip() async throws {
        let transport = MockTransport(routes: [
            .json(.get, "/api/secrets/github.com/grants", #"{"grants":[{"id":"g1","api_key_id":"k1","created_at":"2026-10-24T10:00:00Z"}]}"#),
            .json(.post, "/api/secrets/github.com/grants", #"{"grant":{"id":"g2","api_key_id":"k2","created_at":"2026-10-24T10:01:00Z"}}"#),
            .json(.delete, "/api/secrets/github.com/grants", #"{"ok":true}"#),
            .json(.delete, "/api/secrets/github.com", #"{"ok":true,"deleted":"github.com"}"#),
        ])
        let hv = client(transport)
        let grants = try await hv.send(.secretGrants(name: "github.com"))
        XCTAssertEqual(grants.grants.map(\.apiKeyId), ["k1"])
        let granted = try await hv.send(.grantSecret(name: "github.com", keyID: "k2"))
        XCTAssertEqual(granted.grant.apiKeyId, "k2")
        _ = try await hv.send(.revokeSecretGrant(name: "github.com", keyID: "k2"))
        _ = try await hv.send(.deleteVaultSecret(name: "github.com"))

        let revokeRequests = await transport.requests(matching: "/api/secrets/github.com/grants")

        let revoke = try XCTUnwrap(revokeRequests.last)
        XCTAssertEqual(revoke.httpMethod, "DELETE")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(revoke.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["api_key_id": "k2"])
    }

    func testAnAgentKeyIsRefusedByTheManagerWithItsOwnSentence() async {
        let transport = MockTransport(routes: [.failure(.get, "/api/secrets", status: 403, message: "API keys cannot manage the vault — use a signed-in session.")])
        do {
            _ = try await client(transport).send(.vaultSecrets)
            XCTFail("expected a refusal")
        } catch let error as HVError {
            XCTAssertEqual(error.status, 403)
        } catch {
            XCTFail("\(error)")
        }
    }
}
