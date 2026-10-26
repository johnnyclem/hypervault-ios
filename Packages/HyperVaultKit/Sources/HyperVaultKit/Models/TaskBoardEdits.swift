import Foundation

// Changing a board. Every change is one request with `expected_version`; the
// screen applies it to its copy first (`applying`), and when the server says the
// list moved on (409 with the latest attached) `mergeDecision` says whether the
// change still makes sense on top of what changed.

/// One change a person makes to a board.
public enum TaskBoardEdit: Sendable, Equatable {
    case setStatus(taskID: String, to: BoardTaskStatus)
    case setProgress(taskID: String, to: Int)
    case rename(taskID: String, to: String)
    case setPriority(taskID: String, to: BoardTaskPriority?)
    case addNote(taskID: String, text: String)
    /// A new task, optionally under a parent. `tempID` stands in until the server names it.
    case add(title: String, parent: String?, tempID: String)
    case claim(taskID: String, force: Bool)
    case release(taskID: String)
    case complete(taskID: String, note: String?)

    /// The task this changes, if it changes an existing one.
    public var taskID: String? {
        switch self {
        case .setStatus(let id, _), .setProgress(let id, _), .rename(let id, _), .setPriority(let id, _),
             .addNote(let id, _), .claim(let id, _), .release(let id), .complete(let id, _):
            return id
        case .add:
            return nil
        }
    }

    /// A sentence for a toast once it has landed.
    public var doneSentence: String {
        switch self {
        case .setStatus(_, let status): return status == .done ? "Done." : "Moved to \(status.title.lowercased())."
        case .setProgress: return "Progress saved."
        case .rename: return "Renamed."
        case .setPriority: return "Priority saved."
        case .addNote: return "Note added."
        case .add: return "Task added."
        case .claim: return "Yours."
        case .release: return "Handed back."
        case .complete: return "Done."
        }
    }

    // MARK: On the wire

    public func endpoint(project: String, expectedVersion: Int?) -> Endpoint<TaskBoardMutation> {
        var body: [String: JSONValue] = [:]
        if let expectedVersion { body["expected_version"] = .int(expectedVersion) }
        let base = "/api/tasklists/\(project)/tasks"
        switch self {
        case .setStatus(let id, let status):
            body["patch"] = .object(["status": .string(status.rawValue)])
            return Endpoint(.patch, "\(base)/\(id)", body: .jsonValue(.object(body)), keys: .verbatim)
        case .setProgress(let id, let value):
            body["patch"] = .object(["progress": .int(min(max(value, 0), 100))])
            return Endpoint(.patch, "\(base)/\(id)", body: .jsonValue(.object(body)), keys: .verbatim)
        case .rename(let id, let title):
            body["patch"] = .object(["title": .string(title)])
            return Endpoint(.patch, "\(base)/\(id)", body: .jsonValue(.object(body)), keys: .verbatim)
        case .setPriority(let id, let priority):
            body["patch"] = .object(["priority": priority.map { .string($0.rawValue) } ?? .null])
            return Endpoint(.patch, "\(base)/\(id)", body: .jsonValue(.object(body)), keys: .verbatim)
        case .addNote(let id, let text):
            body["patch"] = .object(["note": .string(text)])
            return Endpoint(.patch, "\(base)/\(id)", body: .jsonValue(.object(body)), keys: .verbatim)
        case .add(let title, let parent, _):
            var task: [String: JSONValue] = ["title": .string(title)]
            if let parent { task["parent"] = .string(parent) }
            body["task"] = .object(task)
            return Endpoint(.post, base, body: .jsonValue(.object(body)), keys: .verbatim)
        case .claim(let id, let force):
            if force { body["force"] = .bool(true) }
            return Endpoint(.post, "\(base)/\(id)/claim", body: .jsonValue(.object(body)), keys: .verbatim)
        case .release(let id):
            body["release"] = .bool(true)
            return Endpoint(.post, "\(base)/\(id)/claim", body: .jsonValue(.object(body)), keys: .verbatim)
        case .complete(let id, let note):
            if let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { body["note"] = .string(note) }
            return Endpoint(.post, "\(base)/\(id)/complete", body: .jsonValue(.object(body)), keys: .verbatim)
        }
    }

    // MARK: On the phone, before the server answers

