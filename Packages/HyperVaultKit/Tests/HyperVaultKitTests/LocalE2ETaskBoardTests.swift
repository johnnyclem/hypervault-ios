import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

// Task boards: create one, read it three ways, make every edit the app makes and compare the server's board with
// the one the Kit predicts from the edit, then a stale write (409), the merge decision and an agent's claim.

final class LocalE2ETaskBoardTests: LocalE2ECase {

    private func newBoard(_ api: HVClient, _ title: String = "Choir") async throws -> (project: String, board: TaskBoard, created: CreatedTaskBoard) {
        let word = uniqueWord()
        let draft = TaskBoardDraft(title: "\(title) \(word)", plan: "Write the score\nRecord the parts\nMix it")
        XCTAssertTrue(draft.canCreate)
        let created = try await send(.createTaskBoard(draft), api)
        let fetched = try await send(.taskBoard(project: created.project), api)
        return (created.project, try XCTUnwrap(fetched.board), created)
    }

    func testCreateAListAndReadABoardThreeWays() async throws {
        let (api, _) = member(22)
        let draft = TaskBoardDraft(title: "Choir \(uniqueWord())", plan: "Write the score\nRecord the parts\n\nMix it")
        XCTAssertEqual(draft.firstTasks, ["Write the score", "Record the parts", "Mix it"])
        let (created, createdRaw) = try await fetch(.createTaskBoard(draft), api)
        XCTAssertEqual(created.project, createdRaw["project"]?.string)
        XCTAssertEqual(created.taskCount, 3)
        XCTAssertGreaterThanOrEqual(created.version, 0)
        XCTAssertTrue(created.board.url.contains(created.board.slug), created.board.url)
        XCTAssertTrue(created.data.slug.hasPrefix("tasks-"), created.data.slug)

        // The index lists it with both slugs.
        let (index, indexRaw) = try await fetch(.taskBoards, api)
        XCTAssertEqual(index.boards.count, rawCount(indexRaw, "boards"))
        let listing = try XCTUnwrap(index.boards.first { $0.project == created.project })
        XCTAssertEqual(listing.displayTitle, draft.trimmedTitle, "the data page is titled \"Tasks — …\": \(listing.title)")
        XCTAssertNotNil(listing.createdAt)
        XCTAssertFalse(listing.displayTitle.isEmpty)
        XCTAssertEqual(index.boards.first?.project, created.project, "newest first")

        // The whole list, then the cheap poll: unchanged at the version it was read at.
        let (fetched, raw) = try await fetch(.taskBoard(project: created.project), api)
        let board = try XCTUnwrap(fetched.board)
        XCTAssertEqual(board.id, created.project)
        XCTAssertEqual(board.title, draft.trimmedTitle)
        XCTAssertEqual(board.title, listing.displayTitle)
        XCTAssertEqual(board.tasks.count, 3)
        XCTAssertEqual(board.tasks.count, raw["tasklist"]?["tasks"]?.array?.count)
        XCTAssertEqual(board.tasks.map(\.title), ["Write the score", "Record the parts", "Mix it"])
        XCTAssertTrue(board.tasks.allSatisfy { $0.status == .todo })
        XCTAssertTrue(board.tasks.allSatisfy { $0.assignee.kind == .unassigned })
        XCTAssertEqual(board.version, created.version)
        XCTAssertFalse(fetched.unchanged)
        let poll = try await send(.taskBoard(project: created.project, sinceVersion: board.version), api)
        XCTAssertTrue(poll.unchanged, "nothing moved, so the poll should say so")
        XCTAssertNil(poll.board)
        let stale = try await send(.taskBoard(project: created.project, sinceVersion: board.version - 1), api)
        XCTAssertFalse(stale.unchanged)
        XCTAssertNotNil(stale.board)

        // The summary agrees with the Kit's own arithmetic over the board.
        let summary = try await send(.taskBoardSummary(project: created.project), api)
        let computed = TaskBoardSummary.compute(board)
        XCTAssertEqual(summary.summary.total, 3)
        XCTAssertEqual(summary.summary.total, computed.total)
        XCTAssertEqual(summary.summary.byStatus, computed.byStatus)
        XCTAssertEqual(summary.summary.progress, computed.progress)
        XCTAssertEqual(summary.summary.version, board.version)
        XCTAssertEqual(summary.summary.unassigned, 3)

        let task = try await send(.taskBoardTask(project: created.project, taskID: board.tasks[1].id), api)
        XCTAssertEqual(task.task.title, "Record the parts")
        XCTAssertEqual(task.task.id, board.tasks[1].id)
        // The data page's slug works as well as the project id.
        let bySlug = try await send(.taskBoard(project: created.data.slug), api)
        XCTAssertEqual(bySlug.board?.id, created.project)

        await expectFailure(404, .taskBoard(project: "no-such-\(unique("board"))"), api)
        await expectFailure(404, .taskBoardTask(project: created.project, taskID: "t-nope"), api)
        await expectFailure(400, .createTaskBoard(TaskBoardDraft(title: "  ")), api)
        let (bob, _) = try second()
        await expectFailure(404, .taskBoard(project: created.project), bob)
    }

