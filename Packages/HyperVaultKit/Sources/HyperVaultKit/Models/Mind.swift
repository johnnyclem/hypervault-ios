import Foundation

// Git for a Mind (docs/prd-8-git-mind.md): branches, commits, diffs, merges,
// time travel. Sources: app/api/mind/*/route.ts and lib/mind/*.

// MARK: Shared vocabulary

/// Who wrote a commit: you, an agent holding one of your keys, or HyperVault.
public enum MindAuthorKind: String, Sendable, Codable, Hashable {
    case user, agent, system

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MindAuthorKind(rawValue: raw) ?? .user
    }

    /// "You", "Agent hv_ab12cdef", "HyperVault".
    public func label(keyPrefix: String? = nil) -> String {
        switch self {
        case .user: return "You"
        case .agent:
            if let keyPrefix, !keyPrefix.isEmpty { return "Agent \(keyPrefix)" }
            return "An agent"
        case .system: return "HyperVault"
        }
    }
}

public enum MindOp: String, Sendable, Codable, Hashable {
    case create, update, delete

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MindOp(rawValue: raw) ?? .update
    }

    /// The word a person would use for it.
    public var verb: String {
        switch self {
        case .create: return "Added"
        case .update: return "Edited"
        case .delete: return "Forgotten"
        }
    }
}

// MARK: Branches

public struct MindBranch: Sendable, Codable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let isDefault: Bool
    public let headCommitId: String?
    public let createdAt: Date?
    public let memoryCount: Int

    public init(id: String, name: String, isDefault: Bool = false, headCommitId: String? = nil, createdAt: Date? = nil, memoryCount: Int = 0) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.headCommitId = headCommitId
        self.createdAt = createdAt
        self.memoryCount = memoryCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        name = try c.decode(String.self, forKey: .name)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? name
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? (name == MindBranchName.defaultName)
        headCommitId = try c.decodeIfPresent(String.self, forKey: .headCommitId)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        memoryCount = try c.decodeIfPresent(Int.self, forKey: .memoryCount) ?? 0
    }

    enum Keys: String, CodingKey { case id, name, isDefault, headCommitId, createdAt, memoryCount }
}

/// `GET /api/mind/branches`.
public struct MindBranchList: Sendable, Codable, Equatable {
    public let branches: [MindBranch]

    public init(branches: [MindBranch] = []) {
        self.branches = branches
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        branches = try c.decodeIfPresent([MindBranch].self, forKey: .branches) ?? []
    }

    enum Keys: String, CodingKey { case branches }

    /// `main` first, then the rest by name.
    public var ordered: [MindBranch] {
        branches.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

/// `POST /api/mind/branches`.
public struct MindBranchCreated: Sendable, Codable, Equatable {
    public let id: String
    public let name: String
    public let from: String
    public let message: String

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        name = try c.decode(String.self, forKey: .name)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? name
        from = try c.decodeIfPresent(String.self, forKey: .from) ?? MindBranchName.defaultName
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
    }

    enum Keys: String, CodingKey { case id, name, from, message }
}

/// `DELETE /api/mind/branches/[name]`.
public struct MindBranchDeleted: Sendable, Codable, Equatable {
    public let deleted: String
    public let message: String

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        deleted = try c.decodeIfPresent(String.self, forKey: .deleted) ?? ""
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
    }

    enum Keys: String, CodingKey { case deleted, message }
}

/// Branch names, as lib/mind/branches.ts spells them.
public enum MindBranchName {
    public static let defaultName = "main"

    /// `^[a-z0-9][a-z0-9/_-]{0,62}$`
    public static func isValid(_ name: String) -> Bool {
        let scalars = Array(name.unicodeScalars)
        guard (1...63).contains(scalars.count) else { return false }
        func alnum(_ s: Unicode.Scalar) -> Bool {
            (s >= "a" && s <= "z") || (s >= "0" && s <= "9")
        }
        guard alnum(scalars[0]) else { return false }
        return scalars.dropFirst().allSatisfy { alnum($0) || $0 == "/" || $0 == "_" || $0 == "-" }
    }

    /// What someone typed, made into a name: trimmed, lowercased, spaces to dashes.
    public static func normalized(_ input: String) -> String {
        input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: "-")
    }

    /// The server's sentence for a name it would refuse, or nil when it is fine.
    public static func validationMessage(for name: String, existing: [String] = []) -> String? {
        if name == defaultName { return "main already exists. It is the default branch." }
        if !isValid(name) {
            return "Branch names are lowercase letters, digits, and /_- (max 63 chars, must start alphanumeric)."
        }
        if existing.contains(name) { return "A branch named \"\(name)\" already exists." }
        return nil
    }
}

// MARK: Commits

public struct MindChangeCounts: Sendable, Codable, Hashable {
    public let created: Int
    public let updated: Int
    public let deleted: Int
    public let links: Int

