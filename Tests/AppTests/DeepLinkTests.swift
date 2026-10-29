import XCTest
import HyperVaultKit
import UIKit
@testable import HyperVault

final class DeepLinkTests: XCTestCase {
    private func link(_ text: String) -> DeepLink? { URL(string: text).flatMap(DeepLink.init(url:)) }

    func testCustomSchemeLinks() {
        XCTAssertEqual(link("hypervault://artifact/trip-notes-abc123"), .route(.artifact(slug: "trip-notes-abc123")))
        XCTAssertEqual(link("hypervault://memory/7f1c"), .route(.memory(id: "7f1c")))
        XCTAssertEqual(link("hypervault://tab/memory"), .tab(.memory))
        XCTAssertEqual(link("hypervault://keep?text=Call%20the%20dentist"), .keep(prefill: "Call the dentist"))
        XCTAssertEqual(link("hypervault://pair?code=ABCD-EFGH"), .pair(code: "ABCD-EFGH"))
    }

    func testWebLinks() {
        XCTAssertEqual(link("https://hypervault.store/a/trip-notes-abc123"), .route(.artifact(slug: "trip-notes-abc123")))
        XCTAssertEqual(link("https://sam.vault.cool/a/page-1"), .route(.artifact(slug: "page-1")))
        XCTAssertEqual(link("https://hypervault.store/vault/memory"), .tab(.memory))
        XCTAssertEqual(link("https://hypervault.store/vault/mail"), .route(.mail))
        XCTAssertEqual(link("https://hypervault.store/g/portfolio-site-x1"), .route(.artifact(slug: "portfolio-site-x1")))
        XCTAssertEqual(link("hypervault://mail/msg-42"), .route(.mailThread(id: "msg-42")))
        XCTAssertEqual(link("hypervault://truth/review"), .route(.truthReview))
        XCTAssertEqual(link("hypervault://taskboards"), .route(.taskBoards))
        XCTAssertEqual(link("https://hypervault.store/rooms/abc"), .route(.room(id: "abc")))
        XCTAssertEqual(link("https://hypervault.store/login?invite=HV-AB12-CD34"), .invite(code: "HV-AB12-CD34"))
    }

    func testUnknownLinksAreIgnored() {
        XCTAssertNil(link("hypervault://auth/callback?code=x"))
        XCTAssertNil(link("https://hypervault.store/"))
        XCTAssertNil(link("mailto:a@b.co"))
        XCTAssertNil(link("hypervault://tab"))
        XCTAssertNil(link("hypervault://tab/nowhere"))
        XCTAssertNil(link("https://hypervault.store/vault/nowhere"))
    }

    // MARK: Links that are already out there

    /// Installed widgets keep hypervault://tab/yours and tab/canvas in their timelines after the app updates, and Spotlight
    /// keeps hypervault://artifact and memory links: they open for good, whatever the tabs become.
    func testTheLinksWidgetsAndSpotlightAlreadyCarryKeepWorking() {
        XCTAssertEqual(link("hypervault://tab/yours"), .yours)
        XCTAssertEqual(link("hypervault://tab/canvas"), .tab(.canvas))
        XCTAssertEqual(link("hypervault://keep"), .keep(prefill: nil))
        XCTAssertEqual(link("hypervault://artifact/trip-notes"), .route(.artifact(slug: "trip-notes")))
        XCTAssertEqual(link("hypervault://memory/7f1c"), .route(.memory(id: "7f1c")))
        XCTAssertEqual(link("hypervault://tab/YOURS"), .yours)
        XCTAssertEqual(link("hypervault://tab/Canvas"), .tab(.canvas))

        // What each opens: the panel on Home, and Home.
        XCTAssertEqual(DeepLink.yours.destination.tab, .canvas)
        XCTAssertNil(DeepLink.yours.destination.route)
        XCTAssertEqual(DeepLink.tab(.canvas).destination.tab, .canvas)
    }

    func testEveryTabNamesItself() {
        XCTAssertEqual(link("hypervault://tab/home"), .tab(.canvas))
        XCTAssertEqual(link("hypervault://tab/chat"), .tab(.chat))
        XCTAssertEqual(link("hypervault://tab/memory"), .tab(.memory))
        XCTAssertEqual(link("hypervault://tab/you"), .tab(.you))
    }

    // MARK: The web's paths

