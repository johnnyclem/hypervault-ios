import Foundation

// Projects: the Projects tab's pure logic. A "project" is what the server calls one task board's id
// (`tasks-{project}` holds the list, `taskboard-{project}` is its page; docs/tasklists.md). Boards and projects are one to
// one: a slug is unique across the whole `artifacts` table, so a project id names exactly one board. Nothing on the server
// says that a chat, a memory, a key or a vault entry belongs to a project, so what the overview shows beside the board is
// what the vault graph, the tags and the names can honestly say, and each row says which of those it is
// (`ProjectRelation`). When the server learns explicit project links, they become one more relation and one more reader;
// the sections, the rows and the builder stay.
//
// What the server only guessed (a page or memory it joined to the board page from shared tags and title words) is kept apart
// from the rest: the builder returns it in `ProjectRelated.possibly`, and the overview shows it only when asked.

// MARK: Words

public enum ProjectsCopy {
    public static let boardSection = "Board"
    public static let openBoard = "Open the full board"
    public static let boardEmpty = "Nothing on the board yet."
    public static let boardAllDone = "Nothing open on the board."
    public static let agentsSection = "Working on it"
    public static let pagesSection = "Pages and files"
    public static let memoriesSection = "Memories"
    public static let chatsSection = "Chats"
    public static let relatedFooter = "Linked and Tagged were filed under this project by you or an agent. Mentions it only means the name matches."
    public static let nothingRelated = "Nothing linked to this project yet."
    public static let showPossiblyRelated = "Show possibly related"
    public static let hidePossiblyRelated = "Hide possibly related"
    public static let possiblySection = "Possibly related"
    public static let possiblyFooter = "Joined to this project by a guess from shared tags and words. They may not belong."
    public static let couldntReadSection = "Couldn't read this."
    public static let couldntReadAll = "Couldn't read what goes with this project."
    public static let linksUnavailable = "Links couldn't be read, so this shows tags and names only."

    /// Opens out the rest of a section the screen shows the first rows of.
    public static func showMore(_ count: Int) -> String { count == 1 ? "Show 1 more" : "Show \(count) more" }

    /// For what a section did not keep at all: the Library has the rest.
    public static func seeAll(_ count: Int) -> String { count == 1 ? "See 1 more in the Library" : "See \(count) more in the Library" }

    public static func sectionTitle(_ section: ProjectGroup.Section) -> String? {
        switch section {
        case .all: return nil
        case .recent: return "Recent"
        case .earlier: return "Earlier"
        }
    }
}

// MARK: The list

extension TaskBoardListing {
    /// The interactive board page paired with the data page: `taskboard-{project}`. It is the page the vault graph joins to
    /// everything else (the data page is hidden from every listing).
    public var boardPageSlug: String { "taskboard-\(project)" }

    /// When the board last moved. `updated_at` is the data page's, which every write bumps; a board nobody has written to
    /// since it was made has only its creation.
    public var lastActivity: Date? { updatedAt ?? createdAt }
}

public struct ProjectGroup: Sendable, Equatable, Identifiable {
    public enum Section: String, Sendable { case all, recent, earlier }

    public let section: Section
    public let boards: [TaskBoardListing]

    public var id: String { section.rawValue }
    public var title: String? { ProjectsCopy.sectionTitle(section) }

    public init(section: Section, boards: [TaskBoardListing]) {
        self.section = section
        self.boards = boards
    }
}

public enum ProjectGrouping {
    /// A project that moved within this long is Recent.
    public static let recentWindow: TimeInterval = 14 * 24 * 3600
    /// Fewer projects than this are one list: headings over a handful of rows are clutter.
    public static let sectionsFrom = 8

