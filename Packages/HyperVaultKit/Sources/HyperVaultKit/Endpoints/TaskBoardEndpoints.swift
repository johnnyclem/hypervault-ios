import Foundation

// Task board routes: app/api/taskboards and app/api/tasklists/[project]/**.
// A project is the id on a listing (`eurorack-choir`); the routes also take
// the `tasks-…` slug. Edits are `TaskBoardEdit.endpoint`.

extension Endpoint where Response == TaskBoardIndex {
    /// Every board in the vault, newest first.
    public static var taskBoards: Endpoint<TaskBoardIndex> {
        Endpoint(.get, "/api/taskboards")
    }
}

extension Endpoint where Response == CreatedTaskBoard {
    /// A new board: the data page and its board page, as one.
    public static func createTaskBoard(_ draft: TaskBoardDraft) -> Endpoint<CreatedTaskBoard> {
        Endpoint(.post, "/api/taskboards", body: .jsonValue(draft.requestBody))
    }
}

extension Endpoint where Response == TaskBoardFetch {
    /// The whole list. With `sinceVersion` the answer is `unchanged` when nothing moved: the cheap poll.
    public static func taskBoard(project: String, sinceVersion: Int? = nil) -> Endpoint<TaskBoardFetch> {
        Endpoint(
            .get, "/api/tasklists/\(project)",
            query: .make([("since_version", sinceVersion.map(String.init))]),
            keys: .verbatim
        )
    }
}

extension Endpoint where Response == TaskBoardSummaryResponse {
    /// Totals by status, overall and per-epic progress, claims: without the tasks.
    public static func taskBoardSummary(project: String) -> Endpoint<TaskBoardSummaryResponse> {
        Endpoint(.get, "/api/tasklists/\(project)/summary", keys: .verbatim)
    }
}

extension Endpoint where Response == TaskBoardTaskResponse {
    public static func taskBoardTask(project: String, taskID: String) -> Endpoint<TaskBoardTaskResponse> {
        Endpoint(.get, "/api/tasklists/\(project)/tasks/\(taskID)", keys: .verbatim)
    }
}