    public init(created: Int = 0, updated: Int = 0, deleted: Int = 0, links: Int = 0) {
        self.created = created
        self.updated = updated
        self.deleted = deleted
        self.links = links
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        created = try c.decodeIfPresent(Int.self, forKey: .created) ?? 0
        updated = try c.decodeIfPresent(Int.self, forKey: .updated) ?? 0
        deleted = try c.decodeIfPresent(Int.self, forKey: .deleted) ?? 0
        links = try c.decodeIfPresent(Int.self, forKey: .links) ?? 0
    }

    enum Keys: String, CodingKey { case created, updated, deleted, links }

    public var total: Int { created + updated + deleted + links }

    /// "2 added · 1 edited · 1 forgotten · 3 links"; empty for a commit that changed nothing.
    /// Each count is held to its noun and each dot to the item before it, so a long line breaks
    /// between items and never leaves a lone number at the end of a line.
    public var summary: String {
        var parts: [String] = []
        if created > 0 { parts.append(MindSummaryText.count(created, "added")) }
        if updated > 0 { parts.append(MindSummaryText.count(updated, "edited")) }
        if deleted > 0 { parts.append(MindSummaryText.count(deleted, "forgotten")) }
        if links > 0 { parts.append(MindSummaryText.count(links, links == 1 ? "link" : "links")) }
        return MindSummaryText.join(parts)
    }
}

/// How the one-line tallies ("2 added · 1 edited") are put together, so they wrap well.
enum MindSummaryText {
    private static let tie = "\u{00A0}"

    /// A count and its words, joined so they cannot be split across two lines.
    static func count(_ number: Int, _ words: String) -> String {
        "\(number)" + tie + words.replacingOccurrences(of: " ", with: tie)
    }

    /// Items with a dot between them. The dot stays with the item before it; the break falls after it.
    static func join(_ parts: [String]) -> String {
        parts.joined(separator: tie + "\u{00B7} ")
    }
}

/// What kind of change a commit was, for the icon beside it.
public enum MindCommitKind: Sendable, Hashable {
    case memorize, edit, forget, merge, revert, importing, link, other
}

public struct MindCommit: Sendable, Codable, Identifiable, Hashable {
    public let id: String
    public let message: String
    public let authorKind: MindAuthorKind
    public let authorKeyPrefix: String?
    public let parentCommitId: String?
    public let mergeParentCommitId: String?
    public let createdAt: Date?
    public let changeCounts: MindChangeCounts

    public init(
        id: String, message: String, authorKind: MindAuthorKind = .user, authorKeyPrefix: String? = nil,
        parentCommitId: String? = nil, mergeParentCommitId: String? = nil, createdAt: Date? = nil,
        changeCounts: MindChangeCounts = MindChangeCounts()
    ) {
        self.id = id
        self.message = message
        self.authorKind = authorKind
        self.authorKeyPrefix = authorKeyPrefix
        self.parentCommitId = parentCommitId
        self.mergeParentCommitId = mergeParentCommitId
        self.createdAt = createdAt
        self.changeCounts = changeCounts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        authorKind = try c.decodeIfPresent(MindAuthorKind.self, forKey: .authorKind) ?? .user
        authorKeyPrefix = try c.decodeIfPresent(String.self, forKey: .authorKeyPrefix)
        parentCommitId = try c.decodeIfPresent(String.self, forKey: .parentCommitId)
        mergeParentCommitId = try c.decodeIfPresent(String.self, forKey: .mergeParentCommitId)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        changeCounts = try c.decodeIfPresent(MindChangeCounts.self, forKey: .changeCounts) ?? MindChangeCounts()
    }

    enum Keys: String, CodingKey {
        case id, message, authorKind, authorKeyPrefix, parentCommitId, mergeParentCommitId, createdAt, changeCounts
    }

    public var shortId: String { String(id.prefix(8)) }
    public var isMerge: Bool { mergeParentCommitId != nil }
    public var author: String { authorKind.label(keyPrefix: authorKeyPrefix) }

    public var kind: MindCommitKind {
        if isMerge || message.hasPrefix("merge ") { return .merge }
        let lower = message.lowercased()
        if lower.hasPrefix("revert") { return .revert }
        if lower.hasPrefix("import") { return .importing }
        if lower.hasPrefix("forget") { return .forget }
        if lower.hasPrefix("edit") { return .edit }
        if lower.hasPrefix("memorize") { return .memorize }
        if lower.hasPrefix("link") || lower.hasPrefix("unlink") { return .link }
        let counts = changeCounts
        if counts.deleted > 0 && counts.created == 0 && counts.updated == 0 { return .forget }
        if counts.updated > 0 && counts.created == 0 { return .edit }
        if counts.created > 0 { return .memorize }
        if counts.links > 0 { return .link }
        return .other
    }
}

/// `GET /api/mind/commits`: first-parent history of a branch, newest first.
public struct MindCommitLog: Sendable, Codable, Equatable {
    public let branch: String
    public let commits: [MindCommit]

    public init(branch: String = MindBranchName.defaultName, commits: [MindCommit] = []) {
        self.branch = branch
        self.commits = commits
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? MindBranchName.defaultName
        commits = try c.decodeIfPresent([MindCommit].self, forKey: .commits) ?? []
    }

