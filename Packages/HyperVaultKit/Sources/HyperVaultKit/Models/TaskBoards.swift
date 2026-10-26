import Foundation

// Universal task boards: shared human + agent lists (docs/tasklists.md, the
// schema is public/schemas/tasklist-v1.json). Every key on the wire is camelCase
// or one lowercase word, so these types are read with `keys: .verbatim`, which
// also keeps `metadata` and `byStatus` keys exactly as written.

private extension KeyedDecodingContainer {
    func soft<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

// MARK: Vocabulary

public enum BoardTaskStatus: String, Sendable, Codable, CaseIterable, Hashable, Identifiable {
    case todo
    case inProgress = "in_progress"
    case blocked
    case review
    case done
    case cancelled

    public var id: String { rawValue }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BoardTaskStatus(rawValue: raw) ?? .todo
    }

    public var title: String {
        switch self {
        case .todo: return "To do"
        case .inProgress: return "In progress"
        case .blocked: return "Blocked"
        case .review: return "In review"
        case .done: return "Done"
        case .cancelled: return "Cancelled"
        }
    }

    /// Open work: not done and not cancelled.
    public var isOpen: Bool { self != .done && self != .cancelled }

    /// What one tap on the status mark does: start it, finish it, and bring a
    /// finished one back. A blocked task gets going again; one in review is
    /// accepted. The other four are chosen from a menu.
    public var cycled: BoardTaskStatus {
        switch self {
        case .todo: return .inProgress
        case .inProgress, .review: return .done
        case .blocked: return .inProgress
        case .done, .cancelled: return .todo
        }
    }

    /// The order the board lists its groups in: what needs a person's eye first.
    public static let boardOrder: [BoardTaskStatus] = [.inProgress, .blocked, .review, .todo, .done, .cancelled]
}

public enum BoardTaskPriority: String, Sendable, Codable, CaseIterable, Hashable, Identifiable {
    case low, medium, high, critical

    public var id: String { rawValue }

    public var title: String { rawValue.capitalized }
}

public enum BoardAssigneeKind: String, Sendable, Codable, Hashable {
    case human, agent, subagent, unassigned

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BoardAssigneeKind(rawValue: raw) ?? .unassigned
    }
}

public struct BoardAssignee: Sendable, Codable, Hashable {
    public let kind: BoardAssigneeKind
    public let name: String?
    public let agentType: String?
    public let display: String?

    public init(kind: BoardAssigneeKind, name: String? = nil, agentType: String? = nil, display: String? = nil) {
        self.kind = kind
        self.name = name
        self.agentType = agentType
        self.display = display
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        kind = c.soft(BoardAssigneeKind.self, .kind) ?? .unassigned
        name = c.soft(String.self, .name)
        agentType = c.soft(String.self, .agentType)
        display = c.soft(String.self, .display)
    }

    enum Keys: String, CodingKey { case kind, name, agentType, display }

    public static let unassigned = BoardAssignee(kind: .unassigned)

    public var isAgent: Bool { kind == .agent || kind == .subagent }
    public var isHuman: Bool { kind == .human }

    /// Who, in a word: the display name, else the name, else the kind of agent.
    public var label: String? {
        guard kind != .unassigned else { return nil }
        for candidate in [display, name, agentType] {
            if let candidate, !candidate.trimmingCharacters(in: .whitespaces).isEmpty { return candidate }
        }
        return kind == .human ? "A person" : "An agent"
    }
}

public struct BoardLock: Sendable, Codable, Hashable {
    public let by: String
    public let agentType: String?
    public let at: Date?
    public let expiresAt: Date?

    public init(by: String, agentType: String? = nil, at: Date? = nil, expiresAt: Date? = nil) {
        self.by = by
        self.agentType = agentType
        self.at = at
        self.expiresAt = expiresAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        by = c.soft(String.self, .by) ?? ""
        agentType = c.soft(String.self, .agentType)
        at = c.soft(Date.self, .at)
        expiresAt = c.soft(Date.self, .expiresAt)
    }