    /// The board as it will be once this lands. The server's answer replaces it.
    /// `me` is the name a claim shows until then.
    public func applying(to board: TaskBoard, me: String = "You", now: Date = Date()) -> TaskBoard {
        switch self {
        case .setStatus(let id, let status):
            return board.editing(id) { $0.setStatus(status, now: now) }
        case .complete(let id, let note):
            return board.editing(id) { task in
                task.setStatus(.done, now: now)
                if let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    task.notes.append(BoardNote(id: "tmp-note", author: me, authorKind: "human", body: note, createdAt: now))
                }
            }
        case .setProgress(let id, let value):
            return board.editing(id) { $0.progress = min(max(value, 0), 100) }
        case .rename(let id, let title):
            return board.editing(id) { $0.title = title }
        case .setPriority(let id, let priority):
            return board.editing(id) { $0.priority = priority }
        case .addNote(let id, let text):
            return board.editing(id) {
                $0.notes.append(BoardNote(id: "tmp-note-\($0.notes.count)", author: me, authorKind: "human", body: text, createdAt: now))
            }
        case .add(let title, let parent, let tempID):
            var copy = board
            copy.tasks.append(BoardTask(id: tempID, title: title, parent: parent, createdAt: now, updatedAt: now))
            if let parent {
                copy.tasks = copy.tasks.map { task in
                    guard task.id == parent else { return task }
                    var parentTask = task
                    parentTask.children.append(tempID)
                    return parentTask
                }
            }
            return copy
        case .claim(let id, _):
            return board.editing(id) { task in
                task.assignee = BoardAssignee(kind: .human, name: me)
                task.lock = BoardLock(by: me, at: now, expiresAt: now.addingTimeInterval(3600))
                if task.status != .blocked { task.status = .inProgress }
            }
        case .release(let id):
            return board.editing(id) { task in
                task.assignee = .unassigned
                task.lock = nil
                if task.status == .inProgress { task.status = .todo }
            }
        }
    }

    // MARK: When the list moved on

    /// What to do with this change when the server answered 409 with the latest list.
    public enum MergeDecision: Sendable, Equatable {
        /// Nothing it touches has changed: send it again on top of the latest.
        case reapply
        /// What it wanted is already so: drop it, there is nothing left to do.
        case alreadyDone
        /// Someone else changed the same thing: the person chooses.
        case conflict(String)
    }

    /// `base` is the list the change was made against; `latest` is what the server holds now.
    public func mergeDecision(base: TaskBoard, latest: TaskBoard, now: Date = Date()) -> MergeDecision {
        switch self {
        case .add(_, let parent, _):
            if let parent, latest.task(parent) == nil { return .conflict("The task you were adding under is gone.") }
            return .reapply
        case .addNote(let id, _):
            return latest.task(id) == nil ? .conflict("That task is gone.") : .reapply
        default:
            break
        }
        guard let id = taskID else { return .reapply }
        guard let theirs = latest.task(id) else { return .conflict("That task is gone.") }
        let mine = base.task(id)

        switch self {
        case .setStatus(_, let wanted):
            if theirs.status == wanted { return .alreadyDone }
            if mine?.status == theirs.status { return .reapply }
            return .conflict("Someone moved it to \(theirs.status.title.lowercased()) in the meantime.")
        case .complete:
            if theirs.status == .done { return .alreadyDone }
            if mine?.status == theirs.status { return .reapply }
            return .conflict("Someone moved it to \(theirs.status.title.lowercased()) in the meantime.")
        case .setProgress(_, let wanted):
            if theirs.progress == wanted { return .alreadyDone }
            return mine?.progress == theirs.progress ? .reapply : .conflict("Someone changed its progress in the meantime.")
        case .rename(_, let wanted):
            if theirs.title == wanted { return .alreadyDone }
            return mine?.title == theirs.title ? .reapply : .conflict("Someone renamed it in the meantime.")
        case .setPriority(_, let wanted):
            if theirs.priority == wanted { return .alreadyDone }
            return mine?.priority == theirs.priority ? .reapply : .conflict("Someone changed its priority in the meantime.")
        case .claim(_, let force):
            if let lock = theirs.lock, lock.isLive(now: now), !force, mine?.lock?.by != lock.by {
                return .conflict("\(lock.by) claimed it in the meantime.")
            }
            return .reapply
        case .release:
            if theirs.lock == nil { return .alreadyDone }
            return .reapply
        case .add, .addNote:
            return .reapply
        }
    }
}