    enum Keys: String, CodingKey { case branch, commits }
}

// MARK: Diffs

public struct MindDiffLine: Sendable, Codable, Hashable {
    public enum Kind: String, Sendable, Codable, Hashable {
        case add, del, ctx

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .ctx
        }
    }

    public let kind: Kind
    public let text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

public struct MindDiffHunk: Sendable, Codable, Hashable {
    public let oldStart: Int
    public let oldLines: Int
    public let newStart: Int
    public let newLines: Int
    public let lines: [MindDiffLine]

    public init(oldStart: Int, oldLines: Int, newStart: Int, newLines: Int, lines: [MindDiffLine]) {
        self.oldStart = oldStart
        self.oldLines = oldLines
        self.newStart = newStart
        self.newLines = newLines
        self.lines = lines
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        oldStart = try c.decodeIfPresent(Int.self, forKey: .oldStart) ?? 0
        oldLines = try c.decodeIfPresent(Int.self, forKey: .oldLines) ?? 0
        newStart = try c.decodeIfPresent(Int.self, forKey: .newStart) ?? 0
        newLines = try c.decodeIfPresent(Int.self, forKey: .newLines) ?? 0
        lines = try c.decodeIfPresent([MindDiffLine].self, forKey: .lines) ?? []
    }

    enum Keys: String, CodingKey { case oldStart, oldLines, newStart, newLines, lines }
}

/// Line hunks between two versions of one memory (lib/mind/diff.ts `TextDiff`).
public struct MindTextDiff: Sendable, Codable, Hashable {
    public let hunks: [MindDiffHunk]
    /// The texts were too large to compare line by line: read it as "replaced".
    public let oversize: Bool

    public init(hunks: [MindDiffHunk] = [], oversize: Bool = false) {
        self.hunks = hunks
        self.oversize = oversize
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        hunks = try c.decodeIfPresent([MindDiffHunk].self, forKey: .hunks) ?? []
        oversize = try c.decodeIfPresent(Bool.self, forKey: .oversize) ?? false
    }

    enum Keys: String, CodingKey { case hunks, oversize }
}

/// One row of a rendered diff: a line with its numbers, or a fold of unchanged
/// lines between two hunks.
public struct MindDiffRow: Sendable, Identifiable, Hashable {
    public enum Kind: Sendable, Hashable { case add, del, ctx, gap }

    public let id: Int
    public let kind: Kind
    public let text: String
    public let oldLine: Int?
    public let newLine: Int?
    /// For a `.gap`: how many unchanged lines it stands for.
    public let skipped: Int?

    public var isChange: Bool { kind == .add || kind == .del }
}

extension MindTextDiff {
    /// "\ No newline at end of file" is jsdiff's note, not a line of the memory.
    private static let noNewlineNote = " No newline at end of file"

    /// The hunks flattened into rows with line numbers, and a gap row where
    /// unchanged lines were left out.
    public var rows: [MindDiffRow] {
        var out: [MindDiffRow] = []
        var previousOldEnd: Int?
        func append(_ kind: MindDiffRow.Kind, _ text: String, old: Int?, new: Int?, skipped: Int? = nil) {
            out.append(MindDiffRow(id: out.count, kind: kind, text: text, oldLine: old, newLine: new, skipped: skipped))
        }
        for hunk in hunks {
            let gap = hunk.oldStart - (previousOldEnd ?? 1)
            if gap > 0 { append(.gap, "", old: nil, new: nil, skipped: gap) }
            var old = hunk.oldStart
            var new = hunk.newStart
            for line in hunk.lines {
                switch line.kind {
                case .add:
                    append(.add, line.text, old: nil, new: new)
                    new += 1
                case .del:
                    append(.del, line.text, old: old, new: nil)
                    old += 1
                case .ctx:
                    if line.text == Self.noNewlineNote { continue }
                    append(.ctx, line.text, old: old, new: new)
                    old += 1
                    new += 1
                }
            }
            previousOldEnd = hunk.oldStart + hunk.oldLines
        }
        return out
    }

    public var addedLines: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .add }.count } }
    public var removedLines: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .del }.count } }
    public var hasTextChanges: Bool { oversize || addedLines > 0 || removedLines > 0 }

    /// "+3 −1", or a sentence when there is no line-level story to tell.
    public var summary: String {
        if oversize { return "Replaced (too large to compare line by line)" }
        if addedLines == 0 && removedLines == 0 { return "No text changes" }
        return "+\(addedLines) \u{2212}\(removedLines)"
    }
}

/// A memory in a diff's added or removed list.
public struct MindDiffMemory: Sendable, Codable, Identifiable, Hashable {
    public let id: String
    public let title: String
    public let tags: [String]

    public init(id: String, title: String, tags: [String] = []) {
        self.id = id
        self.title = title
        self.tags = tags
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled memory"
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
    }

    enum Keys: String, CodingKey { case id, title, tags }
}