    func testEveryEditTheAppMakesLeavesTheBoardAsTheKitPredicts() async throws {
        let (api, _) = member(22)
        var (project, board, _) = try await newBoard(api)
        let first = board.tasks[0].id
        let second = board.tasks[1].id

        func apply(_ edit: TaskBoardEdit, file: StaticString = #filePath, line: UInt = #line) async throws -> TaskBoard {
            let predicted = edit.applying(to: board, me: "You")
            let result = try await send(edit.endpoint(project: project, expectedVersion: board.version), api, file: file, line: line)
            let after = try await send(.taskBoard(project: project), api, file: file, line: line).board
            let server = try XCTUnwrap(after, file: file, line: line)
            XCTAssertEqual(server.version, board.version + 1, "every write bumps the version by one: \(edit)", file: file, line: line)
            if let returned = result.board { XCTAssertEqual(returned.version, server.version, file: file, line: line) }
            // Compare the task the edit touched, field by field, with what the Kit predicted.
            if let id = edit.taskID, let mine = predicted.task(id), let theirs = server.task(id) {
                XCTAssertEqual(theirs.title, mine.title, "title after \(edit)", file: file, line: line)
                XCTAssertEqual(theirs.status, mine.status, "status after \(edit)", file: file, line: line)
                XCTAssertEqual(theirs.priority, mine.priority, "priority after \(edit)", file: file, line: line)
                XCTAssertEqual(theirs.progress, mine.progress, "progress after \(edit)", file: file, line: line)
                XCTAssertEqual(theirs.assignee.kind, mine.assignee.kind, "assignee after \(edit)", file: file, line: line)
                XCTAssertEqual(theirs.notes.map(\.body), mine.notes.map(\.body), "notes after \(edit)", file: file, line: line)
                XCTAssertEqual(theirs.lock == nil, mine.lock == nil, "lock after \(edit)", file: file, line: line)
                XCTAssertEqual(theirs.completedAt == nil, mine.completedAt == nil, "completed after \(edit)", file: file, line: line)
            }
            board = server
            return server
        }

        var after = try await apply(.rename(taskID: first, to: "Write the full score"))
        XCTAssertEqual(after.task(first)?.title, "Write the full score")
        after = try await apply(.setPriority(taskID: first, to: .high))
        XCTAssertEqual(after.task(first)?.priority, .high)
        after = try await apply(.setPriority(taskID: first, to: nil))
        XCTAssertNil(after.task(first)?.priority)
        after = try await apply(.setProgress(taskID: first, to: 40))
        XCTAssertEqual(after.task(first)?.progress, 40)
        after = try await apply(.setStatus(taskID: first, to: .inProgress))
        XCTAssertEqual(after.task(first)?.status, .inProgress)
        after = try await apply(.addNote(taskID: first, text: "Started on the alto line"))
        XCTAssertEqual(after.task(first)?.notes.last?.body, "Started on the alto line")
        XCTAssertEqual(after.task(first)?.notes.last?.authorKind, "human")
        XCTAssertNotNil(after.task(first)?.notes.last?.createdAt)

        // A claim takes the task and puts a hold on it; releasing hands it back.
        after = try await apply(.claim(taskID: second, force: false))
        XCTAssertEqual(after.task(second)?.assignee.kind, .human)
        XCTAssertNotNil(after.task(second)?.lock)
        XCTAssertTrue(after.task(second)?.lock?.isLive() ?? false)
        XCTAssertEqual(after.task(second)?.status, .inProgress)
        after = try await apply(.release(taskID: second))
        XCTAssertEqual(after.task(second)?.assignee.kind, .unassigned)
        XCTAssertNil(after.task(second)?.lock)

        // Adding a task, and a subtask under it; the parent lists its child.
        let addedBoard = try await apply(.add(title: "Ship it", parent: nil, tempID: "tmp-1"))
        let ship = try XCTUnwrap(addedBoard.tasks.first { $0.title == "Ship it" })
        XCTAssertNotEqual(ship.id, "tmp-1", "the server gives a task its own id")
        let withChild = try await apply(.add(title: "Upload", parent: ship.id, tempID: "tmp-2"))
        let child = try XCTUnwrap(withChild.tasks.first { $0.title == "Upload" })
        XCTAssertEqual(child.parent, ship.id)
        XCTAssertTrue(withChild.task(ship.id)?.children.contains(child.id) ?? false)
        XCTAssertEqual(withChild.subtasks(of: ship.id).map(\.id), [child.id])

        // Completing records a note and a completion time; progress goes to 100.
        after = try await apply(.complete(taskID: first, note: "All parts written"))
        XCTAssertEqual(after.task(first)?.status, .done)
        XCTAssertNotNil(after.task(first)?.completedAt)
        XCTAssertEqual(after.task(first)?.progress, 100)
        XCTAssertNil(after.task(first)?.lock)
        XCTAssertEqual(after.task(first)?.notes.last?.body, "All parts written")
        after = try await apply(.setStatus(taskID: first, to: .todo))
        XCTAssertNil(after.task(first)?.completedAt, "reopening clears the completion time")

        // Totals follow.
        let summary = try await send(.taskBoardSummary(project: project), api)
        XCTAssertEqual(summary.summary.total, after.tasks.count)
        XCTAssertEqual(summary.summary.byStatus, TaskBoardSummary.compute(after).byStatus)

        // Refusals: a missing task, a bad status, progress out of range.
        await expectFailure(404, TaskBoardEdit.rename(taskID: "t-none", to: "x").endpoint(project: project, expectedVersion: board.version), api)
        let bad = Endpoint<TaskBoardMutation>(.patch, "/api/tasklists/\(project)/tasks/\(first)", body: .jsonValue(["expected_version": .int(board.version), "patch": ["status": "sideways"]]), keys: .verbatim)
        await expectFailure(400, bad, api)
    }

