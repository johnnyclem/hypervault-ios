import XCTest
@testable import HyperVaultKit

/// The vault list's order: Node 22's `Intl.Collator("en", { sensitivity: "base" })`, stable. The expected lists
/// below are what that collator, with a stable sort, made of the inputs; they are not hand-written.
final class VaultNameOrderTests: XCTestCase {
    private static let asciiInput = ["www.stripe.com", "Zed", "visa-4242", "stripe.key", "stripe-key", "stripe_key", "Stripe", "github.com", "b", "amex-0005", "aa", "a2", "a10", "a1", "a.b", "a.", "a-b", "a-", "a_b", "a_", "a", "2", "1x", "10", ".x", "-x", "_x", "github", "Github", "GITHUB", "A", "zed", "Z", "mastercard-4444", "discover-1117", "card-0505", "home", "contact", "a.1", "a-1", "a_1", "a9", "a0", "0", "9", "z9", "z10", "y", "x"]
    private static let asciiOrder = ["_x", "-x", ".x", "0", "10", "1x", "2", "9", "a", "A", "a_", "a_1", "a_b", "a-", "a-1", "a-b", "a.", "a.1", "a.b", "a0", "a1", "a10", "a2", "a9", "aa", "amex-0005", "b", "card-0505", "contact", "discover-1117", "github", "Github", "GITHUB", "github.com", "home", "mastercard-4444", "Stripe", "stripe_key", "stripe-key", "stripe.key", "visa-4242", "www.stripe.com", "x", "y", "Z", "z10", "z9", "Zed", "zed"]
    private static let accentInput = ["zebra", "Z\u{FC}rich", "zulu", "\u{E9}clair", "eclair", "Eclair", "ecole", "\u{E9}cole", "ecol\u{E9}", "uber", "\u{DC}ber", "\u{FC}ber", "udo", "\u{E5}ngstr\u{F6}m", "angstrom", "Angstrom", "\u{E5}ngstrom", "stra\u{DF}e", "strasse", "Strasse", "\u{F8}lse", "olse", "Olse", "oz", "na\u{EF}ve", "naive", "Naive", "e\u{301}clair", "cafe", "caf\u{E9}", "cafe\u{301}", "Cafe", "cafes", "caf\u{E9}s"]
    private static let accentOrder = ["\u{E5}ngstr\u{F6}m", "angstrom", "Angstrom", "\u{E5}ngstrom", "cafe", "caf\u{E9}", "cafe\u{301}", "Cafe", "cafes", "caf\u{E9}s", "\u{E9}clair", "eclair", "Eclair", "e\u{301}clair", "ecole", "\u{E9}cole", "ecol\u{E9}", "na\u{EF}ve", "naive", "Naive", "\u{F8}lse", "olse", "Olse", "oz", "stra\u{DF}e", "strasse", "Strasse", "uber", "\u{DC}ber", "\u{FC}ber", "udo", "zebra", "zulu", "Z\u{FC}rich"]

    func testAnASCIIListSortsAsTheWebSortsIt() {
        XCTAssertEqual(VaultNameOrder.sorted(Self.asciiInput, by: { $0 }), Self.asciiOrder)
    }

    func testAccentsAndCaseDoNotCount() {
        XCTAssertEqual(VaultNameOrder.sorted(Self.accentInput, by: { $0 }), Self.accentOrder)
    }

    func testTheOrderDoesNotDependOnTheInputOrder() {
        // Names that differ by more than case and accents sort the same however they come in.
        let names = ["b", "a10", "a2", "A1", "_x", "x-y", "x.y", "x_y", "9", "10", "www.stripe.com", "Stripe"]
        let expected = VaultNameOrder.sorted(names, by: { $0 })
        XCTAssertEqual(VaultNameOrder.sorted(names.reversed(), by: { $0 }), expected)
        XCTAssertEqual(VaultNameOrder.sorted(names.shuffledDeterministically(), by: { $0 }), expected)
    }

    func testTheOrderOfPunctuationAndDigitsAndLetters() {
        XCTAssertEqual(VaultNameOrder.sorted(["a", "1", ".", "-", "_"], by: { $0 }), ["_", "-", ".", "1", "a"])
        XCTAssertEqual(VaultNameOrder.sorted(["a1", "a", "a-", "a.", "a_", "aa"], by: { $0 }), ["a", "a_", "a-", "a.", "a1", "aa"])
        // Digits are not read as numbers.
        XCTAssertEqual(VaultNameOrder.sorted(["a2", "a10", "a1"], by: { $0 }), ["a1", "a10", "a2"])
        // A name sorts before a longer one that begins with it.
        XCTAssertEqual(VaultNameOrder.sorted(["github.com", "github"], by: { $0 }), ["github", "github.com"])
    }

    func testCaseOnlyTiesKeepTheInputOrder() {
        XCTAssertEqual(VaultNameOrder.sorted(["Github", "github", "GITHUB"], by: { $0 }), ["Github", "github", "GITHUB"])
        XCTAssertEqual(VaultNameOrder.sorted(["github", "GITHUB", "Github"], by: { $0 }), ["github", "GITHUB", "Github"])
        XCTAssertEqual(VaultNameOrder.compare("Github", "github"), .orderedSame)
        XCTAssertEqual(VaultNameOrder.compare("\u{E9}", "e"), .orderedSame)
        XCTAssertEqual(VaultNameOrder.compare("e\u{301}", "\u{E9}"), .orderedSame)
    }

    func testCompare() {
        XCTAssertEqual(VaultNameOrder.compare("a", "b"), .orderedAscending)
        XCTAssertEqual(VaultNameOrder.compare("B", "a"), .orderedDescending)
        XCTAssertEqual(VaultNameOrder.compare("a", "a_"), .orderedAscending)
        XCTAssertEqual(VaultNameOrder.compare("a-b", "ab"), .orderedAscending)
        XCTAssertEqual(VaultNameOrder.compare("", "a"), .orderedAscending)
        XCTAssertEqual(VaultNameOrder.compare("", ""), .orderedSame)
        // Not the device's language: "aa" is before "b" everywhere, and "z" is before "\u{E5}" only after Latin.
        XCTAssertEqual(VaultNameOrder.compare("aa", "b"), .orderedAscending)
        XCTAssertEqual(VaultNameOrder.compare("z", "\u{44F}"), .orderedAscending)
    }

    func testSortingSecretsKeepsTheOldestFirstAmongTies() {
        func secret(_ id: String, _ name: String) -> VaultSecret { VaultSecret(id: id, name: name, kind: .opaque) }
        let rows = [secret("1", "Github"), secret("2", "zed"), secret("3", "github"), secret("4", "Alpha"), secret("5", "GITHUB")]
        XCTAssertEqual(rows.sortedByName().map(\.id), ["4", "1", "3", "5", "2"])
    }

    func testTheSortKeyHasNoWeightForControlsOrMarks() {
        XCTAssertEqual(VaultNameOrder.sortKey("a\u{1}b"), VaultNameOrder.sortKey("ab"))
        XCTAssertEqual(VaultNameOrder.sortKey("e\u{301}"), VaultNameOrder.sortKey("e"))
    }
}

private extension Array {
    /// A fixed permutation, so the test needs no random numbers.
    func shuffledDeterministically() -> [Element] {
        var out = self
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for index in stride(from: out.count - 1, to: 0, by: -1) {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            out.swapAt(index, Int((seed >> 33) % UInt64(index + 1)))
        }
        return out
    }
}