public struct MindMemoryChange: Sendable, Codable, Identifiable, Hashable {
    public let id: String
    public let titleFrom: String
    public let titleTo: String
    public let tagsAdded: [String]
    public let tagsRemoved: [String]
    public let contentChanged: Bool
    public let diff: MindTextDiff

    public init(
        id: String, titleFrom: String, titleTo: String, tagsAdded: [String] = [], tagsRemoved: [String] = [],
        contentChanged: Bool = false, diff: MindTextDiff = MindTextDiff()
    ) {
        self.id = id
        self.titleFrom = titleFrom
        self.titleTo = titleTo
        self.tagsAdded = tagsAdded
        self.tagsRemoved = tagsRemoved
        self.contentChanged = contentChanged
        self.diff = diff
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        titleFrom = try c.decodeIfPresent(String.self, forKey: .titleFrom) ?? ""
        titleTo = try c.decodeIfPresent(String.self, forKey: .titleTo) ?? titleFrom
        tagsAdded = try c.decodeIfPresent([String].self, forKey: .tagsAdded) ?? []
        tagsRemoved = try c.decodeIfPresent([String].self, forKey: .tagsRemoved) ?? []
        contentChanged = try c.decodeIfPresent(Bool.self, forKey: .contentChanged) ?? false
        diff = try c.decodeIfPresent(MindTextDiff.self, forKey: .diff) ?? MindTextDiff()
    }

    enum Keys: String, CodingKey { case id, titleFrom, titleTo, tagsAdded, tagsRemoved, contentChanged, diff }

    public var renamed: Bool { titleFrom != titleTo }
}

public struct MindLinkRef: Sendable, Codable, Hashable, Identifiable {
    public let aId: String
    public let bId: String
    public let kind: String

    public var id: String { aId < bId ? "\(aId):\(bId)" : "\(bId):\(aId)" }

    public init(aId: String, bId: String, kind: String = "auto") {
        self.aId = aId
        self.bId = bId
        self.kind = kind
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        aId = try c.decode(String.self, forKey: .aId)
        bId = try c.decode(String.self, forKey: .bId)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "auto"
    }

    enum Keys: String, CodingKey { case aId, bId, kind }
}

/// Where a diff was taken: the ref as asked, and the commit it resolved to.
public struct MindDiffPoint: Sendable, Codable, Hashable {
    public let ref: String
    public let commitId: String?

    public init(ref: String, commitId: String? = nil) {
        self.ref = ref
        self.commitId = commitId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        ref = try c.decodeIfPresent(String.self, forKey: .ref) ?? ""
        commitId = try c.decodeIfPresent(String.self, forKey: .commitId)
    }

    enum Keys: String, CodingKey { case ref, commitId }
}

/// `GET /api/mind/diff?from=&to=`: what changed in the whole mind.
public struct MindStateDiff: Sendable, Codable, Hashable {
    public let from: MindDiffPoint
    public let to: MindDiffPoint
    public let added: [MindDiffMemory]
    public let removed: [MindDiffMemory]
    public let changed: [MindMemoryChange]
    public let linksAdded: [MindLinkRef]
    public let linksRemoved: [MindLinkRef]

    public init(
        from: MindDiffPoint, to: MindDiffPoint, added: [MindDiffMemory] = [], removed: [MindDiffMemory] = [],
        changed: [MindMemoryChange] = [], linksAdded: [MindLinkRef] = [], linksRemoved: [MindLinkRef] = []
    ) {
        self.from = from
        self.to = to
        self.added = added
        self.removed = removed
        self.changed = changed
        self.linksAdded = linksAdded
        self.linksRemoved = linksRemoved
    }

