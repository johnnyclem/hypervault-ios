import HyperVaultKit
import XCTest
@testable import HyperVault

/// Counts what a canned route was asked, from any thread.
private final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func hit() {
        lock.lock()
        calls += 1
        lock.unlock()
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
}

/// The overview of one project: the board and the sections that go with it are read side by side, each section says why a row
/// is in it, and a read that fails takes only its own section with it.
@MainActor
final class ProjectOverviewModelTests: XCTestCase {
    private let project = "eurorack-choir"

    private func loaded(_ model: ProjectOverviewModel, file: StaticString = #filePath, line: UInt = #line) -> (digest: ProjectBoardDigest, related: ProjectRelated)? {
        guard case .loaded(let digest) = model.board, case .loaded(let related) = model.related else {
            XCTFail("The board and what goes with it should both have loaded.", file: file, line: line)
            return nil
        }
        return (digest, related)
    }

    func testEveryReadAnsweringGivesTheBoardAndEachSectionWithItsReason() async throws {
        let env = AppEnvironment.preview(routes: ProjectPreviewData.overviewRoutes)
        let model = ProjectOverviewModel(env: env, project: project)
        await model.start()
        let (digest, related) = try XCTUnwrap(loaded(model))

        XCTAssertEqual(model.title, "Eurorack Choir Module", "the board says what it is called")
        XCTAssertEqual(digest.focus.map(\.id), ["t-panels", "t-fw", "t-review", "t-psu"], "in progress, blocked, in review, to do; the epic is its subtasks")
        XCTAssertEqual(digest.agents, [ProjectAgent(name: "Claude Code", tasks: 1)])
        XCTAssertEqual(digest.summary.progress, 29)

        XCTAssertEqual(related.pages.map(\.title), ["Power supply notes", "Panel drawings"])
        XCTAssertEqual(related.pages.map(\.relation), [.linked, .tagged])
        XCTAssertEqual(related.memories.map(\.title), ["Power budget", "Bench notes", "Choir module wiring"])
        XCTAssertEqual(related.memories.map(\.relation), [.linked, .tagged, .mentions])
        XCTAssertEqual(related.chats.map(\.title), ["Eurorack choir front panel quotes", "Choir module power budget"])
        XCTAssertEqual(Set(related.chats.map(\.relation)), [.mentions])
        XCTAssertEqual(related.possibly.map(\.title), ["Trip to Lisbon"], "the server's guess waits behind \"Show possibly related\"")
        XCTAssertTrue(model.unavailable.isEmpty)
        XCTAssertFalse(model.boardIsStale)
        XCTAssertFalse(model.relatedIsStale)
    }

    func testASectionKeepsAllItFoundAndTheScreenShowsTheFirstFew() async throws {
        let env = AppEnvironment.preview(routes: ProjectPreviewData.longRoutes)
        let model = ProjectOverviewModel(env: env, project: project)
        await model.start()
        let (_, related) = try XCTUnwrap(loaded(model))
        XCTAssertEqual(related.pages.count, 9)
        XCTAssertEqual(related.pageTotal, 9)
        XCTAssertEqual(ProjectRelated.shown(related.pages, opened: false).count, ProjectRelated.visibleLimit)
        XCTAssertEqual(ProjectRelated.shown(related.pages, opened: true).count, 9)
    }

    func testTheBoardAndTheSectionsAreSavedUnderTheKeysTheOtherScreensShare() async {
        let env = AppEnvironment.preview(routes: ProjectPreviewData.overviewRoutes)
        let model = ProjectOverviewModel(env: env, project: project)
        await model.start()
        let board = await env.cache.entry(TaskBoard.self, key: "taskboards.board.\(project)", namespace: env.user.id)
        XCTAssertEqual(board?.value.version, 42, "the full board opens warm after the overview, and the other way round")
        let related = await env.cache.entry(ProjectRelated.self, key: "projects.related.\(project)", namespace: env.user.id)
        XCTAssertEqual(related?.value.pages.count, 2)
    }

    func testTheListsTitleIsTheFirstThingTheNavigationBarSays() async {
        let env = AppEnvironment.preview(routes: ProjectPreviewData.overviewRoutes)
        await env.cache.store(TaskBoardIndex(boards: [TaskBoardPreviewData.listing]), key: "taskboards.index", namespace: env.user.id)
        let model = ProjectOverviewModel(env: env, project: project)
        XCTAssertEqual(model.title, ArtifactSlugName.readable(project), "before anything is known, the id read as words")
        await model.start()
        XCTAssertEqual(model.title, "Eurorack Choir Module")
    }

