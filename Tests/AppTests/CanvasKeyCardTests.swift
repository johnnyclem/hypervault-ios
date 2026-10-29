import HyperVaultKit
import XCTest
@testable import HyperVault

/// Open on a key card of the Home canvas: which cards have an entry page to open, how the entry is found in the vault
/// (by the card's row id, then by its title), what the sheet has to say while the vault is read and when it cannot be, that an
/// entry which is not there falls back to the Vault's list without a word, and that the card reads its key again after the page
/// changed it. The canned world's key card has its entry only when a launch asks for it.
@MainActor
final class CanvasKeyCardTests: CanvasTestCase {
    private func keyCard(id: String = "k1", name: String = "OPENAI_API_KEY") -> CanvasCard {
        CanvasState.itemCard(KeptItem(id: id, kind: .key, name: name, href: "/vault/account"))
    }

    /// A target as `CanvasKeyCard.target(for:env:)` makes it, on a vault of the world's own (`VaultWorld` has the previews' six
    /// entries: s1 github.com ... s6 stripe-restricted-key).
    private func target(_ card: CanvasCard, in world: VaultWorld) -> CanvasKeyTarget {
        CanvasKeyTarget(id: card.key, entryID: card.ref?.id, name: card.title, entries: world.list())
    }

    private func entryFound(_ target: CanvasKeyTarget, file: StaticString = #filePath, line: UInt = #line) -> VaultSecret? {
        guard case .found(let entry) = target.outcome else {
            XCTFail("expected the entry to be found, got \(target.outcome)", file: file, line: line)
            return nil
        }
        return entry
    }

    // MARK: Which cards have a page

    func testAKeyCardHasAnEntryByItsRowAndItsTitle() throws {
        let found = try XCTUnwrap(CanvasKeyCard.target(for: keyCard(), env: AppEnvironment.preview()))
        XCTAssertEqual(found.id, "key:k1", "the sheet is driven by the card's key")
        XCTAssertEqual(found.entryID, "k1")
        XCTAssertEqual(found.name, "OPENAI_API_KEY")
    }

    func testEveryOtherKindOfCardHasNone() {
        for kind in [KeptKind.page, .file, .group, .memory] {
            let card = CanvasState.itemCard(KeptItem(id: "x1", kind: kind, name: "A thing", href: "/a/a-thing-1"))
            XCTAssertNil(CanvasKeyCard.target(for: card, env: AppEnvironment.preview()), "a \(kind.singular.lowercased()) card has no entry page")
        }
    }

    func testACardWithNoRowIsFoundByItsTitleAlone() throws {
        let card = CanvasCard(key: "key:odd", kind: .key, title: "github.com", href: "")
        XCTAssertNil(card.ref)
        let found = try XCTUnwrap(CanvasKeyCard.target(for: card, env: AppEnvironment.preview()))
        XCTAssertNil(found.entryID)
        XCTAssertEqual(found.name, "github.com")
    }

    func testTheSheetReadsTheVaultThroughTheEnvironmentItWasGiven() async throws {
        let env = AppEnvironment.preview(routes: VaultPreviewData.routes)
        let made = try XCTUnwrap(CanvasKeyCard.target(for: keyCard(id: "s2", name: "visa-4242"), env: env))
        XCTAssertEqual(made.outcome, .loading, "nothing is read until the sheet asks")

        await made.entries.load()

        XCTAssertEqual(entryFound(made)?.name, "visa-4242")
    }

    // MARK: Finding the entry

    func testTheEntryIsFoundByTheRowTheCardStandsFor() async {
        let key = target(keyCard(id: "s1", name: "github.com"), in: VaultWorld())
        XCTAssertEqual(key.outcome, .loading)

        await key.entries.load()

        XCTAssertEqual(entryFound(key)?.id, "s1")
    }

    func testAnEntryRenamedElsewhereIsStillFoundByItsRow() async {
        let key = target(keyCard(id: "s2", name: "the-old-name"), in: VaultWorld())
        await key.entries.load()

        XCTAssertEqual(entryFound(key)?.name, "visa-4242", "the title is what the card had, the row is what it stands for")
    }

    func testTheRowDecidesWhenItAndTheTitleNameDifferentEntries() async {
        let key = target(keyCard(id: "s2", name: "github.com"), in: VaultWorld())
        await key.entries.load()

        XCTAssertEqual(entryFound(key)?.id, "s2")
    }

    func testAnEntryWhoseRowIsNotThereIsFoundByTheTitle() async {
        let key = target(keyCard(id: "made-again", name: "github.com"), in: VaultWorld())
        await key.entries.load()

        XCTAssertEqual(entryFound(key)?.id, "s1", "deleted and saved again under the same name: the row is new, the name is the one asked for")
    }

    // MARK: When it is not there

    func testAnEntryThatIsNotInTheVaultIsGoneAndNothingIsSaidAboutIt() async {
        let key = target(keyCard(id: "k1", name: "OPENAI_API_KEY"), in: VaultWorld())
        await key.entries.load()

        XCTAssertEqual(key.outcome, .gone)
        XCTAssertEqual(key.entries.phase, .loaded, "the read worked: there is no error to show")
        XCTAssertNil(key.entries.refreshError)
    }

    func testAnEntryThatIsGoneGoesWhereOpenAlwaysWentToBefore() {
        XCTAssertEqual(CanvasKeyCard.fallback, DeepLink.account(.vault))

        let router = AppRouter(youIsStack: true)
        router.open(CanvasKeyCard.fallback)

        XCTAssertEqual(router.tab, .you)
        XCTAssertEqual(router.accountPane, .vault)
    }

    // MARK: When the vault cannot be read