    // The wire nests these: { memories: { added, removed, changed }, links: { added, removed } }.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        from = try c.decodeIfPresent(MindDiffPoint.self, forKey: .from) ?? MindDiffPoint(ref: "")
        to = try c.decodeIfPresent(MindDiffPoint.self, forKey: .to) ?? MindDiffPoint(ref: "")
        let memories = try c.decodeIfPresent(Memories.self, forKey: .memories)
        added = memories?.added ?? []
        removed = memories?.removed ?? []
        changed = memories?.changed ?? []
        let links = try c.decodeIfPresent(Links.self, forKey: .links)
        linksAdded = links?.added ?? []
        linksRemoved = links?.removed ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(from, forKey: .from)
        try c.encode(to, forKey: .to)
        try c.encode(Memories(added: added, removed: removed, changed: changed), forKey: .memories)
        try c.encode(Links(added: linksAdded, removed: linksRemoved), forKey: .links)
    }

    enum Keys: String, CodingKey { case from, to, memories, links }

    struct Memories: Codable, Hashable {
        var added: [MindDiffMemory]
        var removed: [MindDiffMemory]
        var changed: [MindMemoryChange]

        init(added: [MindDiffMemory], removed: [MindDiffMemory], changed: [MindMemoryChange]) {
            self.added = added
            self.removed = removed
            self.changed = changed
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            added = try c.decodeIfPresent([MindDiffMemory].self, forKey: .added) ?? []
            removed = try c.decodeIfPresent([MindDiffMemory].self, forKey: .removed) ?? []
            changed = try c.decodeIfPresent([MindMemoryChange].self, forKey: .changed) ?? []
        }

        enum Keys: String, CodingKey { case added, removed, changed }
    }

    struct Links: Codable, Hashable {
        var added: [MindLinkRef]
        var removed: [MindLinkRef]

        init(added: [MindLinkRef], removed: [MindLinkRef]) {
            self.added = added
            self.removed = removed
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            added = try c.decodeIfPresent([MindLinkRef].self, forKey: .added) ?? []
            removed = try c.decodeIfPresent([MindLinkRef].self, forKey: .removed) ?? []
        }

        enum Keys: String, CodingKey { case added, removed }
    }

    public var isEmpty: Bool {
        added.isEmpty && removed.isEmpty && changed.isEmpty && linksAdded.isEmpty && linksRemoved.isEmpty
    }

    public var summary: String {
        var parts: [String] = []
        if !added.isEmpty { parts.append(MindSummaryText.count(added.count, "added")) }
        if !changed.isEmpty { parts.append(MindSummaryText.count(changed.count, "edited")) }
        if !removed.isEmpty { parts.append(MindSummaryText.count(removed.count, "forgotten")) }
        let links = linksAdded.count + linksRemoved.count
        if links > 0 { parts.append(MindSummaryText.count(links, links == 1 ? "link change" : "link changes")) }
        return MindSummaryText.join(parts)
    }

    /// Titles for the ids a diff mentions, so a link can be read as two names.
    public var titles: [String: String] {
        var map: [String: String] = [:]
        for m in added { map[m.id] = m.title }
        for m in removed { map[m.id] = m.title }
        for m in changed { map[m.id] = m.titleTo.isEmpty ? m.titleFrom : m.titleTo }
        return map
    }
}

/// `GET /api/mind/diff?from=&to=&memory_id=`: one memory between two points.
public struct MindMemoryDiff: Sendable, Codable, Hashable {
    public enum Status: String, Sendable, Codable, Hashable {
        case added, removed, changed

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: raw) ?? .changed
        }
    }

    public let from: MindDiffPoint
    public let to: MindDiffPoint
    public let memoryId: String
    public let titleFrom: String?
    public let titleTo: String?
    public let tagsAdded: [String]
    public let tagsRemoved: [String]
    public let status: Status
    public let diff: MindTextDiff

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        from = try c.decodeIfPresent(MindDiffPoint.self, forKey: .from) ?? MindDiffPoint(ref: "")
        to = try c.decodeIfPresent(MindDiffPoint.self, forKey: .to) ?? MindDiffPoint(ref: "")
        memoryId = try c.decodeIfPresent(String.self, forKey: .memoryId) ?? ""
        titleFrom = try c.decodeIfPresent(String.self, forKey: .titleFrom)
        titleTo = try c.decodeIfPresent(String.self, forKey: .titleTo)
        tagsAdded = try c.decodeIfPresent([String].self, forKey: .tagsAdded) ?? []
        tagsRemoved = try c.decodeIfPresent([String].self, forKey: .tagsRemoved) ?? []
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .changed
        diff = try c.decodeIfPresent(MindTextDiff.self, forKey: .diff) ?? MindTextDiff()
    }

    enum Keys: String, CodingKey { case from, to, memoryId, titleFrom, titleTo, tagsAdded, tagsRemoved, status, diff }
}

/// A point to compare or travel to: a branch, a commit, or a moment.
public enum MindRef: Sendable, Hashable {
    case branch(String)
    case commit(String)
    case moment(Date)

    /// What the server's `from=`, `to=` and `at=` take.
    public var wire: String {
        switch self {
        case .branch(let name): return name
        case .commit(let id): return id
        case .moment(let date): return HVDate.format(date)
        }
    }

    public var label: String {
        switch self {
        case .branch(let name): return name
        case .commit(let id): return String(id.prefix(8))
        case .moment(let date): return date.formatted(date: .abbreviated, time: .shortened)
        }
    }

    /// What a Compare field shows for this point: the branch, the commit's message, or, for a moment,
    /// its kind. The date and time of a moment sit in the pickers under the field, so the field does
    /// not say them a second time.
    public func fieldText(commits: [MindCommit] = []) -> String {
        switch self {
        case .branch(let name):
            return name
        case .commit(let id):
            if let commit = commits.first(where: { $0.id == id }) { return "\(commit.message) (\(commit.shortId))" }
            return "Commit \(id.prefix(8))"
        case .moment:
            return "A moment in time"
        }
    }
}

// MARK: Time travel

public struct MindStateMemory: Sendable, Codable, Identifiable, Hashable {
    public let id: String
    public let title: String
    public let summary: String
    public let tags: [String]
    public let source: String
    public let committedAt: Date?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled memory"
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "manual"
        committedAt = try c.decodeIfPresent(Date.self, forKey: .committedAt)
    }

    enum Keys: String, CodingKey { case id, title, summary, tags, source, committedAt }
}