    enum Keys: String, CodingKey { case by, agentType, at, expiresAt }

    /// A claim whose time has run out can be taken by anyone.
    public func isLive(now: Date = Date()) -> Bool {
        guard let expiresAt else { return true }
        return expiresAt > now
    }
}

public struct BoardNote: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let author: String?
    public let authorKind: String?
    public let body: String
    public let createdAt: Date?

    public init(id: String, author: String? = nil, authorKind: String? = nil, body: String, createdAt: Date? = nil) {
        self.id = id
        self.author = author
        self.authorKind = authorKind
        self.body = body
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        body = c.soft(String.self, .body) ?? ""
        author = c.soft(String.self, .author)
        authorKind = c.soft(String.self, .authorKind)
        createdAt = c.soft(Date.self, .createdAt)
        id = c.soft(String.self, .id) ?? "\(createdAt?.timeIntervalSince1970 ?? 0)-\(author ?? "")-\(body.prefix(24))"
    }

    enum Keys: String, CodingKey { case id, author, authorKind, body, createdAt }

    public var isFromAgent: Bool { authorKind == "agent" || authorKind == "subagent" }
}

// MARK: Tasks and boards

public struct BoardTask: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public var title: String
    public var type: String
    public var status: BoardTaskStatus
    public var priority: BoardTaskPriority?
    public var description: String?
    /// What an agent says it is doing while the task is in progress.
    public var activeForm: String?
    public var assignee: BoardAssignee
    public var progress: Int?
    public var parent: String?
    public var children: [String]
    public var dependsOn: [String]
    public var blocks: [String]
    public var notes: [BoardNote]
    public var lock: BoardLock?
    public var createdAt: Date?
    public var updatedAt: Date?
    public var completedAt: Date?

    public init(
        id: String, title: String, type: String = "task", status: BoardTaskStatus = .todo,
        priority: BoardTaskPriority? = nil, description: String? = nil, activeForm: String? = nil,
        assignee: BoardAssignee = .unassigned, progress: Int? = nil, parent: String? = nil,
        children: [String] = [], dependsOn: [String] = [], blocks: [String] = [], notes: [BoardNote] = [],
        lock: BoardLock? = nil, createdAt: Date? = nil, updatedAt: Date? = nil, completedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.type = type
        self.status = status
        self.priority = priority
        self.description = description
        self.activeForm = activeForm
        self.assignee = assignee
        self.progress = progress
        self.parent = parent
        self.children = children
        self.dependsOn = dependsOn
        self.blocks = blocks
        self.notes = notes
        self.lock = lock
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        title = c.soft(String.self, .title) ?? "Untitled"
        type = c.soft(String.self, .type) ?? "task"
        status = c.soft(BoardTaskStatus.self, .status) ?? .todo
        priority = c.soft(BoardTaskPriority.self, .priority)
        description = c.soft(String.self, .description)
        activeForm = c.soft(String.self, .activeForm)
        assignee = c.soft(BoardAssignee.self, .assignee) ?? .unassigned
        progress = c.soft(Int.self, .progress) ?? c.soft(Double.self, .progress).map { Int($0.rounded()) }
        parent = c.soft(String.self, .parent)
        children = c.soft([String].self, .children) ?? []
        dependsOn = c.soft([String].self, .dependsOn) ?? []
        blocks = c.soft([String].self, .blocks) ?? []
        notes = c.soft([BoardNote].self, .notes) ?? []
        lock = c.soft(BoardLock.self, .lock)
        createdAt = c.soft(Date.self, .createdAt)
        updatedAt = c.soft(Date.self, .updatedAt)
        completedAt = c.soft(Date.self, .completedAt)
    }

    enum Keys: String, CodingKey {
        case id, title, type, status, priority, description, activeForm, assignee, progress, parent
        case children, dependsOn, blocks, notes, lock, createdAt, updatedAt, completedAt
    }

    /// The word for who has it: "You", an agent's name, or nil when nobody does.
    public var holder: String? {
        if let lock, !lock.by.isEmpty { return lock.by }
        return assignee.label
    }

    public var isClaimedByAgent: Bool { assignee.isAgent }
}

