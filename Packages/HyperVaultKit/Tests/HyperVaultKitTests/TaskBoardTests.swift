import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

/// Fixtures follow docs/tasklists.md and what the routes in app/api/tasklists answer
/// (lib/tasklists/schema.ts normalises every task).
final class TaskBoardTests: XCTestCase {
    let base = URL(string: "https://hv.test")!

    func client(_ transport: MockTransport) -> HVClient {
        HVClient(baseURL: base, transport: transport, tokens: StaticTokenProvider(), retry: .none, sleep: { _ in })
    }

    static let listJSON = """
    {"$schema":"https://hypervault.store/schemas/tasklist-v1.json","schemaVersion":1,"id":"eurorack-choir",
     "title":"Eurorack Choir Module","version":42,"settings":{},"stages":["design","build"],
     "createdAt":"2026-10-20T09:00:00.000Z","updatedAt":"2026-10-25T21:30:00.000Z",
     "tasks":[
      {"id":"epic-hw","title":"Hardware","type":"epic","status":"in_progress","assignee":{"kind":"unassigned"},"parent":null,"children":["t-panels","t-psu"],
       "metadata":{"external_id":"x1"},"createdAt":"2026-10-20T09:00:00.000Z","updatedAt":"2026-10-25T21:30:00.000Z"},
      {"id":"t-panels","title":"Order panels","type":"task","status":"in_progress","priority":"high","activeForm":"Ordering the panels",
       "assignee":{"kind":"agent","name":"claude-code:pr-42","agentType":"claude-code"},"progress":60,"parent":"epic-hw",
       "lock":{"by":"claude-code:pr-42","agentType":"claude-code","at":"2026-10-25T21:00:00.000Z","expiresAt":"2026-10-25T22:00:00.000Z"},
       "notes":[{"id":"n-1","author":"johnny","authorKind":"human","body":"ship it small","createdAt":"2026-10-25T20:00:00.000Z"}]},
      {"id":"t-psu","title":"Pick a power supply","type":"task","status":"todo","assignee":{"kind":"unassigned"},"parent":"epic-hw"},
      {"id":"t-doc","title":"Write the manual","type":"task","status":"done","assignee":{"kind":"human","name":"johnny"},"completedAt":"2026-10-24T10:00:00.000Z"},
      {"id":"t-old","title":"Dropped idea","type":"task","status":"cancelled"},
      {"id":"t-block","title":"Wait for firmware","type":"task","status":"blocked","assignee":{"kind":"unassigned"}}
     ]}
    """

    func board() throws -> TaskBoard {
        try HVCoding.decoder(.verbatim).decode(TaskBoard.self, from: Data(Self.listJSON.utf8))
    }

    // MARK: Decoding

    func testTheBoardDecodes() throws {
        let board = try board()
        XCTAssertEqual(board.id, "eurorack-choir")
        XCTAssertEqual(board.version, 42)
        XCTAssertEqual(board.tasks.count, 6)
        let panels = try XCTUnwrap(board.task("t-panels"))
        XCTAssertEqual(panels.status, .inProgress)
        XCTAssertEqual(panels.priority, .high)
        XCTAssertEqual(panels.assignee.kind, .agent)
        XCTAssertTrue(panels.isClaimedByAgent)
        XCTAssertEqual(panels.holder, "claude-code:pr-42")
        XCTAssertEqual(panels.progress, 60)
        XCTAssertEqual(panels.notes.first?.body, "ship it small")
        XCTAssertNotNil(panels.lock?.expiresAt)
        XCTAssertEqual(board.task("t-doc")?.assignee.label, "johnny")
    }

    func testAnUnreadableTaskIsSkippedNotFatal() throws {
        let json = #"{"id":"p","title":"P","version":1,"tasks":[{"id":"ok","title":"Fine"},{"title":"No id"},"junk"]}"#
        let board = try HVCoding.decoder(.verbatim).decode(TaskBoard.self, from: Data(json.utf8))
        XCTAssertEqual(board.tasks.map(\.id), ["ok"])
    }

