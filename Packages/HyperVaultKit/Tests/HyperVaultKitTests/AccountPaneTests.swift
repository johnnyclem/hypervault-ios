import XCTest
@testable import HyperVaultKit

/// `resolveAccountTab` and the pane list, ported from components/settings/account-tabs.ts and its test, plus
/// the rules of handoff section 7 (the hash only counts when `?tab=` names no pane; a repeated `?tab=` names
/// nothing).
final class AccountPaneTests: XCTestCase {
    private let ids = ["general", "vault", "keys", "backends", "domain", "appearance", "import"]

    func testThereAreSevenPanesInTheWebsOrder() {
        XCTAssertEqual(AccountPane.allCases.map(\.rawValue), ids)
        XCTAssertEqual(AccountPane.allCases.map(\.id), ids)
        XCTAssertEqual(
            AccountPane.allCases.map(\.label),
            ["General", "Vault", "Agent keys", "Models", "Domain", "Appearance", "Import"]
        )
    }

    func testTheDefaultIsTheVault() {
        XCTAssertEqual(AccountPane.default, .vault)
        XCTAssertEqual(AccountPane.resolve(queryItems: [], fragment: nil), .vault)
    }

    func testAgentKeysIsNeverRewordedOnItsOwn() {
        XCTAssertEqual(AccountPane.keys.label, "Agent keys")
    }

    func testSymbolsAreThoseOfHandoffSection2_7() {
        XCTAssertEqual(
            AccountPane.allCases.map(\.symbol),
            ["gearshape", "lock", "key", "sparkles", "globe", "paintpalette", "square.and.arrow.down"]
        )
    }

    // MARK: resolve(_:)

    func testEveryIdNamesItsPaneWithAndWithoutAHash() {
        for pane in AccountPane.allCases {
            XCTAssertEqual(AccountPane.resolve(pane.rawValue), pane, pane.rawValue)
            XCTAssertEqual(AccountPane.resolve("#" + pane.rawValue), pane, pane.rawValue)
        }
    }

    func testTheOldSectionIdsAreAliases() {
        XCTAssertEqual(AccountPane.resolve("secrets"), .vault)
        XCTAssertEqual(AccountPane.resolve("reference"), .keys)
        XCTAssertEqual(AccountPane.resolve("theme"), .appearance)
        XCTAssertEqual(AccountPane.resolve("import-file"), .import)
        XCTAssertEqual(AccountPane.resolve("#secrets"), .vault)
        XCTAssertEqual(AccountPane.resolve("#reference"), .keys)
        XCTAssertEqual(AccountPane.resolve("#theme"), .appearance)
        XCTAssertEqual(AccountPane.resolve("#import-file"), .import)
        XCTAssertEqual(AccountPane.aliases.map(\.name), ["secrets", "reference", "theme", "import-file"])
    }

    func testWhatNamesNothing() {
        // The web's own list: "Vault" is not "vault", and "toString" and "constructor" are inherited names a
        // plain object lookup would wrongly find.
        for raw in ["", "#", "##keys", "bogus", "Vault", "KEYS", "toString", "constructor", "__proto__", "keys keys", "key", "keys/"] {
            XCTAssertNil(AccountPane.resolve(raw), raw)
        }
        XCTAssertNil(AccountPane.resolve(nil as String?))
    }

    func testOnlyOneLeadingHashIsDropped() {
        XCTAssertNil(AccountPane.resolve("##keys"))
        XCTAssertNil(AccountPane.resolve("###"))
        XCTAssertEqual(AccountPane.resolve("#keys"), .keys)
    }

    func testItTrimsWithJavaScriptWhiteSpace() {
        XCTAssertEqual(AccountPane.resolve(" keys "), .keys)
        XCTAssertEqual(AccountPane.resolve("# keys"), .keys)
        XCTAssertEqual(AccountPane.resolve("#keys\n"), .keys)
        XCTAssertEqual(AccountPane.resolve("\u{FEFF}keys"), .keys)
        XCTAssertEqual(AccountPane.resolve("\u{00A0}keys\u{3000}"), .keys)
        // U+0085 is white space to Foundation and not to JavaScript's trim().
        XCTAssertNil(AccountPane.resolve("\u{85}keys"))
        // The hash comes off before the trim, so white space in front of it keeps it.
        XCTAssertNil(AccountPane.resolve(" #keys"))
    }

    func testTheMatchIsOfBytesNotOfCanonicalEquivalents() {
        XCTAssertNil(AccountPane.resolve("keys\u{301}"))
        XCTAssertNil(AccountPane.resolve("\u{212A}eys"))  // KELVIN SIGN, canonically a capital K
    }

    // MARK: resolve(queryItems:fragment:)

    private func resolve(_ query: [(String, String?)] = [], _ fragment: String? = nil) -> AccountPane {
        AccountPane.resolve(queryItems: query.map { URLQueryItem(name: $0.0, value: $0.1) }, fragment: fragment)
    }

