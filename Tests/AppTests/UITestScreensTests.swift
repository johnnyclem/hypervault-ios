import HyperVaultKit
import XCTest
@testable import HyperVault

/// What the screens behind the You tab are given by the canned server of the UI-test mode (App/Core/UITestWorld+Screens.swift),
/// read through the Kit's own endpoints, the way the app reads them. A route that drifts from the shape its screen decodes
/// fails here in seconds, instead of as a screen that shows its error state in a journey.
final class UITestScreensTests: XCTestCase {
    private func transport(_ scenario: UITestScenario = .signedIn) -> MockTransport {
        MockTransport(routes: UITestWorld.routes(for: scenario))
    }

    private func client(_ transport: MockTransport) -> HVClient {
        HVClient(baseURL: UITestWorld.appURL, transport: transport, tokens: StaticTokenProvider(), retry: .none)
    }

    private func rest(_ transport: MockTransport) -> AccountRest {
        let tables = HVClient(baseURL: UITestWorld.supabaseURL, transport: transport, tokens: StaticTokenProvider(), retry: .none)
        return AccountRest(client: tables, anonKey: UITestWorld.anonKey)
    }

    // MARK: Agent keys

    func testKeysAreListedMadeOnceAndRevoked() async throws {
        let net = transport()
        let api = client(net), tables = rest(net)
        let userID = UITestWorld.user.id

        let keys = try await AgentKeyDirectory.keys(rest: tables, userID: userID)
        XCTAssertEqual(keys.map(\.id), ["k1", "k2", "k3"])
        let slugs = await AgentKeyDirectory.challengeSlugs(rest: tables, userID: userID, keys: keys)
        XCTAssertEqual(slugs["k1"], "agent-setup-1", "Claude Code has a challenge page to open.")
        XCTAssertNil(slugs["k3"], "The default key has no challenge page.")

        let made = try await api.send(.createAgentKey(name: "Cursor"))
        XCTAssertTrue(AgentKeyRules.looksLikeKey(made.key), "A key is hv_ and 32 characters.")
        XCTAssertEqual(made.prefix, "hv_Qm7TnB41")
        XCTAssertEqual(made.challenge?.slug, "agent-setup-k4")
        let afterMaking = try await AgentKeyDirectory.keys(rest: tables, userID: userID)
        XCTAssertEqual(afterMaking.map(\.id), ["k4", "k1", "k2", "k3"], "The new key is first.")
        XCTAssertEqual(afterMaking.first?.displayName, "Cursor")

        let revoked = try await api.send(.revokeAgentKey(id: "k3"))
        XCTAssertEqual(revoked.revoked, "k3")
        let afterRevoking = try await AgentKeyDirectory.keys(rest: tables, userID: userID)
        XCTAssertEqual(afterRevoking.map(\.id), ["k4", "k1", "k2"])
        do {
            _ = try await api.send(.revokeAgentKey(id: "k3"))
            XCTFail("A key that is gone cannot be revoked again.")
        } catch let error as HVError {
            XCTAssertEqual(error.status, 404)
        }

        // Another launch starts as the first one did.
        let again = try await AgentKeyDirectory.keys(rest: rest(transport()), userID: userID)
        XCTAssertEqual(again.map(\.id), ["k1", "k2", "k3"])
    }

    func testTheConnectStepsComeFromTheRegistryPage() async throws {
        let steps = try await client(transport()).send(.connectDocument(clientID: "cursor"))
        XCTAssertTrue(steps.contains("### Cursor"))
        XCTAssertTrue(ConnectGuide.parse(steps).isEmpty == false)
    }

    func testTheVaultListsEntriesAndWhichKeysMayReadThem() async throws {
        let api = client(transport())
        let secrets = try await api.send(.vaultSecrets)
        XCTAssertEqual(secrets.secrets.map(\.name), ["github.com", "visa-4242", "amex-0005", "contact", "home", "stripe-restricted-key"])
    }

    // MARK: The Library's graph