    func testUnknownStatusAndKindFallBackQuietly() throws {
        let json = #"{"id":"t","title":"T","status":"waiting","assignee":{"kind":"robot"}}"#
        let task = try HVCoding.decoder(.verbatim).decode(BoardTask.self, from: Data(json.utf8))
        XCTAssertEqual(task.status, .todo)
        XCTAssertEqual(task.assignee.kind, .unassigned)
        XCTAssertNil(task.assignee.label)
    }

    func testTheCacheRoundTrips() throws {
        let original = try board()
        let data = try HVCoding.encoder(.verbatim).encode(original)
        let back = try HVCoding.decoder(.verbatim).decode(TaskBoard.self, from: data)
        XCTAssertEqual(back, original)
    }

    func testTheListingOfBoards() throws {
        let json = """
        {"boards":[{"slug":"tasks-eurorack-choir","project":"eurorack-choir","title":"Tasks — Eurorack Choir Module",
         "url":"https://hypervault.store/a/tasks-eurorack-choir","created_at":"2026-10-20T09:00:00.000Z","updated_at":null}],
         "schema":"https://hypervault.store/schemas/tasklist-v1.json"}
        """
        let index = try HVCoding.decoder().decode(TaskBoardIndex.self, from: Data(json.utf8))
        XCTAssertEqual(index.boards.count, 1)
        XCTAssertEqual(index.boards[0].project, "eurorack-choir")
        XCTAssertEqual(index.boards[0].displayTitle, "Eurorack Choir Module")
        XCTAssertNotNil(index.boards[0].createdAt)
        XCTAssertNil(index.boards[0].updatedAt)
    }

    // MARK: Summary

    func testTheSummaryMatchesTheServersRollup() throws {
        let summary = TaskBoardSummary.compute(try board())
        XCTAssertEqual(summary.total, 6)
        XCTAssertEqual(summary.count(.inProgress), 2)
        XCTAssertEqual(summary.count(.cancelled), 1)
        // done 1 of 5 countable
        XCTAssertEqual(summary.progress, 20)
        XCTAssertEqual(summary.epics.map(\.id), ["epic-hw"])
        XCTAssertEqual(summary.epics[0].total, 2)
        XCTAssertEqual(summary.epics[0].done, 0)
        XCTAssertEqual(summary.claimed.map(\.taskId), ["t-panels"])
        // todo or blocked and unassigned: t-psu, t-block
        XCTAssertEqual(summary.unassigned, 2)
    }

    func testTheSummaryEndpointKeepsStatusKeys() async throws {
        let json = """
        {"slug":"tasks-eurorack-choir","summary":{"id":"eurorack-choir","title":"Eurorack Choir Module","version":42,"total":6,
         "byStatus":{"todo":1,"in_progress":2,"blocked":1,"review":0,"done":1,"cancelled":1},"progress":20,
         "epics":[{"id":"epic-hw","title":"Hardware","total":2,"done":0,"progress":0}],
         "claimed":[{"taskId":"t-panels","by":"claude-code:pr-42","agentType":"claude-code"}],"unassigned":2,"updatedAt":"2026-10-25T21:30:00.000Z"}}
        """
        let transport = MockTransport(routes: [.json(.get, "/api/tasklists/eurorack-choir/summary", json)])
        let response = try await client(transport).send(.taskBoardSummary(project: "eurorack-choir"))
        XCTAssertEqual(response.summary.count(.inProgress), 2)
        XCTAssertEqual(response.summary.claimed.first?.by, "claude-code:pr-42")
        XCTAssertEqual(response.summary.done, 1)
    }

    // MARK: Fetching