/// A whole task list: the document the board shows.
public struct TaskBoard: Sendable, Codable, Hashable, Identifiable {
    /// The project id (the slug without `tasks-`).
    public let id: String
    public var title: String
    /// Bumps by one on every write; what `expected_version` pins to.
    public var version: Int
    public var stages: [String]
    public var tasks: [BoardTask]
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(id: String, title: String, version: Int = 0, stages: [String] = [], tasks: [BoardTask] = [], createdAt: Date? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.version = version
        self.stages = stages
        self.tasks = tasks
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        title = c.soft(String.self, .title) ?? id
        version = c.soft(Int.self, .version) ?? 0
        stages = c.soft([String].self, .stages) ?? []
        // One unreadable task must not take the whole board with it.
        tasks = (try? c.decodeIfPresent([Lossy<BoardTask>].self, forKey: .tasks))?.compactMap(\.value) ?? []
        createdAt = c.soft(Date.self, .createdAt)
        updatedAt = c.soft(Date.self, .updatedAt)
    }

    enum Keys: String, CodingKey { case id, title, version, stages, tasks, createdAt, updatedAt }

    public func task(_ id: String) -> BoardTask? { tasks.first { $0.id == id } }

    /// The subtasks of a task, in the order the list holds them.
    public func subtasks(of id: String) -> [BoardTask] {
        tasks.filter { $0.parent == id }
    }

    /// A task and everything under it.
    public func descendants(of id: String) -> [BoardTask] {
        var out: [BoardTask] = []
        var queue = subtasks(of: id)
        var seen = Set<String>([id])
        while !queue.isEmpty {
            let next = queue.removeFirst()
            guard seen.insert(next.id).inserted else { continue }
            out.append(next)
            queue.append(contentsOf: subtasks(of: next.id))
        }
        return out
    }

    /// How much of the work under a task is done (cancelled work does not count); nil for a task with no subtasks.
    public func rollup(of id: String) -> (done: Int, total: Int)? {
        let below = descendants(of: id).filter { $0.status != .cancelled }
        guard !below.isEmpty else { return nil }
        return (below.filter { $0.status == .done }.count, below.count)
    }

    public var rootTasks: [BoardTask] { tasks.filter { $0.parent == nil } }

    /// Replaces a task (or leaves the list alone when it is gone).
    public func replacing(_ task: BoardTask) -> TaskBoard {
        var copy = self
        copy.tasks = tasks.map { $0.id == task.id ? task : $0 }
        return copy
    }
}

/// Decodes one element or nothing, so a bad element is skipped.
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

// MARK: Summary

public struct TaskBoardSummary: Sendable, Codable, Hashable {
    public struct Epic: Sendable, Codable, Hashable, Identifiable {
        public let id: String
        public let title: String
        public let total: Int
        public let done: Int
        public let progress: Int
    }

    public struct Claim: Sendable, Codable, Hashable {
        public let taskId: String
        public let by: String
        public let agentType: String?
    }

    public let id: String
    public let title: String
    public let version: Int
    public let total: Int
    public let byStatus: [String: Int]
    /// Percent of countable (not cancelled) tasks that are done.
    public let progress: Int
    public let epics: [Epic]
    public let claimed: [Claim]
    public let unassigned: Int

    public init(
        id: String, title: String, version: Int, total: Int, byStatus: [String: Int], progress: Int,
        epics: [Epic] = [], claimed: [Claim] = [], unassigned: Int = 0
    ) {
        self.id = id
        self.title = title
        self.version = version
        self.total = total
        self.byStatus = byStatus
        self.progress = progress
        self.epics = epics
        self.claimed = claimed
        self.unassigned = unassigned
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = c.soft(String.self, .id) ?? ""
        title = c.soft(String.self, .title) ?? ""
        version = c.soft(Int.self, .version) ?? 0
        total = c.soft(Int.self, .total) ?? 0
        byStatus = c.soft([String: Int].self, .byStatus) ?? [:]
        progress = c.soft(Int.self, .progress) ?? 0
        epics = c.soft([Epic].self, .epics) ?? []
        claimed = c.soft([Claim].self, .claimed) ?? []
        unassigned = c.soft(Int.self, .unassigned) ?? 0
    }