    /// Most recently moved first; a board with no dates last; ties keep the server's order (newest made first).
    public static func ordered(_ boards: [TaskBoardListing]) -> [TaskBoardListing] {
        boards.enumerated().sorted { lhs, rhs in
            switch (lhs.element.lastActivity, rhs.element.lastActivity) {
            case let (a?, b?) where a != b: return a > b
            case (nil, .some): return false
            case (.some, nil): return true
            default: return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    /// One list for a few projects, Recent and Earlier for many. The list never has an empty heading.
    public static func groups(_ boards: [TaskBoardListing], now: Date = Date()) -> [ProjectGroup] {
        let sorted = ordered(boards)
        guard !sorted.isEmpty else { return [] }
        guard sorted.count >= sectionsFrom else { return [ProjectGroup(section: .all, boards: sorted)] }
        let cutoff = now.addingTimeInterval(-recentWindow)
        let recent = sorted.filter { ($0.lastActivity ?? .distantPast) >= cutoff }
        let earlier = sorted.filter { ($0.lastActivity ?? .distantPast) < cutoff }
        guard !recent.isEmpty, !earlier.isEmpty else { return [ProjectGroup(section: .all, boards: sorted)] }
        return [ProjectGroup(section: .recent, boards: recent), ProjectGroup(section: .earlier, boards: earlier)]
    }
}

// MARK: The board in the overview

public struct ProjectAgent: Sendable, Equatable, Identifiable {
    public let name: String
    public let tasks: Int
    public var id: String { name }

    public init(name: String, tasks: Int) {
        self.name = name
        self.tasks = tasks
    }
}

/// What the overview says about the board itself, from the list the board screen already loads (no second read).
public struct ProjectBoardDigest: Sendable, Equatable {
    public let summary: TaskBoardSummary
    /// The open tasks a person would look at first: leaves (an epic is its subtasks), in progress first, then blocked, in
    /// review and to do, the most recently touched first within each.
    public let focus: [BoardTask]
    /// Who is holding open work: agents by the name on their claim or assignment, the busiest first.
    public let agents: [ProjectAgent]

    public static let focusLimit = 5
    public static let agentLimit = 5

    /// The quiet line under the progress bar, as the list of projects words it: how much is done, and what is moving or stuck.
    public var statusLine: String {
        if summary.total == 0 { return "Nothing on it yet" }
        if summary.countable == 0 { return "Everything was set aside" }
        var parts = ["\(summary.done) of \(summary.countable) done"]
        let active = summary.count(.inProgress)
        if active > 0 { parts.append("\(active) in progress") }
        let blocked = summary.count(.blocked)
        if blocked > 0 { parts.append("\(blocked) blocked") }
        return parts.joined(separator: " \u{00B7} ")
    }

    public init(board: TaskBoard) {
        summary = TaskBoardSummary.compute(board)
        let order = Dictionary(uniqueKeysWithValues: BoardTaskStatus.boardOrder.enumerated().map { ($1, $0) })
        let open = board.tasks.filter { $0.status.isOpen }
        focus = Array(
            open.filter { board.subtasks(of: $0.id).isEmpty }
                .enumerated()
                .sorted { lhs, rhs in
                    let l = order[lhs.element.status] ?? .max, r = order[rhs.element.status] ?? .max
                    if l != r { return l < r }
                    let ld = lhs.element.updatedAt ?? .distantPast, rd = rhs.element.updatedAt ?? .distantPast
                    return ld != rd ? ld > rd : lhs.offset < rhs.offset
                }
                .map(\.element)
                .prefix(Self.focusLimit)
        )
        var counts: [String: Int] = [:]
        for task in open where task.isClaimedByAgent || task.lock != nil {
            if let holder = task.holder { counts[holder, default: 0] += 1 }
        }
        agents = counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(Self.agentLimit)
            .map { ProjectAgent(name: $0.key, tasks: $0.value) }
    }
}

// MARK: Names

/// Whether some text (a chat's title) is about a project, by its name. Whole words only, and strict on purpose: a wrong
/// "Mentions" row is worse than a missing one. A match is the board's title or the project id as a run of words, or two of
/// the title's distinctive words ("Choir module power budget" for "Eurorack Choir Module").
public struct ProjectNameMatcher: Sendable, Equatable {
    public let phrases: [[String]]
    public let words: [String]

    private static let ignored: Set<String> = [
        "the", "and", "for", "with", "from", "into", "new", "task", "tasks", "board", "boards", "project", "projects", "plan",
    ]
    private static let minimumPhrase = 3

    public init(project: String, title: String) {
        var found: [[String]] = []
        func add(_ tokens: [String]) {
            guard !tokens.isEmpty, tokens.joined(separator: " ").count >= Self.minimumPhrase, !found.contains(tokens) else { return }
            found.append(tokens)
        }
        let named = Self.tokens(title)
        add(named)
        var id = Self.tokens(project)
        add(id)
        // A project the app made has six random characters on the end (`lib/slug.ts`): the name is what is before them.
        if id.count > 1, let last = id.last, last.count == 6, last.contains(where: \.isNumber) {
            id.removeLast()
            add(id)
        }
        phrases = found
        var seen = Set<String>()
        words = named.filter { $0.count >= 3 && !Self.ignored.contains($0) && seen.insert($0).inserted }
    }

    public func matches(_ text: String) -> Bool {
        let have = Self.tokens(text)
        guard !have.isEmpty else { return false }
        if phrases.contains(where: { Self.contains(have, $0) }) { return true }
        guard !words.isEmpty else { return false }
        let present = Set(have)
        return words.filter(present.contains).count >= min(words.count, 2)
    }

    static func tokens(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    private static func contains(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count) where Array(haystack[start..<(start + needle.count)]) == needle {
            return true
        }
        return false
    }
}

// MARK: What else belongs

/// Why a row is under a project, strongest first. The overview says it on the row.
public enum ProjectRelation: String, Sendable, Codable, Hashable, CaseIterable {
    /// Joined to the project's board page by hand (a manual connection).
    case linked
    /// Carries the project's id as a tag.
    case tagged
    /// Joined to the board page by the server's guess from shared tags and title words.
    case related
    /// Its name or its text is about the project.
    case mentions

    public var rank: Int { Self.allCases.firstIndex(of: self) ?? Self.allCases.count }

    public var label: String {
        switch self {
        case .linked: return "Linked"
        case .tagged: return "Tagged"
        case .related: return "Possibly related"
        case .mentions: return "Mentions it"
        }
    }
}

public struct ProjectRelatedItem: Sendable, Codable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Codable { case page, memory, chat }

    public let kind: Kind
    /// What opens it: a page's slug, a memory's id, a conversation's id.
    public let key: String
    public let title: String
    public let detail: String
    public let relation: ProjectRelation
    public let date: Date?

    public var id: String { "\(kind.rawValue):\(key)" }

    public init(kind: Kind, key: String, title: String, detail: String = "", relation: ProjectRelation, date: Date? = nil) {
        self.kind = kind
        self.key = key
        self.title = title
        self.detail = detail
        self.relation = relation
        self.date = date
    }
}

public struct ProjectRelated: Sendable, Codable, Equatable {
    public var pages: [ProjectRelatedItem]
    public var memories: [ProjectRelatedItem]
    public var chats: [ProjectRelatedItem]
    /// Pages and memories joined to the board page only by the server's guess (`ProjectRelation.related`), newest first.
    /// They are not in `pages` or `memories`: the overview shows them behind "Show possibly related".
    public var possibly: [ProjectRelatedItem]
    /// How many each section found before the cut, for "See 4 more in the Library".
    public var pageTotal: Int
    public var memoryTotal: Int
    public var chatTotal: Int
    public var possiblyTotal: Int

    public init(
        pages: [ProjectRelatedItem] = [], memories: [ProjectRelatedItem] = [], chats: [ProjectRelatedItem] = [],
        possibly: [ProjectRelatedItem] = [],
        pageTotal: Int? = nil, memoryTotal: Int? = nil, chatTotal: Int? = nil, possiblyTotal: Int? = nil
    ) {
        self.pages = pages
        self.memories = memories
        self.chats = chats
        self.possibly = possibly
        self.pageTotal = pageTotal ?? pages.count
        self.memoryTotal = memoryTotal ?? memories.count
        self.chatTotal = chatTotal ?? chats.count
        self.possiblyTotal = possiblyTotal ?? possibly.count
    }

    /// Everything the three sections hold, not counting the guesses.
    public var confirmedTotal: Int { pageTotal + memoryTotal + chatTotal }

    /// How many rows of a section the screen shows before "Show 3 more".
    public static let visibleLimit = 6

    /// The rows of a section the screen shows: the first few, or all that were kept once the section is opened out.
    public static func shown(_ rows: [ProjectRelatedItem], opened: Bool) -> [ProjectRelatedItem] {
        opened ? rows : Array(rows.prefix(visibleLimit))
    }

    /// Nothing at all was found, not even a guess.
    public var isEmpty: Bool { confirmedTotal + possiblyTotal == 0 }

    public static let empty = ProjectRelated()
}

/// What the builder is given, all of it already read: the screen decides when and how.
public struct ProjectRelatedInput: Sendable {
    public var project: String
    public var title: String
    /// Row ids of the project's board page (and, when known, its data page): what a connection names them by.
    public var anchors: Set<String>
    public var connections: LibraryConnections
    public var pages: [LibraryGraphPage]
    public var memories: [MemoryItem]
    public var conversations: [ChatConversation]

    public init(
        project: String, title: String, anchors: Set<String>, connections: LibraryConnections = LibraryConnections(),
        pages: [LibraryGraphPage] = [], memories: [MemoryItem] = [], conversations: [ChatConversation] = []
    ) {
        self.project = project
        self.title = title
        self.anchors = anchors
        self.connections = connections
        self.pages = pages
        self.memories = memories
        self.conversations = conversations
    }
}

public enum ProjectRelatedBuilder {
    /// The most rows one section keeps (the screen shows `ProjectRelated.visibleLimit` of them until it is opened out); a
    /// section that had more says how many, and the Library has the rest.
    public static let sectionLimit = 40

    public static func build(_ input: ProjectRelatedInput) -> ProjectRelated {
        let project = input.project.lowercased()
        let own: Set<String> = ["tasks-\(input.project)", "taskboard-\(input.project)"]
        let matcher = ProjectNameMatcher(project: input.project, title: input.title)

        func carries(_ tags: [String]) -> Bool { tags.contains { $0.lowercased() == project } }

        // Pages: connections to the board page, then pages tagged with the project.
        let pagesByRow = Dictionary(input.pages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var pages: [String: ProjectRelatedItem] = [:]
        func keep(_ item: ProjectRelatedItem, in found: inout [String: ProjectRelatedItem]) {
            if let existing = found[item.key], existing.relation.rank <= item.relation.rank { return }
            found[item.key] = item
        }
        func page(_ page: LibraryGraphPage, _ relation: ProjectRelation) -> ProjectRelatedItem {
            ProjectRelatedItem(
                kind: .page, key: page.slug, title: page.title,
                detail: ArtifactTypeName.name(type: page.type, isJsx: page.type == "react"), relation: relation
            )
        }
        for edge in input.connections.pageLinks {
            let other: String
            if input.anchors.contains(edge.aId) { other = edge.bId } else if input.anchors.contains(edge.bId) { other = edge.aId } else { continue }
            guard !input.anchors.contains(other), let found = pagesByRow[other], !own.contains(found.slug) else { continue }
            // Every board page carries the tag "taskboard" and a title ending "Task Board", so the server's guess from shared
            // tags and title words (`lib/connections.ts` suggestAutoTargets) joins each board page to the others. Another
            // board found that way is noise; one joined by hand is not.
            if edge.isAuto, found.tags.contains("taskboard") { continue }
            keep(page(found, edge.isAuto ? .related : .linked), in: &pages)
        }
        for found in input.pages where carries(found.tags) && !own.contains(found.slug) && !input.anchors.contains(found.id) {
            keep(page(found, .tagged), in: &pages)
        }

        // Memories: bridges to the board page, tagged, and titled for it. A chat's own mirror memory is a
        // transcript, not a memory the person kept; chats have their own section.
        let memoriesByID = Dictionary(input.memories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var memories: [String: ProjectRelatedItem] = [:]
        func memory(id: String, title: String, source: String, date: Date?, _ relation: ProjectRelation) -> ProjectRelatedItem {
            ProjectRelatedItem(kind: .memory, key: id, title: title, detail: MemorySource.label(source), relation: relation, date: date)
        }
        for bridge in input.connections.bridges where input.anchors.contains(bridge.artifactId) {
            guard let found = memoriesByID[bridge.memoryId], found.source != "chat" else { continue }
            keep(memory(id: found.id, title: found.title, source: found.source, date: found.createdAt, bridge.kind == .manual ? .linked : .related), in: &memories)
        }
        for found in input.memories where found.source != "chat" && carries(found.tags) {
            keep(memory(id: found.id, title: found.title, source: found.source, date: found.createdAt, .tagged), in: &memories)
        }
        for found in input.memories where found.source != "chat" && matcher.matches(found.title) {
            keep(memory(id: found.id, title: found.title, source: found.source, date: found.createdAt, .mentions), in: &memories)
        }

        // Chats: by name only. Nothing on the server joins a conversation to a project.
        var chats: [String: ProjectRelatedItem] = [:]
        for chat in input.conversations where matcher.matches(chat.title) {
            keep(
                ProjectRelatedItem(kind: .chat, key: chat.id, title: chat.title, detail: chat.platform.label, relation: .mentions, date: chat.updatedAt ?? chat.createdAt),
                in: &chats
            )
        }

        func cut(_ found: [ProjectRelatedItem]) -> (rows: [ProjectRelatedItem], total: Int) {
            let sorted = found.sorted { lhs, rhs in
                if lhs.relation.rank != rhs.relation.rank { return lhs.relation.rank < rhs.relation.rank }
                let ld = lhs.date ?? .distantPast, rd = rhs.date ?? .distantPast
                if ld != rd { return ld > rd }
                switch lhs.title.localizedCaseInsensitiveCompare(rhs.title) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: return lhs.id < rhs.id   // dictionaries have no order: break the last tie the same way each time
                }
            }
            return (Array(sorted.prefix(sectionLimit)), sorted.count)
        }
        // The server's guesses are held back from the sections they would otherwise crowd (they sort below Linked and Tagged,
        // but above Mentions), and kept on their own.
        func confirmed(_ found: [String: ProjectRelatedItem]) -> [ProjectRelatedItem] { found.values.filter { $0.relation != .related } }
        let guesses = (Array(pages.values) + Array(memories.values)).filter { $0.relation == .related }
        let p = cut(confirmed(pages)), m = cut(confirmed(memories)), c = cut(Array(chats.values)), g = cut(guesses)
        return ProjectRelated(
            pages: p.rows, memories: m.rows, chats: c.rows, possibly: g.rows,
            pageTotal: p.total, memoryTotal: m.total, chatTotal: c.total, possiblyTotal: g.total
        )
    }
}