    func testThePollSaysUnchanged() async throws {
        let transport = MockTransport(routes: [.json(.get, "/api/tasklists/eurorack-choir", #"{"unchanged":true,"version":42}"#)])
        let fetch = try await client(transport).send(.taskBoard(project: "eurorack-choir", sinceVersion: 42))
        XCTAssertTrue(fetch.unchanged)
        XCTAssertNil(fetch.board)
        let requests = await transport.requests
        XCTAssertEqual(requests[0].url?.query, "since_version=42")
    }

    func testTheFullListComesWithItsSlug() async throws {
        let transport = MockTransport(routes: [.json(.get, "/api/tasklists/eurorack-choir", #"{"slug":"tasks-eurorack-choir","tasklist":\#(Self.listJSON)}"#)])
        let fetch = try await client(transport).send(.taskBoard(project: "eurorack-choir"))
        XCTAssertEqual(fetch.board?.version, 42)
        XCTAssertEqual(fetch.slug, "tasks-eurorack-choir")
    }

    // MARK: Creating

    func testADraftBecomesARequest() throws {
        let draft = TaskBoardDraft(title: "  Garden  ", plan: "- Buy seeds\n\n[ ] Dig the bed\n  Water   \n* ")
        XCTAssertTrue(draft.canCreate)
        XCTAssertEqual(draft.firstTasks, ["Buy seeds", "Dig the bed", "Water"])
        let body = draft.requestBody
        XCTAssertEqual(body["title"], "Garden")
        XCTAssertEqual(body["visibility"], "private")
        XCTAssertEqual(body["tasks"]?.array?.count, 3)
        XCTAssertEqual(body["tasks"]?[0]?["title"], "Buy seeds")
        XCTAssertFalse(TaskBoardDraft(title: "   ").canCreate)
        XCTAssertNil(TaskBoardDraft(title: "Just a name").requestBody["tasks"])
    }

    func testCreatingABoard() async throws {
        let json = #"{"project":"garden","data":{"slug":"tasks-garden","url":"https://hv.test/a/tasks-garden"},"board":{"slug":"taskboard-garden","url":"https://hv.test/a/taskboard-garden"},"version":0,"taskCount":2,"schema":"x","message":"Task board is live."}"#
        let transport = MockTransport(routes: [.json(.post, "/api/taskboards", json)])
        let created = try await client(transport).send(.createTaskBoard(TaskBoardDraft(title: "Garden", plan: "a\nb")))
        XCTAssertEqual(created.project, "garden")
        XCTAssertEqual(created.taskCount, 2)
        let requests = await transport.requests
        let body = try HVCoding.decoder(.verbatim).decode(JSONValue.self, from: try XCTUnwrap(requests[0].httpBody))
        XCTAssertEqual(body["title"], "Garden")
    }

    // MARK: Status

    func testTheTapCyclesTowardDone() {
        XCTAssertEqual(BoardTaskStatus.todo.cycled, .inProgress)
        XCTAssertEqual(BoardTaskStatus.inProgress.cycled, .done)
        XCTAssertEqual(BoardTaskStatus.review.cycled, .done)
        XCTAssertEqual(BoardTaskStatus.blocked.cycled, .inProgress)
        XCTAssertEqual(BoardTaskStatus.done.cycled, .todo)
        XCTAssertEqual(BoardTaskStatus.cancelled.cycled, .todo)
        XCTAssertEqual(BoardTaskStatus.inProgress.rawValue, "in_progress")
    }

    // MARK: Grouping

    func testGroupsListWhatNeedsAttentionFirst() throws {
        let groups = try board().groups()
        XCTAssertEqual(groups.map(\.status), [.inProgress, .blocked, .todo, .done, .cancelled])
        let inProgress = groups[0].rows
        // the epic, then its subtask nested under it
        XCTAssertEqual(inProgress.map(\.task.id), ["epic-hw", "t-panels"])
        XCTAssertEqual(inProgress.map(\.depth), [0, 1])
        // a subtask in another group stands alone and says where it came from
        let todo = groups[2].rows
        XCTAssertEqual(todo.map(\.task.id), ["t-psu"])
        XCTAssertEqual(todo[0].depth, 0)
        XCTAssertEqual(todo[0].parentTitle, "Hardware")
    }

    func testFiltersNarrowTheGroups() throws {
        let board = try board()
        XCTAssertEqual(board.groups(filter: .done).flatMap(\.rows).map(\.task.id), ["t-doc"])
        XCTAssertEqual(board.groups(filter: .agents).flatMap(\.rows).map(\.task.id), ["t-panels"])
        XCTAssertEqual(board.groups(filter: .people).flatMap(\.rows).map(\.task.id), ["t-doc"])
        XCTAssertFalse(board.groups(filter: .open).contains { $0.status == .done || $0.status == .cancelled })
    }

    func testRollupAndProgress() throws {
        let board = try board()
        let rollup = try XCTUnwrap(board.rollup(of: "epic-hw"))
        XCTAssertEqual(rollup.total, 2)
        XCTAssertEqual(rollup.done, 0)
        XCTAssertNil(board.rollup(of: "t-doc"))
        XCTAssertEqual(board.progress.done, 1)
        XCTAssertEqual(board.progress.total, 5)
    }

    // MARK: Edits on the phone

    func testStatusAppliesLocally() throws {
        let done = TaskBoardEdit.setStatus(taskID: "t-panels", to: .done).applying(to: try board())
        let task = try XCTUnwrap(done.task("t-panels"))
        XCTAssertEqual(task.status, .done)
        XCTAssertEqual(task.progress, 100)
        XCTAssertNil(task.lock)
        XCTAssertNotNil(task.completedAt)
        let reopened = TaskBoardEdit.setStatus(taskID: "t-doc", to: .todo).applying(to: done)
        XCTAssertNil(reopened.task("t-doc")?.completedAt)
        XCTAssertEqual(done.version, 42, "the version is the server's to bump")
    }

    func testAddingASubtaskLinksItToItsParent() throws {
        let added = TaskBoardEdit.add(title: "Cut the panel", parent: "t-panels", tempID: "tmp-1").applying(to: try board())
        XCTAssertEqual(added.task("tmp-1")?.parent, "t-panels")
        XCTAssertEqual(added.task("t-panels")?.children, ["tmp-1"])
        XCTAssertEqual(added.subtasks(of: "t-panels").count, 1)
    }

    func testClaimingAndReleasing() throws {
        let claimed = TaskBoardEdit.claim(taskID: "t-psu", force: false).applying(to: try board(), me: "Johnny")
        XCTAssertEqual(claimed.task("t-psu")?.status, .inProgress)
        XCTAssertEqual(claimed.task("t-psu")?.holder, "Johnny")
        XCTAssertTrue(claimed.task("t-psu")?.assignee.isHuman ?? false)
        let released = TaskBoardEdit.release(taskID: "t-psu").applying(to: claimed)
        XCTAssertEqual(released.task("t-psu")?.status, .todo)
        XCTAssertNil(released.task("t-psu")?.lock)
        // a blocked task stays blocked when claimed
        let blocked = TaskBoardEdit.claim(taskID: "t-block", force: false).applying(to: try board())
        XCTAssertEqual(blocked.task("t-block")?.status, .blocked)
    }

    func testNotesAndProgress() throws {
        let board = try board()
        let noted = TaskBoardEdit.addNote(taskID: "t-psu", text: "Check the 12V rail").applying(to: board, me: "Johnny")
        XCTAssertEqual(noted.task("t-psu")?.notes.last?.body, "Check the 12V rail")
        XCTAssertEqual(noted.task("t-psu")?.notes.last?.author, "Johnny")
        XCTAssertEqual(TaskBoardEdit.setProgress(taskID: "t-psu", to: 140).applying(to: board).task("t-psu")?.progress, 100)
    }

    // MARK: Requests

    func bodyOf(_ request: URLRequest) throws -> JSONValue {
        try HVCoding.decoder(.verbatim).decode(JSONValue.self, from: try XCTUnwrap(request.httpBody))
    }

    func testEditsGoToTheRightRoutesWithTheirPin() async throws {
        let answer = #"{"task":{"id":"t-psu","title":"Pick a power supply","status":"in_progress"},"tasklist":\#(Self.listJSON),"commit":null,"message":"ok"}"#
        let transport = MockTransport(routes: [
            .json(.patch, "/api/tasklists/eurorack-choir/tasks/t-psu", answer),
            .json(.post, "/api/tasklists/eurorack-choir/tasks", answer),
            .json(.post, "/api/tasklists/eurorack-choir/tasks/t-psu/claim", answer),
            .json(.post, "/api/tasklists/eurorack-choir/tasks/t-psu/complete", #"{"task":{"id":"t-psu","title":"x","status":"done"},"summary":{"id":"eurorack-choir","title":"E","version":43,"total":6,"byStatus":{"done":2},"progress":40},"message":"done"}"#),
        ])
        let api = client(transport)
        _ = try await api.send(TaskBoardEdit.setStatus(taskID: "t-psu", to: .inProgress).endpoint(project: "eurorack-choir", expectedVersion: 42))
        _ = try await api.send(TaskBoardEdit.add(title: "Sketch", parent: "epic-hw", tempID: "tmp").endpoint(project: "eurorack-choir", expectedVersion: 42))
        _ = try await api.send(TaskBoardEdit.claim(taskID: "t-psu", force: true).endpoint(project: "eurorack-choir", expectedVersion: nil))
        _ = try await api.send(TaskBoardEdit.release(taskID: "t-psu").endpoint(project: "eurorack-choir", expectedVersion: 42))
        let completed = try await api.send(TaskBoardEdit.complete(taskID: "t-psu", note: "Shipped").endpoint(project: "eurorack-choir", expectedVersion: 42))
        XCTAssertNil(completed.board, "completing answers a summary, not the list")
        XCTAssertEqual(completed.summary?.progress, 40)

        let sent = await transport.requests
        XCTAssertEqual(sent.map(\.httpMethod), ["PATCH", "POST", "POST", "POST", "POST"])
        let patch = try bodyOf(sent[0])
        XCTAssertEqual(patch["expected_version"], 42)
        XCTAssertEqual(patch["patch"]?["status"], "in_progress")
        let add = try bodyOf(sent[1])
        XCTAssertEqual(add["task"]?["title"], "Sketch")
        XCTAssertEqual(add["task"]?["parent"], "epic-hw")
        let claim = try bodyOf(sent[2])
        XCTAssertEqual(claim["force"], true)
        XCTAssertNil(claim["expected_version"])
        let release = try bodyOf(sent[3])
        XCTAssertEqual(release["release"], true)
        let complete = try bodyOf(sent[4])
        XCTAssertEqual(complete["note"], "Shipped")
    }

    func testClearingAPriorityIsAnExplicitNull() throws {
        let endpoint = TaskBoardEdit.setPriority(taskID: "t", to: nil).endpoint(project: "p", expectedVersion: 1)
        guard case .jsonValue(let body) = endpoint.body else { return XCTFail("expected a JSON body") }
        XCTAssertEqual(body["patch"]?["priority"], JSONValue.null)
    }

    // MARK: Conflicts

    func conflictBody(latest: String) -> String {
        #"{"error":"Version conflict — the list is at revision 43, not the one you read. The latest state is attached.","conflict":true,"latest":\#(latest)}"#
    }

    func testAConflictCarriesTheLatestList() async throws {
        var latest = try board()
        latest.version = 43
        let latestJSON = String(decoding: try HVCoding.encoder(.verbatim).encode(latest), as: UTF8.self)
        let transport = MockTransport(routes: [.json(.patch, "/api/tasklists/eurorack-choir/tasks/t-psu", conflictBody(latest: latestJSON), status: 409)])
        do {
            _ = try await client(transport).send(TaskBoardEdit.setStatus(taskID: "t-psu", to: .done).endpoint(project: "eurorack-choir", expectedVersion: 42))
            XCTFail("expected a conflict")
        } catch {
            let found = try XCTUnwrap(TaskBoardConflict.latest(in: error))
            XCTAssertEqual(found.version, 43)
            XCTAssertEqual(found.tasks.count, 6)
        }
    }

    func testAClaimConflictIsNotAListConflict() async {
        let transport = MockTransport(routes: [.json(.post, "/api/tasklists/p/tasks/t/claim", #"{"error":"Task \"t\" is already claimed by claude-code:pr-42 (lock expires later). Pass force=true to take it over deliberately."}"#, status: 409)])
        do {
            _ = try await client(transport).send(TaskBoardEdit.claim(taskID: "t", force: false).endpoint(project: "p", expectedVersion: nil))
            XCTFail("expected a refusal")
        } catch {
            XCTAssertNil(TaskBoardConflict.latest(in: error))
            XCTAssertTrue((error as? HVError)?.boardSentence.contains("already claimed") ?? false)
        }
    }

    func testMergingOnTopOfWhatChanged() throws {
        let base = try board()
        var latest = base
        latest.version = 43
        // somebody started t-psu while we were thinking
        latest = TaskBoardEdit.setStatus(taskID: "t-psu", to: .inProgress).applying(to: latest)

        // we wanted it done: nobody else touched the thing we changed? They did (todo -> in progress)
        XCTAssertEqual(
            TaskBoardEdit.setStatus(taskID: "t-psu", to: .done).mergeDecision(base: base, latest: latest),
            .conflict("Someone moved it to in progress in the meantime.")
        )
        // the same move: nothing left to do
        XCTAssertEqual(TaskBoardEdit.setStatus(taskID: "t-psu", to: .inProgress).mergeDecision(base: base, latest: latest), .alreadyDone)
        // a different task entirely: send it again on top
        XCTAssertEqual(TaskBoardEdit.setStatus(taskID: "t-block", to: .todo).mergeDecision(base: base, latest: latest), .reapply)
        // a note never conflicts, an add never does either
        XCTAssertEqual(TaskBoardEdit.addNote(taskID: "t-psu", text: "hi").mergeDecision(base: base, latest: latest), .reapply)
        XCTAssertEqual(TaskBoardEdit.add(title: "x", parent: nil, tempID: "t").mergeDecision(base: base, latest: latest), .reapply)
        // a rename over someone's rename asks
        var renamed = base
        renamed = TaskBoardEdit.rename(taskID: "t-psu", to: "Pick a PSU").applying(to: renamed)
        XCTAssertEqual(
            TaskBoardEdit.rename(taskID: "t-psu", to: "Power supply").mergeDecision(base: base, latest: renamed),
            .conflict("Someone renamed it in the meantime.")
        )
    }

    func testClaimingWhatAnAgentTookInTheMeantime() throws {
        let base = try board()
        var latest = base
        latest = TaskBoardEdit.claim(taskID: "t-psu", force: false).applying(to: latest, me: "claude-code:pr-9")
        let now = Date()
        let decision = TaskBoardEdit.claim(taskID: "t-psu", force: false).mergeDecision(base: base, latest: latest, now: now)
        XCTAssertEqual(decision, .conflict("claude-code:pr-9 claimed it in the meantime."))
        XCTAssertEqual(TaskBoardEdit.claim(taskID: "t-psu", force: true).mergeDecision(base: base, latest: latest, now: now), .reapply)
        // a lock that ran out is free for the taking
        let later = now.addingTimeInterval(7200)
        XCTAssertEqual(TaskBoardEdit.claim(taskID: "t-psu", force: false).mergeDecision(base: base, latest: latest, now: later), .reapply)
    }

    func testAGoneTaskIsAConflict() throws {
        let base = try board()
        var latest = base
        latest.tasks.removeAll { $0.id == "t-psu" }
        XCTAssertEqual(TaskBoardEdit.setStatus(taskID: "t-psu", to: .done).mergeDecision(base: base, latest: latest), .conflict("That task is gone."))
        XCTAssertEqual(TaskBoardEdit.add(title: "x", parent: "t-psu", tempID: "t").mergeDecision(base: base, latest: latest), .conflict("The task you were adding under is gone."))
    }
}