    func testTheTabItemNamesThePane() {
        XCTAssertEqual(resolve([("tab", "keys")]), .keys)
        XCTAssertEqual(resolve([("tab", "secrets")]), .vault)
        XCTAssertEqual(resolve([("tab", "theme")]), .appearance)
        XCTAssertEqual(resolve([("other", "x"), ("tab", "domain")]), .domain)
    }

    func testTheHashCountsWhenNoTabNamesAPane() {
        XCTAssertEqual(resolve([], "keys"), .keys)
        XCTAssertEqual(resolve([], "secrets"), .vault)
        XCTAssertEqual(resolve([("tab", "bogus")], "keys"), .keys)
        XCTAssertEqual(resolve([("tab", "Vault")], "keys"), .keys)
        XCTAssertEqual(resolve([("tab", nil)], "import"), .import)
        XCTAssertEqual(resolve([("tab", "")], "domain"), .domain)
    }

    func testTheTabItemBeatsTheHash() {
        XCTAssertEqual(resolve([("tab", "general")], "keys"), .general)
    }

    func testARepeatedTabNamesNothing() {
        XCTAssertEqual(resolve([("tab", "keys"), ("tab", "vault")]), .vault)
        XCTAssertEqual(resolve([("tab", "keys"), ("tab", "domain")]), .vault)
        XCTAssertEqual(resolve([("tab", "keys"), ("tab", "keys")]), .vault)
        // It names nothing, so the hash decides.
        XCTAssertEqual(resolve([("tab", "keys"), ("tab", "domain")], "general"), .general)
    }

    func testAHashWithASecondHashNamesNothing() {
        // `/vault/account##keys`: location.hash is "##keys", and URLComponents' fragment is "#keys".
        XCTAssertEqual(resolve([], "#keys"), .vault)
        XCTAssertEqual(resolve([], ""), .vault)
        XCTAssertEqual(resolve([], "Vault"), .vault)
    }

    func testAnEncodedHashIsNotDecoded() {
        XCTAssertEqual(resolve([], "%6Beys"), .vault)
    }

    func testTheDefaultWhenNothingNamesAPane() {
        XCTAssertEqual(resolve([("tab", "bogus")], "nope"), .vault)
        XCTAssertEqual(resolve([("x", "keys")], nil), .vault)
    }

    func testResolvingFromAFullLink() throws {
        func pane(_ link: String) throws -> AccountPane {
            let components = try XCTUnwrap(URLComponents(string: link))
            return AccountPane.resolve(
                queryItems: components.queryItems ?? [], fragment: components.percentEncodedFragment
            )
        }
        XCTAssertEqual(try pane("https://hypervault.store/vault/account"), .vault)
        XCTAssertEqual(try pane("https://hypervault.store/vault/account#keys"), .keys)
        XCTAssertEqual(try pane("https://hypervault.store/vault/account#secrets"), .vault)
        XCTAssertEqual(try pane("https://hypervault.store/vault/account?tab=keys"), .keys)
        XCTAssertEqual(try pane("https://hypervault.store/vault/account?tab=bogus#keys"), .keys)
        XCTAssertEqual(try pane("https://hypervault.store/vault/account?tab=general#keys"), .general)
        XCTAssertEqual(try pane("https://hypervault.store/vault/account?tab=keys&tab=general"), .vault)
        XCTAssertEqual(try pane("https://hypervault.store/vault/account?tab=Vault"), .vault)
        XCTAssertEqual(try pane("https://hypervault.store/vault/account?tab=%20keys%20"), .keys)
        XCTAssertEqual(try pane("https://hypervault.store/vault/account##keys"), .vault)
    }

    // MARK: Description lines

    func testDescriptionLinesAreTheBrandBooksVerbatim() {
        XCTAssertEqual(AccountPane.general.descriptionLine, "The account you are signed in with.")
        XCTAssertEqual(
            AccountPane.vault.descriptionLine,
            "Save a login, card or contact once. Agents you give a key, like Claude Code, Codex, Cursor, Gemini CLI or your own script, can use it, and only the ones you allow."
        )
        XCTAssertEqual(
            AccountPane.keys.descriptionLine,
            "One key per agent. A key is shown once, and comes with a setup challenge the agent completes to prove the link works."
        )
        XCTAssertEqual(
            AccountPane.domain.descriptionLine,
            "Every claimed address serves your whole vault. Visitors see the realm's look; you still get your dashboard."
        )
        XCTAssertEqual(
            AccountPane.appearance.descriptionLine,
            "One look for your dashboard and chat; each realm can wear its own, and open straight to an artifact you pick."
        )
        XCTAssertEqual(AccountPane.import.descriptionLine, "Bring what you made elsewhere into your vault.")
    }

    func testTheModelsLineIsLeftOutBecauseTheBrandBookOnlyQuotesItsStart() {
        XCTAssertNil(AccountPane.backends.descriptionLine)
    }

    func testNoPaneDescribesItselfAsConnectedBecauseOnlyTheServerKnows() {
        for pane in AccountPane.allCases {
            let line = pane.descriptionLine ?? ""
            XCTAssertFalse(line.localizedCaseInsensitiveContains("connected"), pane.rawValue)
        }
    }
}