    func testTheVaultIsHomeAndLibraryIsTheLibrary() {
        XCTAssertEqual(link("https://hypervault.store/vault"), .tab(.canvas))
        XCTAssertEqual(link("https://hypervault.store/vault/"), .tab(.canvas))
        XCTAssertEqual(link("hypervault://vault"), .tab(.canvas))
        XCTAssertEqual(link("https://hypervault.store/vault/library"), .route(.library))
        XCTAssertEqual(link("https://hypervault.store/vault/new"), .route(.library))
        XCTAssertEqual(link("https://hypervault.store/vault/groups"), .route(.library))
        XCTAssertEqual(link("hypervault://library"), .route(.library))
        XCTAssertEqual(link("https://hypervault.store/vault/dreams"), .route(.dreams))
        XCTAssertEqual(link("https://hypervault.store/vault/digest"), .route(.digest))
        XCTAssertEqual(link("https://hypervault.store/vault/truth"), .route(.truth))
        XCTAssertEqual(link("https://hypervault.store/vault/import"), .route(.importHistory))
    }

    func testTheYoursPanelAndGroupChatsAndAChatPinnedOnTheWeb() {
        XCTAssertEqual(link("hypervault://yours"), .yours)
        XCTAssertEqual(link("https://hypervault.store/yours"), .yours)
        XCTAssertEqual(link("https://hypervault.store/rooms"), .groupChats)
        XCTAssertEqual(link("hypervault://rooms"), .groupChats)
        XCTAssertEqual(link("https://hypervault.store/chat"), .tab(.chat))
        XCTAssertEqual(link("https://hypervault.store/chat?c=abc-123"), .route(.conversation(id: "abc-123")))
        XCTAssertEqual(link("https://hypervault.store/chat/abc-123"), .route(.conversation(id: "abc-123")))
        XCTAssertEqual(link("https://hypervault.store/chat?other=1"), .tab(.chat))
    }

    // MARK: The You page: /vault/account, ?tab= and the hash

    func testTheYouPageOpensTheVaultWhenNothingNamesAPane() {
        XCTAssertEqual(link("https://hypervault.store/vault/account"), .account(.vault))
        XCTAssertEqual(link("hypervault://vault/account"), .account(.vault))
        XCTAssertEqual(link("hypervault://account"), .account(.vault))
    }

    func testTheTabQueryNamesThePane() {
        for pane in AccountPane.allCases {
            XCTAssertEqual(link("https://hypervault.store/vault/account?tab=\(pane.rawValue)"), .account(pane), pane.rawValue)
        }
        XCTAssertEqual(link("https://hypervault.store/vault/account?tab=keys"), .account(.keys))
        XCTAssertEqual(link("hypervault://vault/account?tab=backends"), .account(.backends))
    }

    func testTheHashNamesThePaneAndTheLinksAlreadyOutThereWork() {
        // The agent docs' KEYS_PATH, and Yours' link to the vault.
        XCTAssertEqual(link("https://hypervault.store/vault/account#keys"), .account(.keys))
        XCTAssertEqual(link("https://hypervault.store/vault/account#secrets"), .account(.vault))
        XCTAssertEqual(link("https://hypervault.store/vault/account#reference"), .account(.keys))
        XCTAssertEqual(link("https://hypervault.store/vault/account#theme"), .account(.appearance))
        XCTAssertEqual(link("https://hypervault.store/vault/account#import-file"), .account(.import))
        XCTAssertEqual(link("hypervault://vault/account#domain"), .account(.domain))
    }

    func testTheQueryBeatsTheHashAndANameThatIsNotAPaneLetsTheHashDecide() {
        XCTAssertEqual(link("https://hypervault.store/vault/account?tab=general#keys"), .account(.general))
        XCTAssertEqual(link("https://hypervault.store/vault/account?tab=bogus#keys"), .account(.keys))
        XCTAssertEqual(link("https://hypervault.store/vault/account?tab=#keys"), .account(.keys))
    }

    func testCaseAndRepeatedQueriesNameNothing() {
        // The match is case-sensitive, so "Vault" names no pane, and neither does a tab given twice.
        XCTAssertEqual(link("https://hypervault.store/vault/account?tab=Vault"), .account(.vault))
        XCTAssertEqual(link("https://hypervault.store/vault/account?tab=Keys#general"), .account(.general))
        XCTAssertEqual(link("https://hypervault.store/vault/account?tab=keys&tab=general"), .account(.vault))
        XCTAssertEqual(link("https://hypervault.store/vault/account?tab=keys&tab=general#import"), .account(.import))
        XCTAssertEqual(link("https://hypervault.store/vault/account##keys"), .account(.vault))
    }