    /// What the Library journey stands on: the canned pages have row ids and sit unlinked, the memories are linked.
    func testTheLibraryGraphDrawsPagesBesideLinkedMemoriesAndHidesWhatHasNoLinks() async throws {
        let net = transport()
        let read = try await LibraryGraphRow.pages(rest: rest(net), userID: UITestWorld.user.id)
        XCTAssertEqual(read.pages.map(\.id), ["art-bakery", "art-lisbon"])
        XCTAssertEqual(read.pages.map(\.type), ["html", "html"])
        let api = client(net)
        let connections = try await api.send(.libraryConnections)
        let memories = try await api.send(.memoryList()).memories

        func build(hideUnlinked: Bool, hidden: Set<String> = []) -> LibraryGraph {
            LibraryGraphBuilder.build(
                pages: read.pages, memories: memories, pageLinks: connections.pageLinks, memoryLinks: connections.memoryLinks,
                bridges: connections.bridges, hiddenTypes: hidden, hideUnlinked: hideUnlinked
            )
        }
        let everything = build(hideUnlinked: false)
        XCTAssertEqual(everything.types.map(\.name), ["html", "memory"], "the chips the journey taps")
        XCTAssertTrue(everything.nodes.contains { $0.title == "Bakery landing page" && $0.kind == .page })
        XCTAssertTrue(everything.nodes.contains { $0.title == "Passport checklist" && $0.kind == .memory })

        let linked = build(hideUnlinked: true)
        XCTAssertFalse(linked.nodes.contains { $0.kind == .page }, "no page here has a link, so none stays")
        XCTAssertTrue(linked.nodes.contains { $0.title == "Passport checklist" }, "the memories are linked to each other")
        XCTAssertTrue(build(hideUnlinked: true, hidden: ["memory"]).nodes.isEmpty, "nothing left has a link: the journey's empty state")
    }

    // MARK: Your address

    func testYourAddressHasAPlanTwoClaimsAndPagesToOpenTo() async throws {
        let net = transport()
        let snapshot = try await RealmDirectory.snapshot(rest: rest(net), userID: UITestWorld.user.id)
        XCTAssertTrue(snapshot.isPro)
        XCTAssertEqual(snapshot.claims.map(\.id), ["c1", "c2"])
        XCTAssertEqual(snapshot.claims.first?.host, "nova.vault.cool")
        XCTAssertEqual(snapshot.claims.first?.theme, "glassmorphism")
        XCTAssertEqual(snapshot.claims.first?.defaultArtifactSlug, "bakery-landing-page-x1")
        XCTAssertEqual(snapshot.homeOptions.map(\.slug), ["bakery-landing-page-x1", "trip-to-lisbon-q7"])

        let caps = try await client(net).send(.capabilities)
        XCTAssertEqual(caps.domains.filter(\.available).count, 3)
        XCTAssertTrue(caps.themes.contains { $0.id == "glassmorphism" })
    }

    func testTheWebsiteWearsAThemeAndTakesAnother() async throws {
        let net = transport()
        let profiles = rest(net)
        let before = try await profiles.dashboardTheme(userID: UITestWorld.user.id)
        XCTAssertEqual(before, "glassmorphism")

        let saved = try await client(net).send(.setDashboardTheme("newsprint"))
        XCTAssertEqual(saved.theme, "newsprint")
        let after = try await profiles.dashboardTheme(userID: UITestWorld.user.id)
        XCTAssertEqual(after, "newsprint", "the profile holds what the server agreed to")
        let plan = try await profiles.profile(userID: UITestWorld.user.id)
        XCTAssertEqual(plan?.isPro, true, "the plan is still read from the same row")

        let stock = try await client(net).send(.setDashboardTheme(nil))
        XCTAssertNil(stock.theme)
        let none = try await profiles.dashboardTheme(userID: UITestWorld.user.id)
        XCTAssertNil(none)
    }

    func testAnUnknownThemeIsRefusedWithTheServersSentence() async {
        do {
            _ = try await client(transport()).send(.setDashboardTheme("not-a-theme"))
            XCTFail("The canned server refuses a theme it does not list.")
        } catch {
            XCTAssertEqual((error as? HVError)?.failure?.status, 400)
        }
    }

