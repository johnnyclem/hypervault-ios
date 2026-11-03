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
        XCTAssertEqual(link("https://hypervault.store/vault/mail"), .tab(.mail))
        XCTAssertEqual(link("https://hypervault.store/g/portfolio-site-x1"), .route(.artifact(slug: "portfolio-site-x1")))
        XCTAssertEqual(link("hypervault://mail/msg-42"), .route(.mailThread(id: "msg-42")))
        XCTAssertEqual(link("hypervault://truth/review"), .route(.truthReview))
        XCTAssertEqual(link("hypervault://taskboards"), .tab(.projects))
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
        XCTAssertEqual(link("hypervault://tab/canvas"), .tab(.home), "Home keeps the raw value its widgets carry")
        XCTAssertEqual(link("hypervault://keep"), .keep(prefill: nil))
        XCTAssertEqual(link("hypervault://artifact/trip-notes"), .route(.artifact(slug: "trip-notes")))
        XCTAssertEqual(link("hypervault://memory/7f1c"), .route(.memory(id: "7f1c")))
        XCTAssertEqual(link("hypervault://tab/YOURS"), .yours)
        XCTAssertEqual(link("hypervault://tab/Canvas"), .tab(.home))

        // What each opens: the panel on Home, and Home.
        XCTAssertEqual(DeepLink.yours.destination.tab, .home)
        XCTAssertNil(DeepLink.yours.destination.route)
        XCTAssertEqual(DeepLink.tab(.home).destination.tab, .home)
    }

    func testEveryTabNamesItself() {
        XCTAssertEqual(link("hypervault://tab/home"), .tab(.home))
        XCTAssertEqual(link("hypervault://tab/projects"), .tab(.projects))
        XCTAssertEqual(link("hypervault://tab/memory"), .tab(.memory))
        XCTAssertEqual(link("hypervault://tab/mail"), .tab(.mail))
        XCTAssertEqual(link("hypervault://tab/MAIL"), .tab(.mail))
    }

    /// The two tabs that are gone keep their links: Chat is Home's chats, You is Settings, and the task boards are Projects.
    func testTheLinksOfTheTabsThatAreGoneStillOpenSomething() {
        XCTAssertEqual(link("hypervault://tab/chat"), .tab(.home))
        XCTAssertEqual(link("hypervault://tab/you"), .account(nil))
        XCTAssertEqual(link("hypervault://tab/taskboards"), .tab(.projects))
        XCTAssertEqual(link("hypervault://tab/task-boards"), .tab(.projects))
    }

    func testTheNamesOfMailAndProjectsAreTheirTabs() {
        XCTAssertEqual(link("hypervault://mail"), .tab(.mail))
        XCTAssertEqual(link("https://hypervault.store/vault/mail"), .tab(.mail))
        XCTAssertEqual(link("hypervault://projects"), .tab(.projects))
        XCTAssertEqual(link("hypervault://task-boards"), .tab(.projects))
        XCTAssertEqual(link("hypervault://tasks"), .tab(.projects))
        XCTAssertEqual(link("hypervault://mail/msg-42"), .route(.mailThread(id: "msg-42")), "a message is a pushed screen of the Mail tab")
    }

    // MARK: The web's paths

    func testTheVaultIsHomeAndLibraryIsTheLibrary() {
        XCTAssertEqual(link("https://hypervault.store/vault"), .tab(.home))
        XCTAssertEqual(link("https://hypervault.store/vault/"), .tab(.home))
        XCTAssertEqual(link("hypervault://vault"), .tab(.home))
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
        XCTAssertEqual(link("https://hypervault.store/chat"), .tab(.home))
        XCTAssertEqual(link("https://hypervault.store/chat?c=abc-123"), .route(.conversation(id: "abc-123")))
        XCTAssertEqual(link("https://hypervault.store/chat/abc-123"), .route(.conversation(id: "abc-123")))
        XCTAssertEqual(link("https://hypervault.store/chat?other=1"), .tab(.home))
    }

    // MARK: Settings, the web's You page: /vault/account, ?tab= and the hash

    func testSettingsOpensTheVaultWhenNothingNamesAPane() {
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
        XCTAssertEqual(DeepLink.route(library).destination.tab, .home)
        XCTAssertEqual(DeepLink.route(library).destination.route, library)
        let review = Route.truthReviewLedger(slug: "team")
        XCTAssertEqual(DeepLink.route(review).destination.route, review)
    }

    // MARK: Pairing

    func testAPairLinkNamesNoTabAndKeepsTheCode() throws {
        let pair = try XCTUnwrap(link("https://hypervault.store/pair?user_code=BCDF-2346"))
        XCTAssertEqual(pair, .pair(code: "BCDF-2346"))
        XCTAssertNil(pair.destination.tab, "it presents the Account sheet over the tab that shows")
        XCTAssertNil(pair.destination.route)
        XCTAssertEqual(link("hypervault://pair"), .pair(code: nil))
    }

    // MARK: Where each lands

    func testDestinations() {
        // Home: pages, the Library, Admin, chats, rooms, Tools and the history import, and what Home itself answers to.
        XCTAssertEqual(DeepLink.route(.artifact(slug: "x")).destination.tab, .home)
        XCTAssertEqual(DeepLink.route(.library).destination.tab, .home)
        XCTAssertEqual(DeepLink.route(.admin).destination.tab, .home)
        XCTAssertEqual(DeepLink.keep(prefill: nil).destination.tab, .home)
        XCTAssertEqual(DeepLink.invite(code: nil).destination.tab, .home)
        XCTAssertEqual(DeepLink.route(.room(id: "x")).destination.tab, .home)
        XCTAssertEqual(DeepLink.route(.conversation(id: "x")).destination.tab, .home)
        XCTAssertEqual(DeepLink.route(.tools).destination.tab, .home)
        XCTAssertEqual(DeepLink.route(.importHistory).destination.tab, .home)
        XCTAssertEqual(DeepLink.groupChats.destination.tab, .home)
        // Mail: a message. (The inbox itself is the tab.)
        XCTAssertEqual(DeepLink.route(.mailThread(id: "m")).destination.tab, .mail)
        // Projects: a board. (The list itself is the tab.)
        XCTAssertEqual(DeepLink.route(.taskBoard(slug: "s", project: "p", title: "t")).destination.tab, .projects)
        // Memory: memories, Dreams, Digest and Truth.
        XCTAssertEqual(DeepLink.route(.memory(id: "x")).destination.tab, .memory)
        XCTAssertEqual(DeepLink.route(.dreams).destination.tab, .memory)
        XCTAssertEqual(DeepLink.route(.digest).destination.tab, .memory)
        XCTAssertEqual(DeepLink.route(.truth).destination.tab, .memory)
        XCTAssertEqual(DeepLink.route(.truthReview).destination.tab, .memory)
        // Settings: a pane, which is not a route and not a tab.
        XCTAssertNil(DeepLink.account(.keys).destination.tab)
        XCTAssertNil(DeepLink.account(nil).destination.tab)
        XCTAssertNil(DeepLink.account(.keys).destination.route)
    }

    func testTheDestinationOfARouteIsTheRouteItself() {
        XCTAssertEqual(DeepLink.route(.truth).destination.route, .truth)
        XCTAssertEqual(DeepLink.route(.artifact(slug: "x")).destination.route, .artifact(slug: "x"))
        XCTAssertNil(DeepLink.tab(.home).destination.route)
    }

    // MARK: The tabs

    func testTheTabBarIsHomeProjectsMemoryMailWithTheirSymbols() {
        XCTAssertEqual(AppTab.allCases, [.home, .projects, .memory, .mail])
        XCTAssertEqual(AppTab.allCases.map(\.title), ["Home", "Projects", "Memory", "Mail"])
        XCTAssertEqual(AppTab.allCases.map(\.symbol), ["house", "square.stack.3d.up", "point.3.connected.trianglepath.dotted", "envelope"])
        XCTAssertEqual(AppTab.home.rawValue, "canvas", "installed widgets carry hypervault://tab/canvas")
    }

    // MARK: What the router does with a link

    @MainActor
    func testASettingsLinkPresentsTheAccountSheetOnThePaneAndLeavesTheTabAlone() {
        let router = AppRouter()
        router.tab = .memory
        router.push(.dreams, on: .memory)
        router.open(.account(.keys))
        XCTAssertEqual(router.sheet, .account)
        XCTAssertEqual(router.tab, .memory, "a sheet over the tab that shows, not a tab")
        XCTAssertEqual(router.path(for: .memory).wrappedValue.count, 1, "and it leaves what was pushed there")
        XCTAssertEqual(router.accountPane, .keys)
        XCTAssertEqual(router.accountPath.count, 2, "the list of panes, then the pane")

        router.open(.account(nil))
        XCTAssertEqual(router.accountPane, .vault, "no pane named is the vault")
        XCTAssertEqual(router.accountPath.count, 2)
        XCTAssertEqual(router.sheet, .account, "the sheet that was up stays up")
    }

    @MainActor
    func testTheAccountMenuStartsFromItsFirstScreenAndAPaneIsPushedOnIt() {
        let router = AppRouter()
        router.showSettings(.domain)
        XCTAssertEqual(router.accountPath.count, 2)
        router.pushInAccount(.artifact(slug: "x"))
        XCTAssertEqual(router.accountPath.count, 3, "what a pane shows is on the sheet's stack")
        XCTAssertEqual(router.path(for: router.tab).wrappedValue.count, 0, "and not on the stack of the tab behind it")

        router.showAccountMenu()
        XCTAssertEqual(router.sheet, .account)
        XCTAssertEqual(router.accountPath.count, 0, "the avatar opens the menu, not the pane that was last open")

        router.showSettings()
        router.openPane(.appearance)
        XCTAssertEqual(router.accountPane, .appearance)
        XCTAssertEqual(router.accountPath.count, 3, "a pane chosen from the list is pushed on it")
    }

    @MainActor
    func testTheYoursLinkOpensThePanelOnHome() {
        let router = AppRouter()
        router.tab = .memory
        router.open(.yours)
        XCTAssertEqual(router.tab, .home)
        XCTAssertTrue(router.yoursPanel)
    }

    @MainActor
    func testTheGroupChatsLinkAsksTheChatsForTheirGroupHalf() {
        let router = AppRouter()
        router.tab = .memory
        router.open(.groupChats)
        XCTAssertEqual(router.tab, .home)
        XCTAssertTrue(router.groupChats)
    }

    // MARK: A link that names no route still starts its tab from the first screen

    @MainActor
    func testTheKeepAndYoursLinksAndAHomeLinkShowHomeFromItsFirstScreen() {
        let router = AppRouter()
        for link in [DeepLink.keep(prefill: nil), .keep(prefill: "a thought"), .yours, .tab(.home)] {
            router.push(.artifact(slug: "x"), on: .home)
            router.tab = .memory
            router.open(link)
            XCTAssertEqual(router.tab, .home, "\(link)")
            XCTAssertEqual(router.path(for: .home).wrappedValue.count, 0, "Home shows its first screen for \(link)")
        }
        XCTAssertEqual(router.canvasDraft, "a thought", "the text is waiting for the canvas")
    }

    @MainActor
    func testTheGroupChatsLinkShowsHomeFromItsFirstScreen() {
        let router = AppRouter()
        router.push(.conversation(id: "c1"), on: .home)
        router.push(.tools, on: .home)
        router.open(.groupChats)
        XCTAssertEqual(router.tab, .home)
        XCTAssertTrue(router.groupChats)
        XCTAssertEqual(router.path(for: .home).wrappedValue.count, 0, "the list shows, not the conversation left open")
    }

    @MainActor
    func testATabLinkShowsItsTabFromItsFirstScreen() {
        let router = AppRouter()
        router.push(.importHistory, on: .home)
        router.push(.dreams, on: .memory)
        router.push(.mailThread(id: "m1"), on: .mail)
        router.open(.tab(.home))
        XCTAssertEqual(router.path(for: .home).wrappedValue.count, 0, "Import, pushed on Home, is closed: Open Chat lands on the list")
        XCTAssertEqual(router.path(for: .memory).wrappedValue.count, 1, "only the tab the link names is started over")
        router.open(.tab(.memory))
        XCTAssertEqual(router.path(for: .memory).wrappedValue.count, 0)
        router.open(.tab(.mail))
        XCTAssertEqual(router.tab, .mail)
        XCTAssertEqual(router.path(for: .mail).wrappedValue.count, 0, "Mail opens on the inbox, not on the message left open")
    }

    @MainActor
    func testALinkToARouteStillStartsFromTheRootOfItsTabAndLeavesTheOthersAlone() {
        let router = AppRouter()
        router.push(.artifact(slug: "a"), on: .home)
        router.push(.mailThread(id: "m1"), on: .mail)
        router.open(.route(.mailThread(id: "m2")))
        XCTAssertEqual(router.tab, .mail)
        XCTAssertEqual(router.path(for: .mail).wrappedValue.count, 1)
        XCTAssertEqual(router.path(for: .home).wrappedValue.count, 1)
    }

    // MARK: A link and a sheet

    @MainActor
    func testALinkClosesTheSheetOverTheTabs() {
        for link in [DeepLink.route(.artifact(slug: "x")), .tab(.mail), .groupChats, .keep(prefill: nil)] {
            let router = AppRouter()
            router.sheet = .account
            router.open(link)
            XCTAssertNil(router.sheet, "\(link)")
        }
    }

    @MainActor
    func testALinkThatPresentsASheetKeepsOneOfItsOwn() {
        let router = AppRouter()
        router.sheet = .account
        router.open(.account(.keys))
        XCTAssertEqual(router.sheet, .account, "Settings over the Account sheet is the same sheet, moved to the pane")

        let invite = AppRouter()
        invite.open(.invite(code: nil))
        XCTAssertEqual(invite.sheet, .invite(code: nil))
    }

    @MainActor
    func testASheetThatIsAskedForWhileAnotherIsUpWaitsForItToGo() {
        let router = AppRouter()
        router.sheet = .connectAgent
        router.open(.account(.keys))
        XCTAssertNil(router.sheet, "the sheet that was up goes first; one set over it would not present")
        XCTAssertEqual(router.accountPath.count, 2, "but the stack is ready for it")
        router.sheetDidDismiss()
        XCTAssertEqual(router.sheet, .account)
        router.sheetDidDismiss()
        XCTAssertEqual(router.sheet, .account, "asking for nothing more presents nothing more")

        // The same for an invite over the Account sheet.
        let over = AppRouter()
        over.showAccountMenu()
        over.open(.invite(code: "HV-1"))
        XCTAssertNil(over.sheet)
        over.sheetDidDismiss()
        XCTAssertEqual(over.sheet, .invite(code: "HV-1"))
    }

    @MainActor
    func testALinkThatClosesSheetsForgetsASheetThatWasWaiting() {
        let router = AppRouter()
        router.sheet = .connectAgent
        router.open(.account(.keys))
        router.open(.tab(.mail))
        router.sheetDidDismiss()
        XCTAssertNil(router.sheet, "the latest link named a tab, so the Account sheet does not come back")
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
    func testAPairLinkOpensTheAgentKeysPaneAndLeavesTheRequestForIt() {
        let router = AppRouter()
        router.open(.pair(code: "ABCD-EFGH"))
        XCTAssertEqual(router.sheet, .account, "the pairing page is the pane's to present, so the sheet shows the pane")
        XCTAssertEqual(router.pairing?.code, "ABCD-EFGH")
        XCTAssertEqual(router.accountPane, .keys)
        XCTAssertEqual(router.accountPath.count, 2)
        XCTAssertEqual(router.tab, .home, "the tab that showed still does")
    }

    @MainActor
    func testAPairLinkWithNoCodeIsStillARequest() {
        let router = AppRouter()
        router.open(.pair(code: nil))
        let request = router.pairing
        XCTAssertNotNil(request)
        XCTAssertNil(request?.code)
        router.open(.pair(code: nil))
        XCTAssertNotEqual(router.pairing, request, "a second ask is a request of its own, so the pane sees it change")
    }

    @MainActor
    func testResetPutsEverythingBack() {
        let router = AppRouter()
        router.open(.account(.domain))
        router.open(.pair(code: "ABCD-EFGH"))
        router.pushInAccount(.library)
        router.open(.yours)
        router.open(.groupChats)
        router.sheet = .connectAgent
        router.open(.account(.keys))
        router.reset()
        XCTAssertEqual(router.tab, .home)
        XCTAssertEqual(router.accountPane, .vault)
        XCTAssertEqual(router.accountPath.count, 0)
        XCTAssertNil(router.pairing)
        XCTAssertFalse(router.yoursPanel)
        XCTAssertFalse(router.groupChats)
        XCTAssertNil(router.sheet)
        router.sheetDidDismiss()
        XCTAssertNil(router.sheet, "a sheet that was waiting is forgotten")
    }
}