/// `GET /api/mind/state?at=`: the whole mind as it stood at a point.
public struct MindState: Sendable, Codable, Hashable {
    public let at: String
    public let commitId: String
    public let memories: [MindStateMemory]
    public let links: [MindLinkRef]
    public let message: String

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        at = try c.decodeIfPresent(String.self, forKey: .at) ?? ""
        commitId = try c.decodeIfPresent(String.self, forKey: .commitId) ?? ""
        memories = try c.decodeIfPresent([MindStateMemory].self, forKey: .memories) ?? []
        links = try c.decodeIfPresent([MindLinkRef].self, forKey: .links) ?? []
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
    }

    enum Keys: String, CodingKey { case at, commitId, memories, links, message }
}

// MARK: Revert

/// `POST /api/mind/revert`: restore a memory to an earlier revision, or bring
/// back one that was forgotten. The restore lands as a new commit.
public struct MindReverted: Sendable, Codable, Equatable {
    public let commitId: String
    public let memoryId: String
    public let title: String
    public let branch: String
    public let message: String

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        commitId = try c.decodeIfPresent(String.self, forKey: .commitId) ?? ""
        let restored = try c.decodeIfPresent(Restored.self, forKey: .restored)
        memoryId = restored?.memoryId ?? ""
        title = restored?.title ?? ""
        branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? MindBranchName.defaultName
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(commitId, forKey: .commitId)
        try c.encode(Restored(memoryId: memoryId, title: title), forKey: .restored)
        try c.encode(branch, forKey: .branch)
        try c.encode(message, forKey: .message)
    }

    enum Keys: String, CodingKey { case commitId, restored, branch, message }

    struct Restored: Codable {
        var memoryId: String
        var title: String
    }
}

// MARK: Merge

/// A memory as one side of a merge holds it.
public struct MindSnapshot: Sendable, Codable, Hashable {
    public let memoryId: String
    public let title: String
    public let content: String
    public let summary: String
    public let tags: [String]
    public let source: String

    public init(memoryId: String, title: String, content: String, summary: String = "", tags: [String] = [], source: String = "manual") {
        self.memoryId = memoryId
        self.title = title
        self.content = content
        self.summary = summary
        self.tags = tags
        self.source = source
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        memoryId = try c.decodeIfPresent(String.self, forKey: .memoryId) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled memory"
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "manual"
    }

    enum Keys: String, CodingKey { case memoryId, title, content, summary, tags, source }
}

/// One memory both branches changed (a 409 from `POST /api/mind/merge`).
/// A missing side means that branch forgot the memory.
public struct MindMergeConflict: Sendable, Codable, Identifiable, Hashable {
    public let memoryId: String
    public let base: MindSnapshot?
    public let ours: MindSnapshot?
    public let theirs: MindSnapshot?
    public let hunksOurs: MindTextDiff
    public let hunksTheirs: MindTextDiff

    public var id: String { memoryId }

    public init(
        memoryId: String, base: MindSnapshot? = nil, ours: MindSnapshot? = nil, theirs: MindSnapshot? = nil,
        hunksOurs: MindTextDiff = MindTextDiff(), hunksTheirs: MindTextDiff = MindTextDiff()
    ) {
        self.memoryId = memoryId
        self.base = base
        self.ours = ours
        self.theirs = theirs
        self.hunksOurs = hunksOurs
        self.hunksTheirs = hunksTheirs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        memoryId = try c.decode(String.self, forKey: .memoryId)
        base = try c.decodeIfPresent(MindSnapshot.self, forKey: .base)
        ours = try c.decodeIfPresent(MindSnapshot.self, forKey: .ours)
        theirs = try c.decodeIfPresent(MindSnapshot.self, forKey: .theirs)
        hunksOurs = try c.decodeIfPresent(MindTextDiff.self, forKey: .hunksOurs) ?? MindTextDiff()
        hunksTheirs = try c.decodeIfPresent(MindTextDiff.self, forKey: .hunksTheirs) ?? MindTextDiff()
    }

    enum Keys: String, CodingKey { case memoryId, base, ours, theirs, hunksOurs, hunksTheirs }

    public enum Situation: Sendable, Hashable {
        /// Both branches edited it differently.
        case bothEdited
        /// The branch being merged into forgot it; the other edited it.
        case forgottenHere
        /// The branch being merged forgot it; the other edited it.
        case forgottenThere
    }

    public var situation: Situation {
        if ours == nil { return .forgottenHere }
        if theirs == nil { return .forgottenThere }
        return .bothEdited
    }

    public var title: String { ours?.title ?? theirs?.title ?? base?.title ?? "Untitled memory" }

    /// A starting point for a hand-merged version: our lines, then any of
    /// theirs we do not already have.
    public var combinedContent: String {
        let ourLines = (ours?.content ?? "").components(separatedBy: "\n")
        guard let theirs else { return ours?.content ?? "" }
        guard ours != nil else { return theirs.content }
        var seen = Set(ourLines)
        var lines = ourLines
        for line in theirs.content.components(separatedBy: "\n") where !line.isEmpty && !seen.contains(line) {
            lines.append(line)
            seen.insert(line)
        }
        return lines.joined(separator: "\n")
    }

