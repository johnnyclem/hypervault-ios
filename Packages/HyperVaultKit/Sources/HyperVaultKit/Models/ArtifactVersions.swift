import Foundation

// A living page is a document with a history: every write is a commit chained
// to the one before, and a write names the commit it was built on, like a
// `git push` (the web's `lib/artifacts/write.ts` and the routes under
// `app/api/artifacts/[slug]`).

/// A commit as the content and write routes name it (`versionRef`).
public struct ArtifactVersionRef: Sendable, Codable, Hashable {
    public let id: String
    public let parentVersionId: String?
    public let message: String
    public let createdAt: Date?
    public let authoredAt: Date?
    public let authorName: String?
    public let authorKind: String?
    public let isHead: Bool

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        parentVersionId = try c.decodeIfPresent(String.self, forKey: .parentVersionId)
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        authoredAt = try c.decodeIfPresent(Date.self, forKey: .authoredAt)
        authorName = try c.decodeIfPresent(String.self, forKey: .authorName)
        authorKind = try c.decodeIfPresent(String.self, forKey: .authorKind)
        isHead = try c.decodeIfPresent(Bool.self, forKey: .isHead) ?? false
    }

    enum Keys: String, CodingKey { case id, parentVersionId, message, createdAt, authoredAt, authorName, authorKind, isHead }
}

/// `GET /api/artifacts/[slug]/content`: the editable source (the raw JSX of a
/// React page, else the stored HTML) and the commit it came from. Pass
/// `headVersionId` back as `base_version_id` when you write.
public struct ArtifactContent: Sendable, Decodable, Equatable {
    public let slug: String
    public let title: String
    public let content: String
    public let isJsx: Bool
    /// Only a living page takes writes.
    public let mutable: Bool
    public let contentHash: String?
    public let version: ArtifactVersionRef?
    public let headVersionId: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        slug = try c.decode(String.self, forKey: .slug)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled"
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        isJsx = try c.decodeIfPresent(Bool.self, forKey: .isJsx) ?? false
        mutable = try c.decodeIfPresent(Bool.self, forKey: .mutable) ?? false
        contentHash = try c.decodeIfPresent(String.self, forKey: .contentHash)
        version = try c.decodeIfPresent(ArtifactVersionRef.self, forKey: .version)
        headVersionId = try c.decodeIfPresent(String.self, forKey: .headVersionId)
    }

    enum Keys: String, CodingKey { case slug, title, content, isJsx, mutable, contentHash, version, headVersionId }

    public static func == (lhs: ArtifactContent, rhs: ArtifactContent) -> Bool {
        lhs.slug == rhs.slug && lhs.content == rhs.content && lhs.headVersionId == rhs.headVersionId
            && lhs.contentHash == rhs.contentHash && lhs.mutable == rhs.mutable
    }
}

/// One commit in `GET /api/artifacts/[slug]/versions`, newest first.
public struct ArtifactVersion: Sendable, Codable, Identifiable, Hashable {
    public let id: String
    public let parentVersionId: String?
    public let title: String
    public let message: String
    /// user, agent or system.
    public let authorKind: String
    /// The prefix of the key an agent wrote with.
    public let authorKeyPrefix: String?
    public let authorName: String?
    public let contentHash: String?
    public let isJsx: Bool
    public let isHead: Bool
    public let createdAt: Date?
    public let authoredAt: Date?
    public let rebasedFromVersionId: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        parentVersionId = try c.decodeIfPresent(String.self, forKey: .parentVersionId)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        authorKind = try c.decodeIfPresent(String.self, forKey: .authorKind) ?? "user"
        authorKeyPrefix = try c.decodeIfPresent(String.self, forKey: .authorKeyPrefix)
        authorName = try c.decodeIfPresent(String.self, forKey: .authorName)
        contentHash = try c.decodeIfPresent(String.self, forKey: .contentHash)
        isJsx = try c.decodeIfPresent(Bool.self, forKey: .isJsx) ?? false
        isHead = try c.decodeIfPresent(Bool.self, forKey: .isHead) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        authoredAt = try c.decodeIfPresent(Date.self, forKey: .authoredAt)
        rebasedFromVersionId = try c.decodeIfPresent(String.self, forKey: .rebasedFromVersionId)
    }

    enum Keys: String, CodingKey {
        case id, parentVersionId, title, message, authorKind, authorKeyPrefix, authorName, contentHash
        case isJsx, isHead, createdAt, authoredAt, rebasedFromVersionId
    }

    /// Who wrote it, as a person would say it: the name an agent gave itself, else its key, else "You".
    public var authorLine: String {
        switch authorKind {
        case "agent":
            if let authorName, !authorName.isEmpty { return authorName }
            if let authorKeyPrefix, !authorKeyPrefix.isEmpty { return authorKeyPrefix }
            return "An agent"
        case "system":
            return authorName ?? "HyperVault"
        default:
            if let authorName, !authorName.isEmpty { return authorName }
            return "You"
        }
    }

    /// The commit message, or "edit" like the server's default.
    public var summary: String { message.isEmpty ? "edit" : message }

    public var isRebased: Bool { rebasedFromVersionId != nil }
}