    // MARK: Rooms and chat

    func testARoomTakesAMessageAndAnswersIt() async throws {
        let net = transport()
        let api = client(net)
        let room = try await api.send(.room(id: "r1"))
        XCTAssertEqual(room.room.title, "Features X and Y")
        XCTAssertEqual(room.members.map(\.handle), ["grok", "claude"])
        XCTAssertEqual(room.messages.count, 3)
        XCTAssertTrue(room.room.pending.isEmpty)

        let run = try await api.send(.postRoomMessage(roomID: "r1", content: "claude, summarise the plan"))
        XCTAssertEqual(run.messages.map(\.senderKind), [.human, .agent])
        XCTAssertEqual(run.messages.last?.content, "Noted: claude, summarise the plan")
        XCTAssertTrue(run.pending.isEmpty)

        let later = try await api.send(.room(id: "r1", after: 2))
        XCTAssertEqual(later.messages.count, 5, "What was said stays in the room.")
        let idle = try await api.send(.runRoom(id: "r1"))
        XCTAssertTrue(idle.messages.isEmpty)
    }

    func testAMemoryIsAskedAboutAndAConversationIsAnswered() async throws {
        let api = client(transport())
        let answer = try await api.send(.memoryAsk(backendId: "b1", message: "What did I plan for the ferry?"))
        XCTAssertEqual(answer.text, UITestWorld.askAnswer)
        XCTAssertEqual(answer.recalled, [UITestWorld.askSource])

        let recall = try await api.send(.memoryRecall("ferry"))
        XCTAssertEqual(recall.results.map(\.title), ["Trip to Lisbon: ferry and passports", "Passport checklist"])

        let page = try await api.send(.memoryPage(id: "m1"))
        XCTAssertEqual(page.memory.title, "Trip to Lisbon: ferry and passports")
        XCTAssertEqual(page.related.map(\.title), ["Passport checklist"])
        XCTAssertEqual(page.artifacts.map(\.title), ["Lisbon trip plan"])

        // A chat turn sends the conversation's switches, and gets a plain reply.
        let turn = try await api.send(.chat(backendID: "b1", message: "Add a fado night", conversationID: "c1", options: ChatSendOptions(smartContext: true)))
        XCTAssertEqual(turn.reply.content, "Noted: Add a fado night")
        XCTAssertEqual(turn.conversationID, "c1")
        XCTAssertTrue(turn.recalledMemories.isEmpty)

        let detail = try await api.send(.conversation(id: "c1"))
        XCTAssertEqual(detail.conversation.title, "Three days in Lisbon")
        XCTAssertEqual(detail.messages.count, 6)
    }

    // MARK: Think

    func testTruthHasALedgerAnEntryWithAnAncestryAndADocket() async throws {
        let api = client(transport())
        let ledgers = try await api.send(.truthLedgers)
        XCTAssertEqual(ledgers.ledgers.count, 2)
        let overview = try await api.send(.truth(ledger: "team"))
        XCTAssertEqual(overview.citable.count, 2)
        XCTAssertEqual(overview.review?.due, true)

        let derivation = try await api.send(.truthDerivation(id: "01M1E6JK8SQAJ8K0JBRHTD10YG", ledger: "team"))
        XCTAssertEqual(derivation.dependents.count, 1)
        let docket = try await api.send(.truthReview(ledger: "team"))
        XCTAssertTrue(String(describing: docket.docket).contains("Retries are idempotent across regions."))
    }

    func testDreamsAndDigestHaveSomethingToReview() async throws {
        let api = client(transport())
        let dreams = try await api.send(.dreamQueue)
        XCTAssertTrue(dreams.dreamingEnabled)
        XCTAssertEqual(dreams.runs.first?.connections.count, 4)
        let digest = try await api.send(.digestQueue)
        XCTAssertEqual(digest.runs.first?.segments.count, 3)
    }