    func testAStaleWriteIsRefusedWithTheLatestBoardAndTheKitDecidesWhatToDo() async throws {
        let (api, _) = member(23)
        let (project, board, _) = try await newBoard(api, "Conflict")
        let task = board.tasks[0].id
        let other = board.tasks[1].id

        // Someone else renames the first task (a second client, at the same version).
        let theirs = TaskBoardEdit.rename(taskID: task, to: "Renamed elsewhere")
        _ = try await send(theirs.endpoint(project: project, expectedVersion: board.version), api)

        // A change made against the old version is refused with the latest attached.
        let mine = TaskBoardEdit.setStatus(taskID: other, to: .inProgress)
        let failure = await expectFailure(409, mine.endpoint(project: project, expectedVersion: board.version), api)
        let error = HVError.api(try XCTUnwrap(failure))
        let latest = try XCTUnwrap(TaskBoardConflict.latest(in: error), "the 409 did not carry a board the Kit can read: \(String(describing: failure?.body))")
        XCTAssertEqual(latest.version, board.version + 1)
        XCTAssertEqual(latest.task(task)?.title, "Renamed elsewhere")
        XCTAssertEqual(latest.id, project)
        XCTAssertFalse(error.boardSentence.isEmpty)

        // The edit touched something else, so it can go on top; the server then takes it.
        XCTAssertEqual(mine.mergeDecision(base: board, latest: latest), .reapply)
        _ = try await send(mine.endpoint(project: project, expectedVersion: latest.version), api)
        // The same rename made again is already so; a different rename of the same task is a conflict.
        XCTAssertEqual(theirs.mergeDecision(base: board, latest: latest), .alreadyDone)
        let clash = TaskBoardEdit.rename(taskID: task, to: "Mine instead")
        if case .conflict(let sentence) = clash.mergeDecision(base: board, latest: latest) {
            XCTAssertTrue(sentence.contains("renamed"), sentence)
        } else {
            XCTFail("a rename against a different rename should be a conflict")
        }

        // Without an expected_version the write goes through on the latest.
        let blind = TaskBoardEdit.setPriority(taskID: task, to: .critical)
        _ = try await send(blind.endpoint(project: project, expectedVersion: nil), api)
        let final = try await send(.taskBoard(project: project), api).board
        XCTAssertEqual(final?.task(task)?.priority, .critical)
        XCTAssertEqual(final?.task(other)?.status, .inProgress)
    }

