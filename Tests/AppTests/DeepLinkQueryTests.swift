import HyperVaultKit
import XCTest
@testable import HyperVault

/// What a link to the web's query (`?mode=`, `?branch=`, `?filter=`, `?q=`, `?ledger=`) leaves for the screens, and what the
/// Memory tab does with a branch. How a link is read is in `DeepLinkTests`.
@MainActor
final class DeepLinkQueryTests: XCTestCase {
    private func open(_ text: String, on router: AppRouter, file: StaticString = #filePath, line: UInt = #line) throws {
        let link = try XCTUnwrap(URL(string: text).flatMap(DeepLink.init(url:)), text, file: file, line: line)
        router.open(link)
    }

    // MARK: The router

    func testAMemoryLinkLeavesItsViewAndBranchForTheMemoryScreen() throws {
        let router = AppRouter()
        router.push(.memory(id: "m1"), on: .memory)
        router.sheet = .account
        try open("https://hypervault.store/vault/memory?mode=graph&branch=feature-x", on: router)
        XCTAssertEqual(router.tab, .memory)
        XCTAssertEqual(router.path(for: .memory).wrappedValue.count, 0, "the tab starts from its first screen")
        XCTAssertNil(router.sheet)
        XCTAssertEqual(router.memoryMode, .graph)
        XCTAssertEqual(router.memoryBranch, "feature-x")
    }

    func testTheNextMemoryLinkNamesWhatItNamesAndNothingMore() throws {
        let router = AppRouter()
        try open("https://hypervault.store/vault/memory?mode=graph&branch=feature-x", on: router)
        try open("https://hypervault.store/vault/memory?mode=ask", on: router)
        XCTAssertEqual(router.memoryMode, .ask)
        XCTAssertNil(router.memoryBranch, "the branch the first link named was not this one's")
        try open("https://hypervault.store/vault/memory?branch=main", on: router)
        XCTAssertNil(router.memoryMode)
        XCTAssertEqual(router.memoryBranch, "main")
    }

    func testAPlainMemoryLinkAsksForNothing() throws {
        let router = AppRouter()
        try open("https://hypervault.store/vault/memory", on: router)
        XCTAssertEqual(router.tab, .memory)
        XCTAssertNil(router.memoryMode)
        XCTAssertNil(router.memoryBranch)
        try open("https://hypervault.store/vault/memory?mode=bogus&branch=Not%20A%20Branch", on: router)
        XCTAssertEqual(router.tab, .memory)
        XCTAssertNil(router.memoryMode)
        XCTAssertNil(router.memoryBranch)
    }

    func testAMemoryByItsIdOpensItOnTheMemoryTab() throws {
        let router = AppRouter()
        try open("https://hypervault.store/vault/memory?open=7f1c", on: router)
        XCTAssertEqual(router.tab, .memory)
        XCTAssertEqual(router.path(for: .memory).wrappedValue.count, 1, "the memory is pushed, as hypervault://memory/7f1c does")
        XCTAssertNil(router.memoryMode)
        XCTAssertNil(router.memoryBranch)
    }

    func testDigestModeOpensTheDigestScreenOnTheMemoryTab() throws {
        let router = AppRouter()
        router.tab = .canvas
        try open("https://hypervault.store/vault/memory?mode=digest", on: router)
        XCTAssertEqual(router.tab, .memory)
        XCTAssertEqual(router.path(for: .memory).wrappedValue.count, 1)
        XCTAssertNil(router.memoryMode, "Digest is a screen, not one of the three views")
    }

    func testALibraryLinkPushesTheLibraryOnHome() throws {
        let router = AppRouter()
        router.tab = .memory
        router.push(.artifact(slug: "x"), on: .canvas)
        try open("https://hypervault.store/vault/library?filter=memory&q=trip", on: router)
        XCTAssertEqual(router.tab, .canvas)
        XCTAssertEqual(router.path(for: .canvas).wrappedValue.count, 1, "the Library alone, from Home's first screen")
        let link = DeepLink(url: URL(string: "https://hypervault.store/vault/library?filter=memory&q=trip")!)
        XCTAssertEqual(link?.destination.route, .libraryFiltered(filter: .memory, query: "trip"), "and it carries what the link chose")
    }

    func testATruthReviewLinkPushesTheReviewOnTheMemoryTab() throws {
        let router = AppRouter()
        router.push(.dreams, on: .memory)
        try open("https://hypervault.store/vault/truth/review?ledger=team", on: router)
        XCTAssertEqual(router.tab, .memory)
        XCTAssertEqual(router.path(for: .memory).wrappedValue.count, 1)
        let link = DeepLink(url: URL(string: "https://hypervault.store/vault/truth/review?ledger=team")!)
        XCTAssertEqual(link?.destination.route, .truthReviewLedger(slug: "team"))
    }

    func testStartingOverForgetsWhatAMemoryLinkLeft() throws {
        let router = AppRouter()
        try open("https://hypervault.store/vault/memory?mode=ask&branch=feature-x", on: router)
        router.reset()
        XCTAssertNil(router.memoryMode)
        XCTAssertNil(router.memoryBranch)
    }