    enum Keys: String, CodingKey { case id, title, version, total, byStatus, progress, epics, claimed, unassigned }

    public func count(_ status: BoardTaskStatus) -> Int { byStatus[status.rawValue] ?? 0 }

    public var done: Int { count(.done) }

    /// Tasks that count toward progress (everything but cancelled).
    public var countable: Int { total - count(.cancelled) }

    /// The server's rollup, computed here from a list in hand (`summarizeTaskList`).
    public static func compute(_ board: TaskBoard) -> TaskBoardSummary {
        var byStatus: [String: Int] = [:]
        for status in BoardTaskStatus.allCases { byStatus[status.rawValue] = 0 }
        for task in board.tasks { byStatus[task.status.rawValue, default: 0] += 1 }

        let countable = board.tasks.filter { $0.status != .cancelled }
        let done = countable.filter { $0.status == .done }.count
        let progress = countable.isEmpty ? 0 : Int((Double(done) / Double(countable.count) * 100).rounded())

        let epics = board.tasks
            .filter { $0.parent == nil && !board.subtasks(of: $0.id).isEmpty }
            .map { epic -> Epic in
                let kids = board.descendants(of: epic.id).filter { $0.status != .cancelled }
                let kidsDone = kids.filter { $0.status == .done }.count
                let percent = kids.isEmpty ? (epic.status == .done ? 100 : 0) : Int((Double(kidsDone) / Double(kids.count) * 100).rounded())
                return Epic(id: epic.id, title: epic.title, total: kids.count, done: kidsDone, progress: percent)
            }

        let claimed = board.tasks
            .filter { $0.lock != nil && $0.status != .done && $0.status != .cancelled }
            .map { Claim(taskId: $0.id, by: $0.lock?.by ?? "", agentType: $0.lock?.agentType) }

        let unassigned = board.tasks.filter {
            ($0.status == .todo || $0.status == .blocked) && $0.assignee.kind == .unassigned
        }.count

        return TaskBoardSummary(
            id: board.id, title: board.title, version: board.version, total: board.tasks.count,
            byStatus: byStatus, progress: progress, epics: epics, claimed: claimed, unassigned: unassigned
        )
    }
}

// MARK: Responses

/// `GET /api/tasklists/{project}`: the whole list, or `{ unchanged, version }`
/// when `since_version` is still current.
public struct TaskBoardFetch: Sendable, Decodable {
    public let slug: String?
    public let board: TaskBoard?
    public let unchanged: Bool
    public let version: Int?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        slug = c.soft(String.self, .slug)
        board = c.soft(TaskBoard.self, .tasklist)
        unchanged = c.soft(Bool.self, .unchanged) ?? false
        version = c.soft(Int.self, .version)
    }

    enum Keys: String, CodingKey { case slug, tasklist, unchanged, version }
}

public struct TaskBoardSummaryResponse: Sendable, Decodable {
    public let slug: String?
    public let summary: TaskBoardSummary
}

/// `GET /api/tasklists/{project}/tasks/{taskId}`.
public struct TaskBoardTaskResponse: Sendable, Decodable {
    public let task: BoardTask
    public let version: Int?
}

/// What a write answers: the task as written and the whole list at its new
/// revision. Completing answers a summary and no list, so `board` is nil and
/// the screen reads the list again.
public struct TaskBoardMutation: Sendable, Decodable {
    public let task: BoardTask?
    public let board: TaskBoard?
    public let summary: TaskBoardSummary?
    public let message: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        task = c.soft(BoardTask.self, .task)
        board = c.soft(TaskBoard.self, .tasklist)
        summary = c.soft(TaskBoardSummary.self, .summary)
        message = c.soft(String.self, .message)
    }

    enum Keys: String, CodingKey { case task, tasklist, summary, message }
}