    func testAVaultThatCannotBeReadSaysSoAndIsReadAgainOnRequest() async {
        let reads = Sequenced([
            Sequenced.error("The database is busy.", status: 500),
            Sequenced.json(VaultPreviewData.secretsJSON),
        ])
        let key = target(keyCard(id: "s1", name: "github.com"), in: VaultWorld(extra: [reads.route(.get, "/api/secrets")]))

        await key.entries.load()
        XCTAssertEqual(key.outcome, .failed("The database is busy."), "not gone: the entry may well be there")

        await key.entries.load()
        XCTAssertEqual(entryFound(key)?.name, "github.com")
    }

    // MARK: The card, after the page changed the key

    private let agentsBefore = #""agents":[{"id":"ag1","name":"Claude Code","key_prefix":"hv_Zk3pQ9vL"}]"#
    private let agentsAfter = #""agents":[{"id":"ag1","name":"Claude Code","key_prefix":"hv_Zk3pQ9vL"},{"id":"ag2","name":"Cursor","key_prefix":"hv_Aa1Bb2Cc"}]"#

    func testTheCardReadsItsKeyAgainAndSaysWhoMayUseItNow() async throws {
        let said = LibraryTestBox<String>(#"{"id":"k1","kind":"key","name":"OPENAI_API_KEY","href":"/vault/account",\#(agentsBefore)}"#)
        let headers: [String: String] = ["content-type": "application/json"]
        let (model, transport) = make([
            MockRoute(.get, "/api/yours/card") { _ in HTTPResponse(status: 200, headers: headers, data: Data(said.value.utf8)) },
            .json(.post, "/api/yours/open", #"{"persisted":true}"#),
        ])
        model.pullItem(KeptItem(id: "k1", kind: .key, name: "OPENAI_API_KEY", href: "/vault/account"))
        let filled = await eventually { model.cards.first?.detail?.agents.count == 1 }
        XCTAssertTrue(filled)

        // The page allowed Cursor and the entry was renamed there.
        said.value = #"{"id":"k1","kind":"key","name":"OPENAI_API_KEY (work)","href":"/vault/account",\#(agentsAfter)}"#
        model.refreshCard(key: "key:k1")

        let refreshed = await eventually { model.cards.first?.detail?.agents.count == 2 }
        XCTAssertTrue(refreshed)
        XCTAssertEqual(model.cards.count, 1, "the card is the same card")
        XCTAssertEqual(model.cards.first?.key, "key:k1")
        XCTAssertEqual(model.cards.first?.title, "OPENAI_API_KEY (work)")
        XCTAssertEqual(model.cards.first?.detail?.agents.map(\.name), ["Claude Code", "Cursor"])
        let asked = await transport.requests(matching: "/api/yours/card")
        XCTAssertEqual(asked.count, 2)
        XCTAssertEqual(asked.last?.url?.query?.contains("id=k1"), true)
    }

    func testAKeyThatIsNotOnThePageIsNotReadAtAll() async {
        let (model, transport) = make([.json(.get, "/api/yours/card", memory)])

        model.refreshCard(key: "key:k1")

        let asked = await transport.requests(matching: "/api/yours/card")
        XCTAssertTrue(asked.isEmpty)
    }

    // MARK: The canned world

    private func vaultNames(_ routes: [MockRoute]) async throws -> [String] {
        let transport = MockTransport(routes: routes)
        let api = HVClient(baseURL: UITestWorld.appURL, transport: transport, tokens: StaticTokenProvider(), retry: .none)
        return try await api.send(.vaultSecrets).secrets.map(\.name)
    }

    func testTheCannedVaultDoesNotListTheKeyCardsEntryUnlessTheLaunchAsksForIt() async throws {
        let six = ["github.com", "visa-4242", "amex-0005", "contact", "home", "stripe-restricted-key"]
        let plain = try await vaultNames(UITestWorld.writeRoutes(keyCardEntry: false))
        XCTAssertEqual(plain, six, "the vault the other journeys and tests count")

        let asked = try await vaultNames(UITestWorld.writeRoutes(keyCardEntry: true))
        XCTAssertEqual(asked, six + ["OPENAI_API_KEY"])
    }

    func testTheCannedKeyCardIsGoneFromTheVaultUntilTheLaunchGivesItsEntryBack() async throws {
        let yours = try XCTUnwrap(UITestWorld.things.first { $0.kind == "key" })
        let card = CanvasState.itemCard(KeptItem(id: yours.id, kind: .key, name: yours.name, href: yours.href))

        for (keyCardEntry, found) in [(false, false), (true, true)] {
            let env = AppEnvironment.preview(routes: UITestWorld.writeRoutes(keyCardEntry: keyCardEntry) + VaultPreviewData.routes)
            let made = try XCTUnwrap(CanvasKeyCard.target(for: card, env: env))
            await made.entries.load()
            if found {
                XCTAssertEqual(entryFound(made)?.id, "k1", "the entry has the id Yours gives the card")
            } else {
                XCTAssertEqual(made.outcome, .gone, "the key card of the plain canned world falls back to the Vault's list")
            }
        }
    }

    func testTheKeyCardsEntryStartsWithTheClaudeCodeKeyAllowed() async throws {
        let transport = MockTransport(routes: UITestWorld.writeRoutes(keyCardEntry: true) + VaultPreviewData.routes)
        let api = HVClient(baseURL: UITestWorld.appURL, transport: transport, tokens: StaticTokenProvider(), retry: .none)

        let grants = try await api.send(.secretGrants(name: "OPENAI_API_KEY")).grants
        XCTAssertEqual(grants.map(\.apiKeyId), ["k1"])
    }
}