    func testAnAgentClaimsATaskAndThePersonSeesTheLock() async throws {
        let (api, _) = member(23)
        let (project, board, _) = try await newBoard(api, "Agents")
        let task = board.tasks[0].id
        let key = try await send(.createAgentKey(name: unique("board agent")), api)
        let agent = client(key.key)

        // The agent claims through the same route; its name is the key's.
        let claim = Endpoint<TaskBoardMutation>(.post, "/api/tasklists/\(project)/tasks/\(task)/claim", body: .jsonValue(["actor": ["name": "Builder", "kind": "agent", "agentType": "builder"]]), keys: .verbatim)
        let claimed = try await send(claim, agent)
        XCTAssertEqual(claimed.task?.assignee.kind, .agent)
        XCTAssertTrue(claimed.task?.assignee.isAgent ?? false)
        XCTAssertNotNil(claimed.task?.lock)
        let seen = try await send(.taskBoard(project: project), api)
        let theirTask = try XCTUnwrap(seen.board?.task(task))
        XCTAssertTrue(theirTask.isClaimedByAgent)
        XCTAssertTrue(theirTask.lock?.isLive() ?? false)
        XCTAssertNotNil(theirTask.holder)
        let summary = try await send(.taskBoardSummary(project: project), api)
        XCTAssertEqual(summary.summary.claimed.map(\.taskId), [task])
        XCTAssertEqual(summary.summary.claimed.first?.agentType, "builder")
        XCTAssertEqual(TaskBoardFilter.agents.includes(theirTask), true)
        XCTAssertEqual(TaskBoardFilter.people.includes(theirTask), false)

        // The person cannot take it without forcing; with force they can.
        let version = try XCTUnwrap(seen.board?.version)
        let refused = await expectFailure(409, TaskBoardEdit.claim(taskID: task, force: false).endpoint(project: project, expectedVersion: version), api)
        XCTAssertNotNil(refused)
        let forced = try await send(TaskBoardEdit.claim(taskID: task, force: true).endpoint(project: project, expectedVersion: version), api)
        XCTAssertEqual(forced.task?.assignee.kind, .human)
        // The server lets the agent complete a task it no longer holds; the hold goes with it.
        let complete = Endpoint<TaskBoardMutation>(.post, "/api/tasklists/\(project)/tasks/\(task)/complete", body: .jsonValue([:]), keys: .verbatim)
        let late = try await send(complete, agent)
        XCTAssertEqual(late.task?.status, .done)
        XCTAssertNil(late.task?.lock)
    }
}
