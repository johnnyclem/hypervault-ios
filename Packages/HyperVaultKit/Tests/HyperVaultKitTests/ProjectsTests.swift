import XCTest
@testable import HyperVaultKit

/// The Projects tab's logic: how boards are ordered and grouped, which open tasks the overview puts first, and which pages,
/// memories and chats it can honestly say belong beside a project (and why).
final class ProjectsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    private func listing(_ project: String, title: String? = nil, created: Double = 100, updated: Double? = nil) -> TaskBoardListing {
        TaskBoardListing(
            slug: "tasks-\(project)", project: project, title: "Tasks \u{2014} \(title ?? project)",
            createdAt: ago(created), updatedAt: updated.map(ago)
        )
    }

    // MARK: Listing

    func testTheBoardPageAndTheLastMoveComeFromTheListing() {
        let board = listing("eurorack-choir", created: 30, updated: 2)
        XCTAssertEqual(board.boardPageSlug, "taskboard-eurorack-choir")
        XCTAssertEqual(board.lastActivity, ago(2))
        XCTAssertEqual(listing("garden", created: 30).lastActivity, ago(30), "a board nobody has written to has only its making")
    }

    // MARK: Grouping

    func testBoardsAreOrderedByWhenTheyLastMovedAndTiesKeepTheServersOrder() {
        let boards = [
            listing("made-last", created: 1),
            listing("moved-today", created: 90, updated: 0.1),
            listing("tie-a", created: 40),
            listing("tie-b", created: 40),
        ]
        XCTAssertEqual(ProjectGrouping.ordered(boards).map(\.project), ["moved-today", "made-last", "tie-a", "tie-b"])
        let undated = TaskBoardListing(slug: "tasks-x", project: "x", title: "x")
        XCTAssertEqual(ProjectGrouping.ordered([undated, listing("dated")]).map(\.project), ["dated", "x"], "no dates at all goes last")
    }

    func testAFewProjectsAreOneListWithNoHeading() {
        let groups = ProjectGrouping.groups((0..<7).map { listing("p\($0)", created: Double($0) * 40) }, now: now)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].section, .all)
        XCTAssertNil(groups[0].title)
        XCTAssertTrue(ProjectGrouping.groups([], now: now).isEmpty)
    }

    func testManyProjectsSplitIntoRecentAndEarlier() {
        let boards = (0..<10).map { listing("p\($0)", created: Double($0) * 5) }   // 0, 5, 10 days old recent; the rest earlier
        let groups = ProjectGrouping.groups(boards, now: now)
        XCTAssertEqual(groups.map(\.section), [.recent, .earlier])
        XCTAssertEqual(groups.map(\.title), ["Recent", "Earlier"])
        XCTAssertEqual(groups[0].boards.map(\.project), ["p0", "p1", "p2"])
        XCTAssertEqual(groups[1].boards.count, 7)
    }

    func testAListWithNothingRecentOrNothingOlderHasNoHeadings() {
        let allOld = ProjectGrouping.groups((0..<9).map { listing("o\($0)", created: 100 + Double($0)) }, now: now)
        XCTAssertEqual(allOld.map(\.section), [.all])
        let allNew = ProjectGrouping.groups((0..<9).map { listing("n\($0)", created: Double($0)) }, now: now)
        XCTAssertEqual(allNew.map(\.section), [.all])
    }

    // MARK: The board's digest

    private func task(
        _ id: String, _ status: BoardTaskStatus, parent: String? = nil, updated: Double? = nil,
        assignee: BoardAssignee = .unassigned, lock: BoardLock? = nil
    ) -> BoardTask {
        BoardTask(id: id, title: "Task \(id)", status: status, assignee: assignee, parent: parent, lock: lock, updatedAt: updated.map(ago))
    }

    func testTheDigestLeadsWithWhatNeedsAnEyeAndLeavesEpicsToTheirSubtasks() {
        let board = TaskBoard(id: "p", title: "P", tasks: [
            task("epic", .inProgress),
            task("a", .todo, parent: "epic", updated: 1),
            task("b", .inProgress, parent: "epic", updated: 5),
            task("c", .blocked, updated: 2),
            task("d", .done, updated: 0),
            task("e", .inProgress, updated: 1),
            task("f", .cancelled),
            task("g", .review),
            task("h", .todo, updated: 9),
        ])
        let digest = ProjectBoardDigest(board: board)
        XCTAssertEqual(digest.focus.map(\.id), ["e", "b", "c", "g", "a"], "in progress (newest first), blocked, review, then to do; the epic itself and finished work are left out")
        XCTAssertEqual(digest.focus.count, ProjectBoardDigest.focusLimit)
        XCTAssertEqual(digest.summary.total, 9)
        XCTAssertEqual(digest.summary.done, 1)
    }

    func testTheStatusLineSaysHowFarAlongAndWhatIsMovingOrStuck() {
        XCTAssertEqual(ProjectBoardDigest(board: TaskBoard(id: "p", title: "P")).statusLine, "Nothing on it yet")
        let board = TaskBoard(id: "p", title: "P", tasks: [
            task("a", .done), task("b", .inProgress), task("c", .inProgress), task("d", .blocked), task("e", .todo), task("f", .cancelled),
        ])
        XCTAssertEqual(ProjectBoardDigest(board: board).statusLine, "1 of 5 done \u{00B7} 2 in progress \u{00B7} 1 blocked")
        let quiet = TaskBoard(id: "p", title: "P", tasks: [task("a", .done), task("b", .todo)])
        XCTAssertEqual(ProjectBoardDigest(board: quiet).statusLine, "1 of 2 done")
        let setAside = TaskBoard(id: "p", title: "P", tasks: [task("a", .cancelled)])
        XCTAssertEqual(ProjectBoardDigest(board: setAside).statusLine, "Everything was set aside")
    }

    func testTheDigestNamesWhoIsHoldingOpenWork() {
        let claude = BoardAssignee(kind: .agent, name: "Claude Code")
        let board = TaskBoard(id: "p", title: "P", tasks: [
            task("1", .inProgress, assignee: claude),
            task("2", .todo, assignee: claude),
            task("3", .inProgress, lock: BoardLock(by: "gemini:run-4")),
            task("4", .done, assignee: BoardAssignee(kind: .agent, name: "Old agent")),
            task("5", .todo, assignee: BoardAssignee(kind: .human, name: "sam")),
        ])
        let agents = ProjectBoardDigest(board: board).agents
        XCTAssertEqual(agents, [ProjectAgent(name: "Claude Code", tasks: 2), ProjectAgent(name: "gemini:run-4", tasks: 1)])
        XCTAssertTrue(ProjectBoardDigest(board: TaskBoard(id: "p", title: "P")).agents.isEmpty)
        XCTAssertTrue(ProjectBoardDigest(board: TaskBoard(id: "p", title: "P")).focus.isEmpty)
    }

    // MARK: Names

    func testANameMatchesWholeWordsOfTheTitleOrTheId() {
        let matcher = ProjectNameMatcher(project: "eurorack-choir", title: "Eurorack Choir Module")
        XCTAssertTrue(matcher.matches("Eurorack Choir Module: front panels"), "the whole title")
        XCTAssertTrue(matcher.matches("Notes on the eurorack choir"), "the id as words")
        XCTAssertTrue(matcher.matches("Choir module power budget"), "two of the title's own words")
        XCTAssertFalse(matcher.matches("Choir rehearsal on Thursday"), "one word of three is not enough")
        XCTAssertFalse(matcher.matches("Eurorack"), "nor is the other one")
        XCTAssertFalse(matcher.matches(""))
    }

    func testAMatchIsAWholeWordNotAFragment() {
        let matcher = ProjectNameMatcher(project: "art", title: "Art")
        XCTAssertTrue(matcher.matches("Art show plans"))
        XCTAssertFalse(matcher.matches("Party planning"), "\"art\" inside \"party\" is not the project")
        XCTAssertFalse(matcher.matches("Smart home"))
    }

    func testAOneWordProjectMatchesThatWordAndTheGenericWordsOfABoardAreIgnored() {
        let garden = ProjectNameMatcher(project: "garden", title: "Spring garden")
        XCTAssertTrue(garden.matches("Garden irrigation plan"), "the id \"garden\" is a name in itself")
        XCTAssertTrue(garden.matches("Spring garden beds"))
        XCTAssertFalse(garden.matches("Spring break trip"))
        let boards = ProjectNameMatcher(project: "launch", title: "Launch task board")
        XCTAssertFalse(boards.matches("My task board ideas"), "\"task\" and \"board\" are on every board and name no project")
        XCTAssertTrue(boards.matches("Launch checklist"))
    }

    func testTheRandomEndingAnAppMadeIdCarriesIsNotPartOfItsName() {
        let matcher = ProjectNameMatcher(project: "balcony-garden-k3x9a2", title: "Balcony garden")
        XCTAssertTrue(matcher.matches("Balcony garden: pots"))
        XCTAssertTrue(matcher.phrases.contains(["balcony", "garden"]))
        // A plain six-letter last word is a word, not a suffix.
        let spring = ProjectNameMatcher(project: "spring-garden", title: "Yard")
        XCTAssertTrue(spring.phrases.contains(["spring", "garden"]))
        XCTAssertTrue(spring.matches("Spring garden plan"))
    }

    // MARK: What else belongs

    private let board = "board-row"
    private let data = "data-row"

    private func page(_ id: String, _ title: String, tags: [String] = [], type: String = "html") -> LibraryGraphPage {
        LibraryGraphPage(id: id, slug: "slug-\(id)", title: title, type: type, tags: tags)
    }

    private func memory(_ id: String, _ title: String, tags: [String] = [], source: String = "manual", created: Double = 5) -> MemoryItem {
        MemoryItem(id: id, title: title, tags: tags, source: source, createdAt: ago(created))
    }

    private func input(
        pages: [LibraryGraphPage] = [], memories: [MemoryItem] = [],
        conversations: [ChatConversation] = [], page links: [ArtifactEdge] = [], bridges: [MemoryBridgeRow] = []
    ) -> ProjectRelatedInput {
        ProjectRelatedInput(
            project: "eurorack-choir", title: "Eurorack Choir Module", anchors: [board, data],
            connections: LibraryConnections(pageLinks: links, memoryLinks: [], bridges: bridges),
            pages: pages, memories: memories, conversations: conversations
        )
    }

    private func chat(_ id: String, _ title: String, platform: String = "hypervault", updated: Double = 1) -> ChatConversation {
        ChatConversation(id: id, title: title, sourcePlatform: platform, updatedAt: ago(updated))
    }

    func testPagesJoinedToTheBoardPageAreLinkedByHandOrPossiblyRelatedAndTheBoardsOwnPagesAreNeverListed() {
        let related = build(input(
            pages: [
                page("p1", "Panel drawings"), page("p2", "Wiring notes"), page("p3", "Unrelated"),
                page(board, "Eurorack Choir Module \u{2014} Task Board", tags: ["taskboard", "eurorack-choir"]),
            ],
            page: [
                ArtifactEdge(id: "e1", aId: "p1", bId: board, kind: "manual"),
                ArtifactEdge(id: "e2", aId: board, bId: "p2", kind: "auto"),
                ArtifactEdge(id: "e3", aId: board, bId: data, kind: "manual"),   // the pair the server makes
                ArtifactEdge(id: "e4", aId: "p3", bId: "p1", kind: "manual"),    // not touching the board
            ]
        ))
        XCTAssertEqual(related.pages.map(\.key), ["slug-p1"])
        XCTAssertEqual(related.pages.map(\.relation), [.linked])
        XCTAssertEqual(related.pageTotal, 1)
        XCTAssertEqual(related.possibly.map(\.key), ["slug-p2"], "the server's guess is kept apart, not listed with the pages")
        XCTAssertEqual(related.possibly.map(\.relation), [.related])
        XCTAssertEqual(related.possiblyTotal, 1)
    }

    func testAnotherBoardsPageJoinedByTheServersGuessIsNoiseButOneJoinedByHandIsKept() {
        let related = build(input(
            pages: [
                page("other-auto", "Garden \u{2014} Task Board", tags: ["taskboard", "garden"]),
                page("other-hand", "Choir budget \u{2014} Task Board", tags: ["taskboard", "choir-budget"]),
            ],
            page: [
                ArtifactEdge(id: "e1", aId: board, bId: "other-auto", kind: "auto"),
                ArtifactEdge(id: "e2", aId: board, bId: "other-hand", kind: "manual"),
            ]
        ))
        XCTAssertEqual(related.pages.map(\.key), ["slug-other-hand"])
    }

    func testAPageTaggedWithTheProjectIsListedAndTheStrongerReasonWins() {
        let related = build(input(
            pages: [page("p1", "Panel drawings", tags: ["Eurorack-Choir"]), page("p2", "Tagged only", tags: ["eurorack-choir"]), page("p3", "Other", tags: ["choir"])],
            page: [ArtifactEdge(id: "e1", aId: "p1", bId: board, kind: "auto")]
        ))
        XCTAssertEqual(related.pages.map(\.key), ["slug-p1", "slug-p2"], "tagged beats a guess; p1 is both, and is listed once")
        XCTAssertEqual(Set(related.pages.map(\.relation)), [.tagged])
        XCTAssertEqual(related.pages.count, 2, "one row for a page that is both tagged and joined")
        XCTAssertTrue(related.possibly.isEmpty, "a page that is also tagged is not a guess")
    }

    func testMemoriesComeFromBridgesTagsAndTheirTitlesButNeverFromAChatsOwnMirror() {
        let related = build(input(
            memories: [
                memory("m1", "Power budget", created: 3),
                memory("m2", "Tagged note", tags: ["eurorack-choir"], created: 2),
                memory("m3", "Guessed", created: 1),
                memory("m4", "Eurorack choir wiring", created: 9),
                memory("mirror", "Chat: Choir module power budget", source: "chat"),
                memory("m5", "Dinner ideas"),
            ],
            bridges: [
                MemoryBridgeRow(id: "b1", memoryId: "m1", artifactId: board, kind: .manual),
                MemoryBridgeRow(id: "b2", memoryId: "m3", artifactId: board, kind: .auto),
                MemoryBridgeRow(id: "b3", memoryId: "mirror", artifactId: board, kind: .auto),
                MemoryBridgeRow(id: "b4", memoryId: "gone", artifactId: board, kind: .manual),
                MemoryBridgeRow(id: "b5", memoryId: "m5", artifactId: "some-other-page", kind: .manual),
            ]
        ))
        XCTAssertEqual(related.memories.map(\.key), ["m1", "m2", "m4"])
        XCTAssertEqual(related.memories.map(\.relation), [.linked, .tagged, .mentions])
        XCTAssertEqual(related.memories.first?.detail, "You")
        XCTAssertEqual(related.possibly.map(\.key), ["m3"], "a bridge the server guessed at waits behind \"Show possibly related\"")
    }

    func testChatsAreFoundByNameAndOnlyByName() {
        let related = build(input(conversations: [
            chat("c1", "Choir module power budget", updated: 2),
            chat("c2", "Eurorack Choir Module: front panel quotes", updated: 1),
            chat("c3", "Dinner ideas"),
            chat("c4", "Eurorack choir notes", platform: "chatgpt", updated: 8),
        ]))
        XCTAssertEqual(related.chats.map(\.key), ["c2", "c1", "c4"], "the newest first")
        XCTAssertEqual(Set(related.chats.map(\.relation)), [.mentions])
        XCTAssertEqual(related.chats.last?.detail, "ChatGPT")
    }

    func testEachSectionKeepsTheMostItCanAndCountsWhatItDidNotKeep() {
        let many = (0..<45).map { page("p\($0)", "Page \($0)", tags: ["eurorack-choir"]) }
        let related = build(input(pages: many))
        XCTAssertEqual(related.pages.count, ProjectRelatedBuilder.sectionLimit)
        XCTAssertEqual(related.pageTotal, 45)
        XCTAssertEqual(ProjectsCopy.seeAll(related.pageTotal - related.pages.count), "See 5 more in the Library")
        XCTAssertEqual(ProjectsCopy.seeAll(1), "See 1 more in the Library")
    }

    func testAScreenShowsTheFirstFewRowsUntilTheSectionIsOpenedOut() {
        let rows = (0..<9).map { ProjectRelatedItem(kind: .page, key: "p\($0)", title: "Page \($0)", relation: .tagged) }
        XCTAssertEqual(ProjectRelated.shown(rows, opened: false).map(\.key), ["p0", "p1", "p2", "p3", "p4", "p5"])
        XCTAssertEqual(ProjectRelated.shown(rows, opened: true).count, 9)
        XCTAssertEqual(ProjectRelated.shown(Array(rows.prefix(2)), opened: false).count, 2)
        XCTAssertEqual(ProjectsCopy.showMore(rows.count - ProjectRelated.visibleLimit), "Show 3 more")
        XCTAssertEqual(ProjectsCopy.showMore(1), "Show 1 more")
    }

    func testNothingFoundIsEmptyAndTheResultSurvivesTheCache() throws {
        XCTAssertTrue(build(input()).isEmpty)
        let related = build(input(
            memories: [memory("m1", "Power budget")],
            bridges: [MemoryBridgeRow(id: "b1", memoryId: "m1", artifactId: board, kind: .manual)]
        ))
        let data = try HVCoding.encoder(.verbatim).encode(related)
        XCTAssertEqual(try HVCoding.decoder(.verbatim).decode(ProjectRelated.self, from: data), related)
        let guessed = build(input(pages: [page("p1", "Panel drawings")], page: [ArtifactEdge(id: "e1", aId: board, bId: "p1", kind: "auto")]))
        let again = try HVCoding.decoder(.verbatim).decode(ProjectRelated.self, from: HVCoding.encoder(.verbatim).encode(guessed))
        XCTAssertEqual(again, guessed)
        XCTAssertEqual(again.possibly.map(\.key), ["slug-p1"])
    }

    func testGuessesArePagesAndMemoriesNewestFirstAndNeverCrowdOutTheSections() {
        let guessedPages = (0..<4).map { page("g\($0)", "Guess \($0)") }
        let guessedMemories = (0..<4).map { memory("gm\($0)", "Guessed memory \($0)", created: Double($0) + 1) }
        let edges = guessedPages.map { ArtifactEdge(id: "e-\($0.id)", aId: board, bId: $0.id, kind: "auto") }
        let bridges = guessedMemories.map { MemoryBridgeRow(id: "b-\($0.id)", memoryId: $0.id, artifactId: board, kind: .auto) }
        let related = build(input(
            pages: guessedPages + [page("t1", "Tagged page", tags: ["eurorack-choir"])],
            memories: guessedMemories + [memory("m9", "Eurorack choir wiring", created: 30)],
            page: edges, bridges: bridges
        ))
        XCTAssertEqual(related.pages.map(\.key), ["slug-t1"])
        XCTAssertEqual(related.memories.map(\.key), ["m9"], "a guess does not take the place of a name match")
        XCTAssertEqual(related.possiblyTotal, 8)
        XCTAssertEqual(related.possibly.count, 8, "kept on their own")
        XCTAssertEqual(related.possibly.first?.key, "gm0", "memories carry a date and come before pages, which have none")
        XCTAssertEqual(related.possibly.prefix(4).map(\.kind), [.memory, .memory, .memory, .memory])
        XCTAssertEqual(related.confirmedTotal, 2)
        XCTAssertFalse(related.isEmpty)
    }

    func testOnlyGuessesIsNotEmptyButHasNothingConfirmed() {
        let related = build(input(pages: [page("p1", "Panel drawings")], page: [ArtifactEdge(id: "e1", aId: board, bId: "p1", kind: "auto")]))
        XCTAssertEqual(related.confirmedTotal, 0)
        XCTAssertEqual(related.possiblyTotal, 1)
        XCTAssertFalse(related.isEmpty)
        XCTAssertTrue(ProjectRelated.empty.isEmpty)
    }

    private func build(_ input: ProjectRelatedInput) -> ProjectRelated { ProjectRelatedBuilder.build(input) }
}