extension BoardTask {
    fileprivate mutating func setStatus(_ status: BoardTaskStatus, now: Date) {
        let was = self.status
        self.status = status
        updatedAt = now
        if status == .done, was != .done {
            completedAt = now
            if progress != nil { progress = 100 }
            lock = nil
        } else if was == .done, status != .done {
            completedAt = nil
        }
    }
}

extension TaskBoard {
    fileprivate func editing(_ id: String, _ change: (inout BoardTask) -> Void) -> TaskBoard {
        var copy = self
        copy.tasks = tasks.map { task in
            guard task.id == id else { return task }
            var edited = task
            change(&edited)
            return edited
        }
        return copy
    }
}

// MARK: A refused write

/// `409 { conflict: true, latest }`: the list is no longer at the revision the
/// change was made against, and the latest is attached.
public enum TaskBoardConflict {
    public static func latest(in error: Error) -> TaskBoard? {
        guard let hv = error as? HVError, case .api(let failure) = hv, failure.status == 409,
              failure.body?["conflict"]?.bool == true, let latest = failure.body?["latest"]
        else { return nil }
        guard let data = try? JSONEncoder().encode(latest) else { return nil }
        return try? HVCoding.decoder(.verbatim).decode(TaskBoard.self, from: data)
    }
}

extension HVError {
    /// The sentence for a board failure: the server's own.
    public var boardSentence: String { userMessage }
}

// MARK: Grouping for the screen

public enum TaskBoardFilter: String, Sendable, CaseIterable, Identifiable, Hashable {
    case all, open, agents, people, done

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: return "All"
        case .open: return "Open"
        case .agents: return "Agents"
        case .people: return "Me"
        case .done: return "Done"
        }
    }

    public func includes(_ task: BoardTask) -> Bool {
        switch self {
        case .all: return true
        case .open: return task.status.isOpen
        case .agents: return task.assignee.isAgent
        case .people: return task.assignee.isHuman
        case .done: return task.status == .done
        }
    }
}

/// A row on the board: the task, how deep it sits, and where it came from when
/// its parent is in another group.
public struct TaskBoardRow: Sendable, Hashable, Identifiable {
    public let task: BoardTask
    public let depth: Int
    /// The parent's title, when the parent is not in the same group.
    public let parentTitle: String?

    public var id: String { task.id }
}

public struct TaskBoardGroup: Sendable, Hashable, Identifiable {
    public let status: BoardTaskStatus
    public let rows: [TaskBoardRow]

    public var id: String { status.rawValue }
}

extension TaskBoard {
    /// The board by status, what needs attention first. A subtask sits under its
    /// parent when they share a group, and stands on its own (with its parent's
    /// name) when they do not. Empty groups are left out.
    public func groups(filter: TaskBoardFilter = .all) -> [TaskBoardGroup] {
        let included = tasks.filter { filter.includes($0) }
        var out: [TaskBoardGroup] = []
        for status in BoardTaskStatus.boardOrder {
            let inGroup = included.filter { $0.status == status }
            guard !inGroup.isEmpty else { continue }
            let ids = Set(inGroup.map(\.id))
            var rows: [TaskBoardRow] = []
            var placed = Set<String>()

            func place(_ task: BoardTask, depth: Int) {
                guard placed.insert(task.id).inserted else { return }
                let parentTitle = depth == 0 ? task.parent.flatMap { self.task($0)?.title } : nil
                rows.append(TaskBoardRow(task: task, depth: depth, parentTitle: parentTitle))
                for child in inGroup where child.parent == task.id { place(child, depth: depth + 1) }
            }
            for task in inGroup where task.parent == nil || !ids.contains(task.parent ?? "") {
                place(task, depth: 0)
            }
            out.append(TaskBoardGroup(status: status, rows: rows))
        }
        return out
    }

    /// Done over total across the board, for the progress bar (cancelled work does not count).
    public var progress: (done: Int, total: Int) {
        let countable = tasks.filter { $0.status != .cancelled }
        return (countable.filter { $0.status == .done }.count, countable.count)
    }
}