    func testSettingsIsTheGeneralPane() {
        XCTAssertEqual(link("hypervault://settings"), .account(.general))
        XCTAssertEqual(link("https://hypervault.store/settings"), .account(.general))
    }

    // MARK: The web's query: ?open=, ?mode=, ?branch=, ?filter=, ?q=, ?ledger=

    /// A table of links and what each opens. A failure names the link that broke.
    private func assertLinks(_ table: [(String, DeepLink?)], file: StaticString = #filePath, line: UInt = #line) {
        for (text, expected) in table {
            XCTAssertEqual(link(text), expected, text, file: file, line: line)
        }
    }

    func testOpenNamesTheMemoryTheWebPutsInIt() {
        let uuid = "8b41d07a-2c93-4f55-a6e0-1d7c93b4e802"
        assertLinks([
            ("https://hypervault.store/vault/memory?open=7f1c", .route(.memory(id: "7f1c"))),
            ("https://hypervault.store/vault/memory?open=\(uuid)", .route(.memory(id: uuid))),
            ("hypervault://vault/memory?open=7f1c", .route(.memory(id: "7f1c"))),
            ("hypervault://memory?open=7f1c", .route(.memory(id: "7f1c"))),
            ("https://sam.vault.cool/vault/memory?open=7f1c", .route(.memory(id: "7f1c"))),
            // The path form is the id, and a query beside it changes nothing.
            ("hypervault://memory/7f1c?open=other&mode=graph", .route(.memory(id: "7f1c"))),
            // A memory opens as a memory: it wins over a mode, and the branch beside it is not used.
            ("https://hypervault.store/vault/memory?open=7f1c&mode=graph&branch=feature-x", .route(.memory(id: "7f1c"))),
        ])
    }

    func testAnOpenThatNamesNoMemoryIsIgnored() {
        assertLinks([
            ("https://hypervault.store/vault/memory?open=", .tab(.memory)),
            ("https://hypervault.store/vault/memory?open=%20%20", .tab(.memory)),
            ("https://hypervault.store/vault/memory?open=a%20b", .tab(.memory)),
            ("https://hypervault.store/vault/memory?open=a%2Fb", .tab(.memory)),
            ("https://hypervault.store/vault/memory?open=..%2F..%2Fadmin", .tab(.memory)),
            ("https://hypervault.store/vault/memory?open=..", .tab(.memory)),
            ("https://hypervault.store/vault/memory?open=a&open=b", .tab(.memory)),
            ("https://hypervault.store/vault/memory?open=%FF", .tab(.memory)),
            ("https://hypervault.store/vault/memory?open=\(String(repeating: "a", count: 129))", .tab(.memory)),
            // What is left of the link still counts.
            ("https://hypervault.store/vault/memory?open=a%2Fb&mode=graph", .memoryTab(mode: .graph, branch: nil)),
        ])
        XCTAssertEqual(link("https://hypervault.store/vault/memory?open=\(String(repeating: "a", count: 128))"), .route(.memory(id: String(repeating: "a", count: 128))))
    }

    func testModeNamesTheWayOfLookingAndDigestIsItsOwnScreen() {
        assertLinks([
            ("https://hypervault.store/vault/memory?mode=search", .memoryTab(mode: .search, branch: nil)),
            ("https://hypervault.store/vault/memory?mode=ask", .memoryTab(mode: .ask, branch: nil)),
            ("https://hypervault.store/vault/memory?mode=graph", .memoryTab(mode: .graph, branch: nil)),
            ("hypervault://vault/memory?mode=graph", .memoryTab(mode: .graph, branch: nil)),
            ("hypervault://memory?mode=ask", .memoryTab(mode: .ask, branch: nil)),
            ("https://hypervault.store/vault/memory?mode=digest", .route(.digest)),
            ("https://hypervault.store/vault/memory?mode=digest&branch=feature-x", .route(.digest)),
        ])
        XCTAssertEqual(DeepLink.route(.digest).destination.tab, .memory, "Digest opens on the Memory tab")
    }