    public var combinedTags: [String] {
        var tags = ours?.tags ?? []
        for tag in theirs?.tags ?? [] where !tags.contains(tag) { tags.append(tag) }
        return tags
    }
}

/// How one conflict is settled.
public enum MindResolution: Sendable, Hashable {
    case ours
    case theirs
    case custom(title: String, content: String, tags: [String]?)

    var wire: JSONValue {
        switch self {
        case .ours: return "ours"
        case .theirs: return "theirs"
        case .custom(let title, let content, let tags):
            var object: [String: JSONValue] = ["title": .string(title), "content": .string(content)]
            if let tags { object["tags"] = .array(tags.map { .string($0) }) }
            return .object(object)
        }
    }
}

/// Which side a bulk choice takes.
public enum MindSide: Sendable, Hashable {
    case ours, theirs
}

public struct MindMergeResult: Sendable, Codable, Equatable {
    public let commitId: String?
    public let created: Int
    public let updated: Int
    public let deleted: Int
    public let linksChanged: Int
    public let message: String

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        commitId = try c.decodeIfPresent(String.self, forKey: .commitId)
        let merged = try c.decodeIfPresent(MindChangeCounts.self, forKey: .merged)
        created = merged?.created ?? 0
        updated = merged?.updated ?? 0
        deleted = merged?.deleted ?? 0
        linksChanged = try c.decodeIfPresent(Int.self, forKey: .linksChanged) ?? 0
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encodeIfPresent(commitId, forKey: .commitId)
        try c.encode(MindChangeCounts(created: created, updated: updated, deleted: deleted), forKey: .merged)
        try c.encode(linksChanged, forKey: .linksChanged)
        try c.encode(message, forKey: .message)
    }

    enum Keys: String, CodingKey { case commitId, merged, linksChanged, message }

    /// The merge changed nothing ("Already up to date", "Nothing to merge").
    public var isNoOp: Bool { commitId == nil }
}

/// What a merge attempt came to.
public enum MindMergeStep: Sendable, Equatable {
    case merged(MindMergeResult)
    case conflicts(message: String, [MindMergeConflict])
}

/// The state of a merge in progress, from the first attempt to the last
/// resolution. A merge is attempted with no resolutions; if both branches
/// changed the same memory the server answers 409 with each conflict's base,
/// ours and theirs, the session collects a resolution for every one, and the
/// merge is attempted again with all of them.
public struct MindMergeSession: Sendable, Equatable {
    public let source: String
    public let target: String
    public private(set) var conflicts: [MindMergeConflict] = []
    public private(set) var resolutions: [String: MindResolution] = [:]
    /// The commit message; empty lets the server write "merge x into y".
    public var message = ""

    public init(source: String, target: String = MindBranchName.defaultName) {
        self.source = source
        self.target = target
    }

    /// Takes the conflicts a 409 reported. Known conflicts are refreshed in
    /// place, new ones are added, and a resolution survives only for a
    /// conflict the server did not list again.
    public mutating func receive(_ incoming: [MindMergeConflict]) {
        var merged = conflicts
        for conflict in incoming {
            if let index = merged.firstIndex(where: { $0.memoryId == conflict.memoryId }) {
                merged[index] = conflict
                resolutions[conflict.memoryId] = nil
            } else {
                merged.append(conflict)
            }
        }
        conflicts = merged
    }

    public mutating func resolve(_ memoryId: String, _ resolution: MindResolution) {
        guard conflicts.contains(where: { $0.memoryId == memoryId }) else { return }
        resolutions[memoryId] = resolution
    }

    public mutating func unresolve(_ memoryId: String) {
        resolutions[memoryId] = nil
    }

    /// Settles every conflict still open the same way.
    public mutating func resolveRemaining(_ side: MindSide) {
        for conflict in unresolved {
            resolutions[conflict.memoryId] = side == .ours ? .ours : .theirs
        }
    }

    public var unresolved: [MindMergeConflict] { conflicts.filter { resolutions[$0.memoryId] == nil } }
    public var resolvedCount: Int { conflicts.count - unresolved.count }
    public var hasConflicts: Bool { !conflicts.isEmpty }

    /// Whether the merge can be attempted: the first attempt always can, and a
    /// later one once every reported conflict has an answer.
    public var canMerge: Bool { unresolved.isEmpty }

    public func resolution(for memoryId: String) -> MindResolution? { resolutions[memoryId] }

    /// The conflict after `memoryId` that still needs an answer, wrapping round.
    public func nextUnresolved(after memoryId: String?) -> MindMergeConflict? {
        let open = unresolved
        guard !open.isEmpty else { return nil }
        guard let memoryId, let index = conflicts.firstIndex(where: { $0.memoryId == memoryId }) else { return open.first }
        let rotated = Array(conflicts[(index + 1)...]) + Array(conflicts[..<index])
        return rotated.first(where: { resolutions[$0.memoryId] == nil }) ?? open.first
    }