public struct ArtifactVersionList: Sendable, Decodable, Equatable {
    public let slug: String
    public let mutable: Bool
    public let versions: [ArtifactVersion]

    public init(slug: String, mutable: Bool, versions: [ArtifactVersion]) {
        self.slug = slug
        self.mutable = mutable
        self.versions = versions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        slug = try c.decodeIfPresent(String.self, forKey: .slug) ?? ""
        mutable = try c.decodeIfPresent(Bool.self, forKey: .mutable) ?? false
        versions = try c.decodeIfPresent([ArtifactVersion].self, forKey: .versions) ?? []
    }

    enum Keys: String, CodingKey { case slug, mutable, versions }
}

/// `GET /api/artifacts/[slug]/diff`: a unified diff of the editable source between two commits.
public struct ArtifactDiff: Sendable, Decodable, Equatable {
    public let slug: String
    public let from: String
    public let to: String
    public let patch: String
    public let added: Int
    public let removed: Int
    public let hunks: Int

    public var isEmpty: Bool { patch.isEmpty }
}

// MARK: Writing

/// The body of `PUT /api/artifacts/[slug]/content`. A write must name what it
/// was built on: `baseVersionId` (the head it read), or `force` to overwrite.
public struct ArtifactWriteRequest: Sendable, Encodable {
    public var content: String
    public var title: String?
    public var message: String?
    public var baseVersionId: String?
    public var forceHtml: Bool?
    public var force: Bool?

    public init(
        content: String, title: String? = nil, message: String? = nil, baseVersionId: String? = nil,
        forceHtml: Bool? = nil, force: Bool? = nil
    ) {
        self.content = content
        self.title = title
        self.message = message
        self.baseVersionId = baseVersionId
        self.forceHtml = forceHtml
        self.force = force
    }
}

/// A write that went through (`PUT .../content`, `POST .../revert`).
public struct ArtifactWriteResult: Sendable, Decodable, Equatable {
    public let url: String?
    public let slug: String
    public let isJsx: Bool
    /// The content matched the head, so no commit was made.
    public let unchanged: Bool
    /// The server replayed the change onto a newer head.
    public let rebased: Bool
    public let forced: Bool
    public let version: ArtifactVersionRef?
    /// Pass this as `base_version_id` on the next write.
    public let headVersionId: String?
    public let message: String

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        slug = try c.decodeIfPresent(String.self, forKey: .slug) ?? ""
        isJsx = try c.decodeIfPresent(Bool.self, forKey: .isJsx) ?? false
        unchanged = try c.decodeIfPresent(Bool.self, forKey: .unchanged) ?? false
        rebased = try c.decodeIfPresent(Bool.self, forKey: .rebased) ?? false
        forced = try c.decodeIfPresent(Bool.self, forKey: .forced) ?? false
        version = try c.decodeIfPresent(ArtifactVersionRef.self, forKey: .version)
        headVersionId = try c.decodeIfPresent(String.self, forKey: .headVersionId)
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
    }

    enum Keys: String, CodingKey { case url, slug, isJsx, unchanged, rebased, forced, version, headVersionId, message }
}

/// Why a write was refused with a conflict body (`WriteConflict.reason`).
public enum ArtifactConflictReason: String, Sendable, Hashable {
    case rebaseConflict = "rebase_conflict"
    case unknownBase = "unknown_base"
    case staleBase = "stale_base"
    case staleHash = "stale_hash"
    case concurrentWrite = "concurrent_write"
    case oversize
    case preconditionFailed = "precondition_failed"
    case preconditionRequired = "precondition_required"
    case other
}

/// The 409, 412 and 428 answers of a write. Every one carries the head and its
/// content, so the person can see what they would overwrite and choose.
public struct ArtifactConflict: Sendable, Equatable {
    public let message: String
    public let reason: ArtifactConflictReason
    public let status: Int
    /// The head as it stands now.
    public let head: ArtifactVersionRef?
    public let headContent: String
    /// The commit the writer built on, when the server looked it up (the owner's only).
    public let baseContent: String?

    /// Reads a refused write. Nil when the refusal is not a conflict (a 400, a 413, an immutable page's 409).
    public init?(failure: APIFailure) {
        guard [409, 412, 428].contains(failure.status),
              let body = failure.body,
              body["conflict"]?.bool == true,
              let headContent = body["head_content"]?.string
        else { return nil }
        self.message = failure.message
        self.status = failure.status
        self.reason = body["reason"]?.string.flatMap(ArtifactConflictReason.init(rawValue:)) ?? .other
        self.headContent = headContent
        self.baseContent = body["base_content"]?.string
        if let head = body["head"], !head.isNull,
           let data = try? JSONEncoder().encode(head),
           let ref = try? HVCoding.decoder().decode(ArtifactVersionRef.self, from: data) {
            self.head = ref
        } else {
            self.head = nil
        }
    }

    /// Writing again on top of the head is how "keep mine" overwrites: it fast-forwards.
    public var headVersionId: String? { head?.id }
}