    func testAModeThatIsNotOneOfThemIsIgnored() {
        assertLinks([
            ("https://hypervault.store/vault/memory?mode=", .tab(.memory)),
            ("https://hypervault.store/vault/memory?mode=bogus", .tab(.memory)),
            ("https://hypervault.store/vault/memory?mode=Graph", .tab(.memory)),
            ("https://hypervault.store/vault/memory?mode=graph&mode=ask", .tab(.memory)),
            ("https://hypervault.store/vault/memory?mode=%FF", .tab(.memory)),
            ("https://hypervault.store/vault/memory?mode=graph%20ask", .tab(.memory)),
            // The tab with a stranger's query is the tab.
            ("https://hypervault.store/vault/memory?other=1", .tab(.memory)),
            ("https://hypervault.store/vault/memory", .tab(.memory)),
            ("hypervault://memory", .tab(.memory)),
        ])
    }

    func testBranchNamesABranchOfTheMind() {
        assertLinks([
            ("https://hypervault.store/vault/memory?branch=feature-x", .memoryTab(mode: nil, branch: "feature-x")),
            ("https://hypervault.store/vault/memory?branch=main", .memoryTab(mode: nil, branch: "main")),
            ("https://hypervault.store/vault/memory?branch=exp/ideas_2", .memoryTab(mode: nil, branch: "exp/ideas_2")),
            ("https://hypervault.store/vault/memory?branch=exp%2Fideas_2", .memoryTab(mode: nil, branch: "exp/ideas_2")),
            ("hypervault://memory?branch=feature-x&mode=ask", .memoryTab(mode: .ask, branch: "feature-x")),
            ("https://hypervault.store/vault/memory?mode=graph&branch=feature-x", .memoryTab(mode: .graph, branch: "feature-x")),
            // The web trims a branch name.
            ("https://hypervault.store/vault/memory?branch=%20feature-x%20", .memoryTab(mode: nil, branch: "feature-x")),
        ])
    }

    func testABranchThatCannotBeOneIsIgnored() {
        let long = String(repeating: "a", count: 64)
        assertLinks([
            ("https://hypervault.store/vault/memory?branch=", .tab(.memory)),
            ("https://hypervault.store/vault/memory?branch=Feature", .tab(.memory)),
            ("https://hypervault.store/vault/memory?branch=-x", .tab(.memory)),
            ("https://hypervault.store/vault/memory?branch=a%20b", .tab(.memory)),
            ("https://hypervault.store/vault/memory?branch=a..b%00", .tab(.memory)),
            ("https://hypervault.store/vault/memory?branch=\(long)", .tab(.memory)),
            ("https://hypervault.store/vault/memory?branch=a&branch=b", .tab(.memory)),
            // A good mode beside a bad branch still counts.
            ("https://hypervault.store/vault/memory?mode=graph&branch=Feature", .memoryTab(mode: .graph, branch: nil)),
        ])
        XCTAssertEqual(link("https://hypervault.store/vault/memory?branch=\(String(long.dropLast()))"), .memoryTab(mode: nil, branch: String(long.dropLast())), "63 is the longest")
    }

    func testFilterAndQNameWhatTheLibraryShows() {
        assertLinks([
            ("https://hypervault.store/vault/library?filter=memory", .route(.libraryFiltered(filter: .memory, query: ""))),
            ("https://hypervault.store/vault/library?filter=key", .route(.libraryFiltered(filter: .key, query: ""))),
            ("https://hypervault.store/vault/library?filter=file", .route(.libraryFiltered(filter: .file, query: ""))),
            ("https://hypervault.store/vault/library?filter=all", .route(.library)),
            ("https://hypervault.store/vault/library?q=trip", .route(.libraryFiltered(filter: .all, query: "trip"))),
            ("https://hypervault.store/vault/library?filter=memory&q=trip", .route(.libraryFiltered(filter: .memory, query: "trip"))),
            ("hypervault://library?filter=key", .route(.libraryFiltered(filter: .key, query: ""))),
            ("hypervault://vault/library?filter=key&q=work", .route(.libraryFiltered(filter: .key, query: "work"))),
            // The web reads the filter in any case, and trims both.
            ("https://hypervault.store/vault/library?filter=Memory", .route(.libraryFiltered(filter: .memory, query: ""))),
            ("https://hypervault.store/vault/library?filter=%20KEY%20&q=%20work%20", .route(.libraryFiltered(filter: .key, query: "work"))),
        ])
    }