    /// One line on what a resolution does, for the conflict's summary chip.
    public func describe(_ resolution: MindResolution, for conflict: MindMergeConflict) -> String {
        switch resolution {
        case .ours:
            return conflict.ours == nil ? "Keep it forgotten on \(target)" : "Keep the version on \(target)"
        case .theirs:
            return conflict.theirs == nil ? "Forget it, as \(source) did" : "Take the version from \(source)"
        case .custom:
            return "Your own version"
        }
    }

    /// The body of `POST /api/mind/merge`.
    public func requestBody() -> JSONValue {
        let ordered = resolutions.keys.sorted()
        var body: [String: JSONValue] = [
            "source": .string(source),
            "target": .string(target),
            "resolutions": .array(ordered.map { id in
                .object(["memory_id": .string(id), "resolution": resolutions[id]?.wire ?? .null])
            }),
        ]
        let note = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { body["message"] = .string(note) }
        return .object(body)
    }
}

/// Runs a merge attempt and reads the 409 that reports conflicts.
public struct MindMerger: Sendable {
    private let client: HVClient

    public init(client: HVClient) {
        self.client = client
    }

    public func attempt(_ session: MindMergeSession) async throws -> MindMergeStep {
        do {
            let result = try await client.send(Endpoint<MindMergeResult>.mindMerge(body: session.requestBody()))
            return .merged(result)
        } catch let error as HVError {
            if let step = Self.conflicts(in: error) { return step }
            throw error
        }
    }

    /// A 409 that carries `conflicts`; any other 409 (the target moved while
    /// merging) is an ordinary error with the server's sentence.
    static func conflicts(in error: HVError) -> MindMergeStep? {
        guard case .api(let failure) = error, failure.status == 409,
              let list = failure.body?["conflicts"], list.array != nil,
              let data = try? JSONEncoder().encode(list),
              let conflicts = try? HVCoding.decoder(.snakeCase).decode([MindMergeConflict].self, from: data),
              !conflicts.isEmpty
        else { return nil }
        return .conflicts(message: failure.message, conflicts)
    }
}

// MARK: Endpoints

extension Endpoint where Response == MindBranchList {
    public static var mindBranches: Endpoint<MindBranchList> {
        Endpoint(.get, "/api/mind/branches")
    }
}

extension Endpoint where Response == MindBranchCreated {
    /// Forks `from` (default main) into a new branch. Head pointers are copied, not content.
    public static func mindCreateBranch(name: String, from: String = MindBranchName.defaultName) -> Endpoint<MindBranchCreated> {
        Endpoint(.post, "/api/mind/branches", body: .jsonValue(["name": .string(name), "from": .string(from)]))
    }
}

extension Endpoint where Response == MindBranchDeleted {
    public static func mindDeleteBranch(name: String) -> Endpoint<MindBranchDeleted> {
        Endpoint(.delete, "/api/mind/branches/" + Self.pathComponent(name))
    }

    /// `encodeURIComponent`, which the route decodes again.
    static func pathComponent(_ name: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        return name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
    }
}

extension Endpoint where Response == MindCommitLog {
    public static func mindCommits(branch: String? = nil, limit: Int? = nil) -> Endpoint<MindCommitLog> {
        Endpoint(.get, "/api/mind/commits", query: .make([("branch", branch), ("limit", limit.map(String.init))]))
    }
}

extension Endpoint where Response == MindStateDiff {
    /// What changed in the whole mind between two refs.
    public static func mindDiff(from: MindRef, to: MindRef, branch: String? = nil) -> Endpoint<MindStateDiff> {
        Endpoint(.get, "/api/mind/diff", query: .make([("from", from.wire), ("to", to.wire), ("branch", branch)]))
    }
}

extension Endpoint where Response == MindMemoryDiff {
    /// One memory between two refs (commit ids, as the history screen has them).
    public static func mindMemoryDiff(from: MindRef, to: MindRef, memoryId: String) -> Endpoint<MindMemoryDiff> {
        Endpoint(.get, "/api/mind/diff", query: .make([("from", from.wire), ("to", to.wire), ("memory_id", memoryId)]))
    }
}

extension Endpoint where Response == MindState {
    public static func mindState(at: MindRef, branch: String? = nil) -> Endpoint<MindState> {
        Endpoint(.get, "/api/mind/state", query: .make([("at", at.wire), ("branch", branch)]))
    }
}

extension Endpoint where Response == MindMergeResult {
    /// A 409 comes back as an `HVError`; `MindMerger` turns it into conflicts.
    public static func mindMerge(body: JSONValue) -> Endpoint<MindMergeResult> {
        Endpoint(.post, "/api/mind/merge", body: .jsonValue(body))
    }
}

extension Endpoint where Response == MindReverted {
    public static func mindRevert(memoryId: String, revisionId: String, branch: String? = nil) -> Endpoint<MindReverted> {
        var body: [String: JSONValue] = ["memory_id": .string(memoryId), "revision_id": .string(revisionId)]
        if let branch { body["branch"] = .string(branch) }
        return Endpoint(.post, "/api/mind/revert", body: .jsonValue(.object(body)))
    }
}