    func testTaskBoardsAreListedAndOneHasTasks() async throws {
        let api = client(transport())
        let index = try await api.send(.taskBoards)
        XCTAssertEqual(index.boards.map(\.project), ["eurorack-choir", "garden"])
        let fetch = try await api.send(.taskBoard(project: "eurorack-choir"))
        XCTAssertEqual(fetch.board?.title, "Eurorack Choir Module")
        XCTAssertEqual(fetch.board?.tasks.count, 7)
        let summary = try await api.send(.taskBoardSummary(project: "garden"))
        XCTAssertEqual(summary.summary.total, 4)
    }

    // MARK: Agents

    func testToolsAndMailHaveThingsToShow() async throws {
        let api = client(transport())
        let servers = try await api.send(.mcpServers)
        XCTAssertEqual(servers.servers.map(\.name), ["Linear", "Team notes", "Weather"])

        let boxes = try await api.send(.mailMailboxes)
        XCTAssertEqual(boxes.mailboxes.first?.address, "ana@vault.cool")
        let inbox = try await api.send(.mailMessages())
        XCTAssertEqual(inbox.messages.count, 4)
        let thread = try await api.send(.mailThread(threadId: "11111111-1111-4111-8111-111111111111"))
        XCTAssertEqual(thread.messages.count, 3)
        XCTAssertEqual(thread.messages.last?.text, "Done. Friday it is, and I updated the page.")
    }

    // MARK: Import, sharing and history

    func testAPastedConversationIsImportedAndAPageHasSharesAndHistory() async throws {
        let api = client(transport())
        let outcome = try await api.send(.importHistory(ImportRequest(data: "User: hi\nAssistant: hello", platform: nil, title: nil)))
        XCTAssertEqual(outcome.imported, 1)
        XCTAssertEqual(outcome.messages, 2)
        var totals = ImportTotals()
        totals.add(outcome)
        XCTAssertEqual(totals.summary(platform: .other, locale: Locale(identifier: "en_US")), "Imported 1 conversation (2 messages). Open Chat to continue them on any backend.")

        let shares = try await api.send(.artifactShares(slug: "bakery-landing-page-x1"))
        XCTAssertEqual(shares.people.map(\.name), ["maya@example.com"])
        let history = try await api.send(.artifactVersions(slug: "bakery-landing-page-x1"))
        XCTAssertEqual(history.versions.map(\.id), ["v3", "v2", "v1"])
        XCTAssertEqual(history.versions.first?.isHead, true)
        XCTAssertEqual(history.versions.first?.summary, "Open at seven on weekdays")
    }

    // MARK: Admin

    func testOnlyAnAdminPassesTheAdminCheckAndMintsCodes() async throws {
        // The check the You tab makes: a 403 says no, a 400 (the empty body refused) says yes.
        for (scenario, expected) in [(UITestScenario.signedIn, AdminProbe.Verdict.notAdmin), (.signedInEmpty, .notAdmin), (.signedInAdmin, .admin)] {
            let api = client(transport(scenario))
            var verdict = AdminProbe.Verdict.unknown
            do {
                _ = try await api.send(.adminProbe)
                verdict = .admin
            } catch let error as HVError {
                verdict = AdminProbe.verdict(status: error.status)
            }
            XCTAssertEqual(verdict, expected, "\(scenario)")
        }

        let api = client(transport(.signedInAdmin))
        let minted = try await api.send(.createInvite(maxUses: 5, note: "Launch batch")).invite
        XCTAssertEqual(minted.code, "HV-UIT1-K7QM")
        XCTAssertEqual(minted.id, "3f1c1a2e-0000-4000-8000-000000000001")
        XCTAssertEqual(minted.maxUses, 5)
        XCTAssertEqual(minted.note, "Launch batch")
        XCTAssertEqual(minted.status, .active)
        let off = try await api.send(.setInvite(id: minted.id, disabled: true)).invite
        XCTAssertEqual(off.status, .disabled)
        _ = try await api.send(.deleteInvite(id: minted.id))
        do {
            _ = try await api.send(.setInvite(id: minted.id, disabled: false))
            XCTFail("A destroyed code is gone.")
        } catch let error as HVError {
            XCTAssertEqual(error.status, 404)
        }
    }
}