    func testTheSearchIsReadAsAWebFormWritesIt() {
        assertLinks([
            ("https://hypervault.store/vault/library?q=trip%20notes", .route(.libraryFiltered(filter: .all, query: "trip notes"))),
            ("https://hypervault.store/vault/library?q=trip+notes", .route(.libraryFiltered(filter: .all, query: "trip notes"))),
            ("https://hypervault.store/vault/library?q=c%2B%2B", .route(.libraryFiltered(filter: .all, query: "c++"))),
            ("https://hypervault.store/vault/library?q=caf%C3%A9", .route(.libraryFiltered(filter: .all, query: "caf\u{E9}"))),
            ("https://hypervault.store/vault/library?filter=memory&q=a%26b", .route(.libraryFiltered(filter: .memory, query: "a&b"))),
        ])
        // Cut at the web's 100 characters.
        let cut = link("https://hypervault.store/vault/library?q=\(String(repeating: "a", count: 120))")
        XCTAssertEqual(cut, .route(.libraryFiltered(filter: .all, query: String(repeating: "a", count: 100))))
    }

    func testAFilterOrSearchThatNamesNothingIsIgnored() {
        assertLinks([
            ("https://hypervault.store/vault/library?filter=", .route(.library)),
            ("https://hypervault.store/vault/library?filter=bogus", .route(.library)),
            ("https://hypervault.store/vault/library?filter=memories", .route(.library)),
            ("https://hypervault.store/vault/library?filter=memory&filter=key", .route(.library)),
            ("https://hypervault.store/vault/library?q=", .route(.library)),
            ("https://hypervault.store/vault/library?q=%20%20", .route(.library)),
            ("https://hypervault.store/vault/library?q=a&q=b", .route(.library)),
            ("https://hypervault.store/vault/library?q=%FF", .route(.library)),
            ("https://hypervault.store/vault/library?other=1", .route(.library)),
            // A filter the web does not know is All, as it is there, and the search still counts.
            ("https://hypervault.store/vault/library?filter=bogus&q=trip", .route(.libraryFiltered(filter: .all, query: "trip"))),
            // Files are the file manager, which the web does not search by a link.
            ("https://hypervault.store/vault/library?filter=file&q=trip", .route(.libraryFiltered(filter: .file, query: ""))),
            // Only /vault/library takes them.
            ("https://hypervault.store/vault/new?filter=key&q=work", .route(.library)),
            ("https://hypervault.store/vault/groups?filter=key", .route(.library)),
        ])
    }

    func testLedgerOpensTheReviewOnThatLedger() {
        assertLinks([
            ("https://hypervault.store/vault/truth/review?ledger=team", .route(.truthReviewLedger(slug: "team"))),
            ("https://hypervault.store/vault/truth/review?ledger=team_2-b", .route(.truthReviewLedger(slug: "team_2-b"))),
            ("hypervault://truth/review?ledger=team", .route(.truthReviewLedger(slug: "team"))),
            ("hypervault://vault/truth/review?ledger=team", .route(.truthReviewLedger(slug: "team"))),
            ("https://hypervault.store/vault/truth/review", .route(.truthReview)),
            ("hypervault://truth/review", .route(.truthReview)),
            // The ledger page itself takes no ledger in a link.
            ("https://hypervault.store/vault/truth?ledger=team", .route(.truth)),
            ("hypervault://truth?ledger=team", .route(.truth)),
        ])
        XCTAssertEqual(DeepLink.route(.truthReviewLedger(slug: "team")).destination.tab, .memory)
    }

    func testALedgerThatCannotBeOneIsIgnored() {
        let long = String(repeating: "a", count: 65)
        assertLinks([
            ("https://hypervault.store/vault/truth/review?ledger=", .route(.truthReview)),
            ("https://hypervault.store/vault/truth/review?ledger=Team", .route(.truthReview)),
            ("https://hypervault.store/vault/truth/review?ledger=_team", .route(.truthReview)),
            ("https://hypervault.store/vault/truth/review?ledger=a%20b", .route(.truthReview)),
            ("https://hypervault.store/vault/truth/review?ledger=..%2Fadmin", .route(.truthReview)),
            ("https://hypervault.store/vault/truth/review?ledger=team&ledger=other", .route(.truthReview)),
            ("https://hypervault.store/vault/truth/review?ledger=\(long)", .route(.truthReview)),
        ])
    }

    func testAGroupOpensByItsSlugAndNewIsTheLibrary() {
        assertLinks([
            ("https://hypervault.store/vault/groups/trip-planner-abc123", .route(.artifact(slug: "trip-planner-abc123"))),
            ("hypervault://vault/groups/trip-planner-abc123", .route(.artifact(slug: "trip-planner-abc123"))),
            ("https://hypervault.store/vault/groups", .route(.library)),
            ("https://hypervault.store/vault/groups/", .route(.library)),
            ("https://hypervault.store/vault/groups/new", .route(.library)),
        ])
    }