    // MARK: The branch

    /// Counts the reads of the branch list, which a test's canned route can add to from any thread.
    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func hit() {
            lock.lock()
            defer { lock.unlock() }
            count += 1
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    private let branches = #"{"branches":[{"id":"b1","name":"main","is_default":true},{"id":"b2","name":"feature-x"}]}"#

    private func branchRoute(_ reads: Reads, json: String? = nil) -> MockRoute {
        let body = json ?? branches
        return MockRoute(.get, "/api/mind/branches") { _ in
            reads.hit()
            return HTTPResponse(status: 200, headers: ["content-type": "application/json"], data: Data(body.utf8))
        }
    }

    /// A list for a person of its own, whose remembered branch is forgotten when the test ends.
    private func makeList(_ routes: [MockRoute]) -> MemoryListModel {
        let user = AuthUser(id: "branch-link-\(UUID().uuidString)", email: "sam@example.com", displayName: "Sam")
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: MemoryBranchStore.key(for: user.id)) }
        return MemoryListModel(env: .preview(routes: routes, user: user))
    }

    func testABranchThePersonHasIsSwitchedToTheWayTheMenuDoes() async {
        let reads = Reads()
        let list = makeList([branchRoute(reads)])
        XCTAssertEqual(list.branch, "main")
        let switched = await list.switchBranch(named: "feature-x")
        XCTAssertTrue(switched)
        XCTAssertEqual(list.branch, "feature-x")
        XCTAssertEqual(MemoryBranchStore.current(for: list.userID), "feature-x", "remembered, as the menu's switch is")
        XCTAssertEqual(reads.value, 1, "the branches were read once, to check it")
    }

    func testABranchThePersonDoesNotHaveIsLeftAlone() async {
        let reads = Reads()
        let list = makeList([branchRoute(reads)])
        let switched = await list.switchBranch(named: "nope")
        XCTAssertFalse(switched)
        XCTAssertEqual(list.branch, "main")
        XCTAssertEqual(MemoryBranchStore.current(for: list.userID), "main", "nothing was remembered")
    }

    func testANameThatCannotBeABranchIsNotLookedUp() async {
        let reads = Reads()
        let list = makeList([branchRoute(reads)])
        for name in ["Feature X", "", "-x", "a..b", String(repeating: "a", count: 64)] {
            let switched = await list.switchBranch(named: name)
            XCTAssertFalse(switched, name)
        }
        XCTAssertEqual(list.branch, "main")
        XCTAssertEqual(reads.value, 0, "a name the server would refuse is not worth a request")
    }

    func testMainIsAlwaysThePersonsAndNeedsNoList() async {
        let reads = Reads()
        let list = makeList([branchRoute(reads)])
        list.switchBranch(to: "feature-x")
        let switched = await list.switchBranch(named: "main")
        XCTAssertTrue(switched)
        XCTAssertEqual(list.branch, "main")
        XCTAssertEqual(reads.value, 0)
    }

    func testAListThatCannotBeReadLeavesTheBranchAlone() async {
        let list = makeList([.failure(.get, "/api/mind/branches", status: 404, message: "Not found.")])
        let switched = await list.switchBranch(named: "feature-x")
        XCTAssertFalse(switched)
        XCTAssertEqual(list.branch, "main")
    }

    func testABranchTheTabAlreadyListsIsNotReadForAgain() async {
        let reads = Reads()
        let list = makeList([branchRoute(reads)])
        await list.loadBranches()
        let before = reads.value
        XCTAssertGreaterThan(before, 0)
        let switched = await list.switchBranch(named: "feature-x")
        XCTAssertTrue(switched)
        XCTAssertEqual(list.branch, "feature-x")
        XCTAssertEqual(reads.value, before)
    }

    func testTheBranchAPersonIsAlreadyOnIsTheSameBranch() async {
        let reads = Reads()
        let list = makeList([branchRoute(reads)])
        let switched = await list.switchBranch(named: "main")
        XCTAssertTrue(switched)
        XCTAssertEqual(list.branch, "main")
    }

    // MARK: The Library

    func testALibraryLinkThatNamesAFilterOrASearchOpensTheListNotTheGraph() {
        XCTAssertFalse(LibraryScreen.linkNamesWhatToShow(filter: .all, query: ""), "a plain Library link leaves the saved choice alone")
        XCTAssertFalse(LibraryScreen.linkNamesWhatToShow(filter: .all, query: "   "), "spaces name nothing")
        XCTAssertTrue(LibraryScreen.linkNamesWhatToShow(filter: .key, query: ""))
        XCTAssertTrue(LibraryScreen.linkNamesWhatToShow(filter: .file, query: ""))
        XCTAssertTrue(LibraryScreen.linkNamesWhatToShow(filter: .all, query: "trip"))
        XCTAssertTrue(LibraryScreen.linkNamesWhatToShow(filter: .memory, query: "trip"))
    }
}