    func testAFailingChatListLeavesPagesAndMemoriesAndIsNotSaved() async throws {
        let env = AppEnvironment.preview(routes: ProjectPreviewData.partialRoutes)
        let model = ProjectOverviewModel(env: env, project: project)
        await model.start()
        let (_, related) = try XCTUnwrap(loaded(model))
        XCTAssertEqual(model.unavailable, [.chats])
        XCTAssertEqual(related.pages.count, 2)
        XCTAssertEqual(related.memories.count, 3)
        XCTAssertTrue(related.chats.isEmpty)
        let saved = await env.cache.entry(ProjectRelated.self, key: "projects.related.\(project)", namespace: env.user.id)
        XCTAssertNil(saved, "a partial answer would paint holes on the next visit")
    }

    func testFailedLinksStillGiveTagsAndNames() async throws {
        let routes = [MockRoute.failure(.get, "/api/connections", status: 500, message: "No links today.")] + ProjectPreviewData.overviewRoutes
        let env = AppEnvironment.preview(routes: routes)
        let model = ProjectOverviewModel(env: env, project: project)
        await model.start()
        let (_, related) = try XCTUnwrap(loaded(model))
        XCTAssertEqual(model.unavailable, [.links])
        XCTAssertEqual(related.pages.map(\.title), ["Panel drawings"], "only the tag is left of the page reasons")
        XCTAssertEqual(related.memories.map(\.relation), [.tagged, .mentions])
        XCTAssertTrue(related.possibly.isEmpty)
    }

    func testABoardThatIsNotInTheVaultIsAllThatIsSaid() async {
        let env = AppEnvironment.preview(routes: ProjectPreviewData.missingRoutes)
        let model = ProjectOverviewModel(env: env, project: project)
        await model.start()
        XCTAssertTrue(model.boardFailed)
        guard case .failed(let message) = model.board else { return XCTFail("The board should have failed.") }
        XCTAssertTrue(message.contains("No task list"), "the server's own words: \(message)")
        guard case .loading = model.related else { return XCTFail("Nothing else is put together for a project that is not here.") }
    }