    func testTheDestinationsOfTheLinksTheQueryMakes() {
        let memory = DeepLink.memoryTab(mode: .graph, branch: "feature-x")
        XCTAssertEqual(memory.destination.tab, .memory)
        XCTAssertNil(memory.destination.route, "the tab, not a pushed screen")
        let library = Route.libraryFiltered(filter: .key, query: "work")
        XCTAssertEqual(DeepLink.route(library).destination.tab, .canvas)
        XCTAssertEqual(DeepLink.route(library).destination.route, library)
        let review = Route.truthReviewLedger(slug: "team")
        XCTAssertEqual(DeepLink.route(review).destination.route, review)
    }

    // MARK: Pairing

    func testAPairLinkLandsOnTheYouTabWithTheCodeKept() throws {
        let pair = try XCTUnwrap(link("https://hypervault.store/pair?user_code=BCDF-2346"))
        XCTAssertEqual(pair, .pair(code: "BCDF-2346"))
        XCTAssertEqual(pair.destination.tab, .you)
        XCTAssertNil(pair.destination.route)
        XCTAssertEqual(link("hypervault://pair"), .pair(code: nil))
    }

    // MARK: Where each lands

    func testDestinations() {
        // Home: pages, the Library, mail, task boards and Admin.
        XCTAssertEqual(DeepLink.route(.artifact(slug: "x")).destination.tab, .canvas)
        XCTAssertEqual(DeepLink.route(.library).destination.tab, .canvas)
        XCTAssertEqual(DeepLink.route(.mail).destination.tab, .canvas)
        XCTAssertEqual(DeepLink.route(.mailThread(id: "m")).destination.tab, .canvas)
        XCTAssertEqual(DeepLink.route(.taskBoards).destination.tab, .canvas)
        XCTAssertEqual(DeepLink.route(.taskBoard(slug: "s", project: "p", title: "t")).destination.tab, .canvas)
        XCTAssertEqual(DeepLink.route(.admin).destination.tab, .canvas)
        XCTAssertEqual(DeepLink.keep(prefill: nil).destination.tab, .canvas)
        XCTAssertEqual(DeepLink.invite(code: nil).destination.tab, .canvas)
        // Chat: conversations, rooms, Tools and the history import, and the group chats half.
        XCTAssertEqual(DeepLink.route(.room(id: "x")).destination.tab, .chat)
        XCTAssertEqual(DeepLink.route(.conversation(id: "x")).destination.tab, .chat)
        XCTAssertEqual(DeepLink.route(.tools).destination.tab, .chat)
        XCTAssertEqual(DeepLink.route(.importHistory).destination.tab, .chat)
        XCTAssertEqual(DeepLink.groupChats.destination.tab, .chat)
        // Memory: memories, Dreams, Digest and Truth.
        XCTAssertEqual(DeepLink.route(.memory(id: "x")).destination.tab, .memory)
        XCTAssertEqual(DeepLink.route(.dreams).destination.tab, .memory)
        XCTAssertEqual(DeepLink.route(.digest).destination.tab, .memory)
        XCTAssertEqual(DeepLink.route(.truth).destination.tab, .memory)
        XCTAssertEqual(DeepLink.route(.truthReview).destination.tab, .memory)
        // You: a pane, which is not a route.
        XCTAssertEqual(DeepLink.account(.keys).destination.tab, .you)
        XCTAssertEqual(DeepLink.account(nil).destination.tab, .you)
        XCTAssertNil(DeepLink.account(.keys).destination.route)
    }

    func testTheDestinationOfARouteIsTheRouteItself() {
        XCTAssertEqual(DeepLink.route(.truth).destination.route, .truth)
        XCTAssertEqual(DeepLink.route(.artifact(slug: "x")).destination.route, .artifact(slug: "x"))
        XCTAssertNil(DeepLink.tab(.chat).destination.route)
    }

    // MARK: The tabs

    func testTheDockIsHomeChatMemoryYouWithTheWebsSymbols() {
        XCTAssertEqual(AppTab.allCases, [.canvas, .chat, .memory, .you])
        XCTAssertEqual(AppTab.allCases.map(\.title), ["Home", "Chat", "Memory", "You"])
        XCTAssertEqual(AppTab.allCases.map(\.symbol), ["house", "bubble.left", "point.3.connected.trianglepath.dotted", "person.crop.circle"])
    }