/// One board in the vault (`GET /api/taskboards`).
public struct TaskBoardListing: Sendable, Codable, Hashable, Identifiable {
    public let slug: String
    /// The project id: what the task routes take.
    public let project: String
    public let title: String
    public let url: String
    public let createdAt: Date?
    public let updatedAt: Date?

    public var id: String { slug }

    public init(slug: String, project: String, title: String, url: String = "", createdAt: Date? = nil, updatedAt: Date? = nil) {
        self.slug = slug
        self.project = project
        self.title = title
        self.url = url
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        slug = try c.decode(String.self, forKey: .slug)
        project = c.soft(String.self, .project) ?? (slug.hasPrefix("tasks-") ? String(slug.dropFirst(6)) : slug)
        title = c.soft(String.self, .title) ?? project
        url = c.soft(String.self, .url) ?? ""
        createdAt = c.soft(Date.self, .createdAt)
        updatedAt = c.soft(Date.self, .updatedAt)
    }

    enum Keys: String, CodingKey { case slug, project, title, url, createdAt, updatedAt }

    /// The board's name without the "Tasks — " the data page is titled with.
    public var displayTitle: String {
        for prefix in ["Tasks — ", "Tasks - "] where title.hasPrefix(prefix) {
            let rest = String(title.dropFirst(prefix.count))
            if !rest.isEmpty { return rest }
        }
        return title
    }
}

public struct TaskBoardIndex: Sendable, Codable, Equatable {
    public let boards: [TaskBoardListing]

    public init(boards: [TaskBoardListing] = []) { self.boards = boards }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        boards = (try? c.decodeIfPresent([Lossy<TaskBoardListing>].self, forKey: .boards))?.compactMap(\.value) ?? []
    }

    enum Keys: String, CodingKey { case boards }
}

public struct CreatedTaskBoard: Sendable, Decodable {
    public struct Page: Sendable, Decodable {
        public let slug: String
        public let url: String
    }

    public let project: String
    public let data: Page
    public let board: Page
    public let version: Int
    public let taskCount: Int
    public let message: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        project = try c.decode(String.self, forKey: .project)
        data = try c.decode(Page.self, forKey: .data)
        board = try c.decode(Page.self, forKey: .board)
        version = c.soft(Int.self, .version) ?? 0
        taskCount = c.soft(Int.self, .taskCount) ?? 0
        message = c.soft(String.self, .message)
    }

    enum Keys: String, CodingKey { case project, data, board, version, taskCount, message }
}

// MARK: Creating a board

/// What the person types to start a board: a name and, if they like, a first
/// plan, one task per line.
public struct TaskBoardDraft: Sendable, Equatable {
    public var title: String
    /// One task per non-blank line; a leading "- ", "* " or "[ ] " is dropped.
    public var plan: String

    public init(title: String = "", plan: String = "") {
        self.title = title
        self.plan = plan
    }

    public var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var canCreate: Bool { !trimmedTitle.isEmpty }

    public var firstTasks: [String] {
        plan.split(whereSeparator: \.isNewline).compactMap { line in
            var text = line.trimmingCharacters(in: .whitespaces)
            for marker in ["- [ ] ", "- [x] ", "- ", "* ", "[ ] ", "• "] {
                if text.hasPrefix(marker) {
                    text = String(text.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
                    break
                }
                if text == marker.trimmingCharacters(in: .whitespaces) {
                    text = ""
                    break
                }
            }
            return text.isEmpty ? nil : text
        }
    }

    public var requestBody: JSONValue {
        var body: [String: JSONValue] = ["title": .string(trimmedTitle), "visibility": "private"]
        let tasks = firstTasks
        if !tasks.isEmpty { body["tasks"] = .array(tasks.map { .object(["title": .string($0)]) }) }
        return .object(body)
    }
}