    func testTryAgainOnABoardPutsTheRestTogether() async throws {
        let project = self.project   // the canned routes below are @Sendable closures: they take the value, not the test case
        let open = Asked()
        let board = MockRoute(.get, "/api/tasklists/\(project)") { _ in
            if open.count == 0 {
                return HTTPResponse(status: 404, headers: ["content-type": "application/json"], data: Data(#"{"error":"No task list."}"#.utf8))
            }
            return HTTPResponse(status: 200, headers: ["content-type": "application/json"], data: Data(#"{"slug":"tasks-\#(project)","tasklist":\#(TaskBoardPreviewData.boardJSON)}"#.utf8))
        }
        let env = AppEnvironment.preview(routes: [board] + ProjectPreviewData.overviewRoutes)
        let model = ProjectOverviewModel(env: env, project: project)
        await model.start()
        XCTAssertTrue(model.boardFailed)
        open.hit()
        await model.retryBoard()
        XCTAssertFalse(model.boardFailed)
        let (_, related) = try XCTUnwrap(loaded(model))
        XCTAssertEqual(related.chats.count, 2, "matched by the board's name, which the board has now said")
    }

    func testRefreshingABoardThatNeverAnsweredReadsItBeforeTheSections() async throws {
        let project = self.project
        let tries = Asked(), answered = Asked(), armed = Asked(), early = Asked()
        let board = MockRoute(.get, "/api/tasklists/\(project)") { _ in
            tries.hit()
            if tries.count == 1 {
                return HTTPResponse(status: 404, headers: ["content-type": "application/json"], data: Data(#"{"error":"No task list."}"#.utf8))
            }
            answered.hit()
            return HTTPResponse(status: 200, headers: ["content-type": "application/json"], data: Data(#"{"slug":"tasks-\#(project)","tasklist":\#(TaskBoardPreviewData.boardJSON)}"#.utf8))
        }
        let chats = MockRoute(.get, "/api/conversations") { _ in
            if armed.count > 0, answered.count == 0 { early.hit() }
            return HTTPResponse(status: 200, headers: ["content-type": "application/json"], data: Data(ProjectPreviewData.conversationsJSON.utf8))
        }
        let env = AppEnvironment.preview(routes: [board, chats] + ProjectPreviewData.overviewRoutes)
        let model = ProjectOverviewModel(env: env, project: project)
        await model.start()
        XCTAssertTrue(model.boardFailed)
        armed.hit()
        await model.refresh()
        XCTAssertEqual(early.count, 0, "no section is read while the board has still not said what it is called")
        let (_, related) = try XCTUnwrap(loaded(model))
        XCTAssertEqual(related.chats.count, 2, "matched by the board's name, not by the id the screen guessed it from")
    }

    func testTheBoardPageIsLookedUpByItsCardWhenTheTableDoesNotHoldIt() async throws {
        let cards = Asked()
        let card = MockRoute(.get, "/api/yours/card") { _ in
            cards.hit()
            return HTTPResponse(
                status: 200, headers: ["content-type": "application/json"],
                data: Data(#"{"id":"art-board-choir","kind":"page","name":"Eurorack Choir Module","href":"/a/taskboard-eurorack-choir"}"#.utf8)
            )
        }
        // A vault past its newest pages: the table read has no board page, and the links still name it by its row id.
        let routes = [card, .json(.get, "/rest/v1/artifacts", "[]")] + ProjectPreviewData.overviewRoutes
        let env = AppEnvironment.preview(routes: routes)
        let model = ProjectOverviewModel(env: env, project: project)
        await model.start()
        let (_, related) = try XCTUnwrap(loaded(model))
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(related.memories.first?.title, "Power budget", "the memory joined to the board page is found through the card's row id")
        XCTAssertEqual(related.memories.first?.relation, .linked)
    }

    func testComingBackWithinAMinuteChecksTheBoardAndReadsNothingElseAgain() async {
        let project = self.project
        let links = Asked(), polls = Asked()
        let counted = [
            MockRoute(.get, "/api/connections") { _ in
                links.hit()
                return HTTPResponse(status: 200, headers: ["content-type": "application/json"], data: Data(ProjectPreviewData.connectionsJSON.utf8))
            },
            MockRoute(.get, "/api/tasklists/\(project)") { request in
                if request.url?.query?.contains("since_version=42") == true {
                    polls.hit()
                    return HTTPResponse(status: 200, headers: ["content-type": "application/json"], data: Data(#"{"unchanged":true,"version":42}"#.utf8))
                }
                return HTTPResponse(status: 200, headers: ["content-type": "application/json"], data: Data(#"{"slug":"tasks-\#(project)","tasklist":\#(TaskBoardPreviewData.boardJSON)}"#.utf8))
            },
        ]
        let env = AppEnvironment.preview(routes: counted + ProjectPreviewData.overviewRoutes)
        let model = ProjectOverviewModel(env: env, project: project)
        await model.refreshIfStarted()
        XCTAssertEqual(links.count, 0, "a screen that has not started loads nothing on appearing")
        await model.start()
        await model.refreshIfStarted()
        XCTAssertEqual(links.count, 1, "the links are not read again inside a minute")
        XCTAssertEqual(polls.count, 1, "the board is asked whether it moved")
        await model.refresh()
        XCTAssertEqual(links.count, 2, "pull to refresh reads again")
    }

    func testWhenNothingCanBeReadTheSectionsFailAndASavedCopyStaysAndSaysSo() async {
        let failing: [MockRoute] = ["/rest/v1/artifacts", "/api/connections", "/api/memories", "/api/conversations"].map {
            .failure(.get, $0, status: 400, message: "No.")
        }
        let routes = TaskBoardPreviewData.boardRoutes + failing
        let bare = ProjectOverviewModel(env: AppEnvironment.preview(routes: routes), project: project)
        await bare.start()
        XCTAssertEqual(bare.related, .failed(ProjectsCopy.couldntReadAll))

        let env = AppEnvironment.preview(routes: routes)
        await env.cache.store(
            ProjectRelated(pages: [ProjectRelatedItem(kind: .page, key: "saved", title: "Saved page", relation: .linked)]),
            key: "projects.related.\(project)", namespace: env.user.id
        )
        let model = ProjectOverviewModel(env: env, project: project)
        await model.start()
        XCTAssertTrue(model.relatedIsStale)
        guard case .loaded(let related) = model.related else { return XCTFail("The saved copy should stay.") }
        XCTAssertEqual(related.pages.map(\.title), ["Saved page"])
    }
}