    // MARK: What the router does with a link

    @MainActor
    func testAnAccountLinkBringsThePaneForwardFromItsFirstScreen() {
        let router = AppRouter(youIsStack: true)
        router.push(.artifact(slug: "x"), on: .you)
        router.open(.account(.keys))
        XCTAssertEqual(router.tab, .you)
        XCTAssertEqual(router.accountPane, .keys)
        XCTAssertEqual(router.path(for: .you).wrappedValue.count, 1, "the stack starts from the pane and nothing is pushed on it")

        router.open(.account(nil))
        XCTAssertEqual(router.accountPane, .vault, "no pane named is the vault")
    }

    @MainActor
    func testAStacksPathStartsWithThePane() {
        let router = AppRouter(youIsStack: true)
        XCTAssertEqual(router.path(for: .you).wrappedValue.count, 1, "a phone's stack opens on the vault")
        router.open(.account(.domain))
        XCTAssertEqual(router.accountPane, .domain)
        XCTAssertEqual(router.path(for: .you).wrappedValue.count, 1)
        router.reset()
        XCTAssertEqual(router.accountPane, .vault)
        XCTAssertEqual(router.path(for: .you).wrappedValue.count, 1)
    }

    @MainActor
    func testBesideTheListThePaneIsTheRootAndNotOnThePath() {
        let router = AppRouter(youIsStack: false)
        XCTAssertEqual(router.path(for: .you).wrappedValue.count, 0, "beside the list the pane is the root")
        router.push(.artifact(slug: "x"), on: .you)
        XCTAssertEqual(router.path(for: .you).wrappedValue.count, 1)
        router.open(.account(.domain))
        XCTAssertEqual(router.accountPane, .domain)
        XCTAssertEqual(router.path(for: .you).wrappedValue.count, 0, "the pane starts from its first screen")
        router.reset()
        XCTAssertEqual(router.accountPane, .vault)
        XCTAssertEqual(router.path(for: .you).wrappedValue.count, 0)
    }

    @MainActor
    func testTheLayoutIsTheDevicesAndNotTheWindows() {
        // A phone is a stack and an iPad is a list beside the pane; nothing else changes it afterwards.
        let router = AppRouter()
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        XCTAssertEqual(router.youIsStack, !isPad)
        router.open(.account(.keys))
        router.push(.artifact(slug: "x"), on: .you)
        let pushed = router.path(for: .you).wrappedValue.count
        router.open(.tab(.you))
        XCTAssertEqual(router.youIsStack, !isPad)
        XCTAssertEqual(router.path(for: .you).wrappedValue.count, pushed, "a link to the You tab itself leaves it as it is")
    }

    @MainActor
    func testTheYoursLinkOpensThePanelOnHome() {
        let router = AppRouter()
        router.tab = .memory
        router.open(.yours)
        XCTAssertEqual(router.tab, .canvas)
        XCTAssertTrue(router.yoursPanel)
    }

    @MainActor
    func testTheGroupChatsLinkAsksChatForItsGroupHalf() {
        let router = AppRouter()
        router.open(.groupChats)
        XCTAssertEqual(router.tab, .chat)
        XCTAssertTrue(router.groupChats)
    }

    // MARK: A link that names no route still starts its tab from the first screen

    @MainActor
    func testTheKeepAndYoursLinksAndAHomeLinkShowHomeFromItsFirstScreen() {
        let router = AppRouter()
        for link in [DeepLink.keep(prefill: nil), .keep(prefill: "a thought"), .yours, .tab(.canvas)] {
            router.push(.artifact(slug: "x"), on: .canvas)
            router.tab = .memory
            router.open(link)
            XCTAssertEqual(router.tab, .canvas, "\(link)")
            XCTAssertEqual(router.path(for: .canvas).wrappedValue.count, 0, "Home shows its first screen for \(link)")
        }
        XCTAssertEqual(router.canvasDraft, "a thought", "the text is waiting for the canvas")
    }

    @MainActor
    func testTheGroupChatsLinkShowsChatFromItsFirstScreen() {
        let router = AppRouter()
        router.push(.conversation(id: "c1"), on: .chat)
        router.push(.tools, on: .chat)
        router.open(.groupChats)
        XCTAssertEqual(router.tab, .chat)
        XCTAssertTrue(router.groupChats)
        XCTAssertEqual(router.path(for: .chat).wrappedValue.count, 0, "the list shows, not the conversation left open")
    }

    @MainActor
    func testAChatOrMemoryLinkShowsItsTabFromItsFirstScreen() {
        let router = AppRouter()
        router.push(.importHistory, on: .chat)
        router.push(.dreams, on: .memory)
        router.open(.tab(.chat))
        XCTAssertEqual(router.path(for: .chat).wrappedValue.count, 0, "Import, pushed on Chat, is closed: Open Chat lands on the list")
        XCTAssertEqual(router.path(for: .memory).wrappedValue.count, 1, "only the tab the link names is started over")
        router.open(.tab(.memory))
        XCTAssertEqual(router.path(for: .memory).wrappedValue.count, 0)
    }

    @MainActor
    func testALinkToARouteStillStartsFromTheRootOfItsTabAndLeavesTheOthersAlone() {
        let router = AppRouter()
        router.push(.artifact(slug: "a"), on: .canvas)
        router.push(.conversation(id: "c1"), on: .chat)
        router.open(.route(.conversation(id: "c2")))
        XCTAssertEqual(router.tab, .chat)
        XCTAssertEqual(router.path(for: .chat).wrappedValue.count, 1)
        XCTAssertEqual(router.path(for: .canvas).wrappedValue.count, 1)
    }

    // MARK: A link and a sheet

    @MainActor
    func testALinkClosesTheSheetOverTheTabs() {
        for link in [DeepLink.route(.artifact(slug: "x")), .tab(.chat), .account(.keys), .groupChats, .keep(prefill: nil)] {
            let router = AppRouter()
            router.sheet = .account
            router.open(link)
            XCTAssertNil(router.sheet, "\(link)")
        }
    }

    @MainActor
    func testALinkThatPresentsASheetKeepsItsOwn() {
        let router = AppRouter()
        router.sheet = .account
        router.open(.pair(code: "ABCD-EFGH"))
        XCTAssertEqual(router.sheet, .pair(code: "ABCD-EFGH"))
        router.open(.invite(code: nil))
        XCTAssertEqual(router.sheet, .invite(code: nil))
    }

    @MainActor
    func testTheYoursPanelWaitsForTheSheetThatWasUpToGo() {
        let router = AppRouter()
        router.sheet = .account
        router.open(.yours)
        XCTAssertNil(router.sheet)
        XCTAssertFalse(router.yoursPanel, "it would not present over a sheet that is still going")
        router.sheetDidDismiss()
        XCTAssertTrue(router.yoursPanel)

        // Nothing waits when there was no sheet, and a sheet that goes later asks for nothing.
        let free = AppRouter()
        free.open(.yours)
        XCTAssertTrue(free.yoursPanel)
        free.yoursPanel = false
        free.sheetDidDismiss()
        XCTAssertFalse(free.yoursPanel)

        // Starting over forgets what was waiting.
        let waiting = AppRouter()
        waiting.sheet = .account
        waiting.open(.yours)
        waiting.reset()
        waiting.sheetDidDismiss()
        XCTAssertFalse(waiting.yoursPanel)
    }

    @MainActor
    func testARouteStartsFromTheRootOfItsTab() {
        let router = AppRouter()
        router.push(.memory(id: "a"), on: .memory)
        router.push(.dreams, on: .memory)
        router.open(.route(.truth))
        XCTAssertEqual(router.tab, .memory)
        XCTAssertEqual(router.path(for: .memory).wrappedValue.count, 1)
    }

    @MainActor
    func testAPairLinkShowsThePairingSheetOverTheAgentKeysPane() {
        let router = AppRouter()
        router.open(.pair(code: "ABCD-EFGH"))
        XCTAssertEqual(router.sheet, .pair(code: "ABCD-EFGH"))
        XCTAssertEqual(router.tab, .you)
        XCTAssertEqual(router.accountPane, .keys)
    }

    @MainActor
    func testResetPutsEverythingBack() {
        let router = AppRouter()
        router.open(.account(.domain))
        router.open(.yours)
        router.open(.groupChats)
        router.sheet = .account
        router.reset()
        XCTAssertEqual(router.tab, .canvas)
        XCTAssertEqual(router.accountPane, .vault)
        XCTAssertFalse(router.yoursPanel)
        XCTAssertFalse(router.groupChats)
        XCTAssertNil(router.sheet)
    }
}
