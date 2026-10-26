import Foundation

/// Who can open an artifact (the web's `lib/visibility.ts`). A row from before
/// the privacy migration has no visibility and is public; a word this build
/// does not know reads as private, so a screen never promises more than the
/// server does.
public enum ArtifactVisibility: String, Sendable, Codable, CaseIterable, Hashable {
    case `public`
    case `private`
    case password

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ArtifactVisibility(rawValue: raw) ?? .private
    }

    public var title: String {
        switch self {
        case .public: return "Public"
        case .private: return "Private"
        case .password: return "Password"
        }
    }

    /// One line for a picker: who can open it.
    public var detail: String {
        switch self {
        case .public: return "Anyone with the link"
        case .private: return "Only you and people you add"
        case .password: return "Anyone with a password"
        }
    }

    /// Private or behind a password: identity alone is not enough to open it.
    public var isGated: Bool { self != .public }
}

/// One row of `GET /api/artifacts`: a page, a stored file or a group, without
/// its content. The route sends no id; connections and sharing take the slug.
public struct ArtifactSummary: Sendable, Codable, Identifiable, Hashable {
    public var id: String { slug }
    public let slug: String
    public let title: String
    /// Free text on the server: html, react, markdown, note, json, pdf, image, group.
    public let type: String
    public let tags: [String]
    public let sourcePrompt: String?
    public let isPwa: Bool
    public let isJsx: Bool
    public let visibility: ArtifactVisibility
    public let icon: String?
    public let createdAt: Date?
    public let url: String?

    public init(
        slug: String, title: String, type: String = "html", tags: [String] = [], sourcePrompt: String? = nil,
        isPwa: Bool = false, isJsx: Bool = false, visibility: ArtifactVisibility = .private, icon: String? = nil,
        createdAt: Date? = nil, url: String? = nil
    ) {
        self.slug = slug
        self.title = title
        self.type = type
        self.tags = tags
        self.sourcePrompt = sourcePrompt
        self.isPwa = isPwa
        self.isJsx = isJsx
        self.visibility = visibility
        self.icon = icon
        self.createdAt = createdAt
        self.url = url
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        slug = try c.decode(String.self, forKey: .slug)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled"
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "html"
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        sourcePrompt = try c.decodeIfPresent(String.self, forKey: .sourcePrompt)
        isPwa = try c.decodeIfPresent(Bool.self, forKey: .isPwa) ?? false
        isJsx = try c.decodeIfPresent(Bool.self, forKey: .isJsx) ?? false
        // A server from before the privacy migration sends no visibility: public.
        visibility = try c.decodeIfPresent(ArtifactVisibility.self, forKey: .visibility) ?? .public
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        url = try c.decodeIfPresent(String.self, forKey: .url)
    }

    enum Keys: String, CodingKey { case slug, title, type, tags, sourcePrompt, isPwa, isJsx, visibility, icon, createdAt, url }

    /// What a person calls it: a stored pdf or image is a file, a group is a group, the rest are pages.
    public var kind: KeptKind {
        switch type {
        case "group": return .group
        case "pdf", "image": return .file
        default: return .page
        }
    }

    public var isGroup: Bool { type == "group" }

    /// A stored pdf or image: the content is a Storage path, not markup.
    public var isStoredFile: Bool { type == "pdf" || type == "image" }

    /// Pages the system keeps for itself (the setup challenge, a task board's data). Never listed.
    public var isBookkeeping: Bool {
        tags.contains { ArtifactSummary.bookkeepingTags.contains($0) }
    }

    static let bookkeepingTags: Set<String> = ["agent-setup-challenge", "tasklist"]

    /// The word on a row: "react" for a component, else the stored type.
    public var typeLabel: String { isJsx ? "react" : type }
}

public struct ArtifactList: Sendable, Codable, Equatable {
    public let items: [ArtifactSummary]

    public init(items: [ArtifactSummary] = []) {
        self.items = items
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        items = try c.decodeIfPresent([ArtifactSummary].self, forKey: .items) ?? []
    }

    enum Keys: String, CodingKey { case items }
}

// MARK: Icon

/// The glyph and colours of an artifact's generated home-screen icon, so a row
/// here looks like the icon the web serves (`lib/pwa.ts`).
public enum ArtifactIcon {
    /// The first letter or digit of the title, upper-cased, else "#".
    public static func initial(_ title: String) -> String {
        guard let first = title.first(where: { $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return "#" }
        return String(first).uppercased()
    }

    /// A custom glyph is at most two code points: an icon, not a word.
    public static let maxGlyphScalars = 2

    /// Trims and keeps the first two code points; nil when nothing is left (the cue to clear the override).
    public static func normalizedGlyph(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var glyph = String.UnicodeScalarView()
        glyph.append(contentsOf: trimmed.unicodeScalars.prefix(maxGlyphScalars))
        let text = String(glyph)
        return text.isEmpty ? nil : text
    }

    public static func glyph(icon: String?, title: String) -> String {
        normalizedGlyph(icon) ?? initial(title)
    }

    /// The hue (0..<360) of the first gradient stop; the second is 42 degrees on.
    /// The same hash as the web: `hash = hash * 31 + charCode`, 32 bits, over UTF-16 units.
    public static func hue(seed: String) -> Double {
        var hash: UInt32 = 0
        for unit in seed.utf16 { hash = hash &* 31 &+ UInt32(unit) }
        return Double(hash % 360)
    }

    public static func secondHue(seed: String) -> Double {
        (hue(seed: seed) + 42).truncatingRemainder(dividingBy: 360)
    }
}

// MARK: Changing and removing

/// The artifact a `PATCH` answers with.
public struct ArtifactRef: Sendable, Decodable, Hashable {
    public let id: String?
    public let slug: String
    public let title: String
    public let visibility: ArtifactVisibility?
    public let icon: String?
}

/// What `PATCH /api/artifacts` answers: the row, and a sentence to show.
public struct ArtifactPatchResult: Sendable, Decodable {
    public let artifact: ArtifactRef
    public let message: String
}

/// What `DELETE /api/artifacts` answers. The route also echoes the page's
/// content; it is not decoded here.
public struct ArtifactDeleteResult: Sendable, Decodable {
    public struct Deleted: Sendable, Decodable {
        public let id: String?
        public let slug: String
        public let title: String
    }

    public let deleted: Deleted
    public let message: String
}

// MARK: Saving

/// The body of `POST /api/save`. The server detects React and wraps it unless `forceHtml`.
public struct ArtifactSaveRequest: Sendable, Encodable {
    public var content: String
    public var title: String?
    /// "jsx" tells the server a `.jsx` file is a component even when detection is unsure.
    public var type: String?
    public var tags: [String]
    public var connectTo: [String]
    public var makePwa: Bool
    public var forceHtml: Bool
    /// A living page keeps a version for every write.
    public var mutable: Bool
    public var visibility: ArtifactVisibility
    public var sourcePrompt: String?

    public init(
        content: String, title: String? = nil, type: String? = nil, tags: [String] = [], connectTo: [String] = [],
        makePwa: Bool = true, forceHtml: Bool = false, mutable: Bool = false,
        visibility: ArtifactVisibility = .private, sourcePrompt: String? = nil
    ) {
        self.content = content
        self.title = title
        self.type = type
        self.tags = tags
        self.connectTo = connectTo
        self.makePwa = makePwa
        self.forceHtml = forceHtml
        self.mutable = mutable
        self.visibility = visibility
        self.sourcePrompt = sourcePrompt
    }
}

/// What `POST /api/save` and `POST /api/artifacts/import-file` answer.
public struct ArtifactSaveResult: Sendable, Decodable, Equatable {
    public struct Connections: Sendable, Decodable, Equatable {
        public let manual: Int
        public let auto: Int
    }

    public let url: String
    public let slug: String
    public let isJsx: Bool
    public let visibility: ArtifactVisibility
    public let mutable: Bool
    /// True when the same content was already kept: this is the existing link, not a copy.
    public let duplicate: Bool
    public let connections: Connections?
    /// The canvas's own words ("Kept. Here's the link. ...").
    public let message: String

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        url = try c.decode(String.self, forKey: .url)
        slug = try c.decode(String.self, forKey: .slug)
        isJsx = try c.decodeIfPresent(Bool.self, forKey: .isJsx) ?? false
        visibility = try c.decodeIfPresent(ArtifactVisibility.self, forKey: .visibility) ?? .private
        mutable = try c.decodeIfPresent(Bool.self, forKey: .mutable) ?? false
        duplicate = try c.decodeIfPresent(Bool.self, forKey: .duplicate) ?? false
        connections = try c.decodeIfPresent(Connections.self, forKey: .connections)
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
    }

    enum Keys: String, CodingKey { case url, slug, isJsx, visibility, mutable, duplicate, connections, message }
}

/// An answer that is only a sentence to show (`{ message }`): a share ended, a file added.
public struct ArtifactMessage: Sendable, Decodable {
    public let message: String

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
    }

    enum Keys: String, CodingKey { case message }
}

// MARK: Feedback, source

/// A thumb on a page.
public enum ArtifactFeedback: String, Sendable, Codable, Hashable {
    case up, down
}

public struct ArtifactFeedbackState: Sendable, Decodable {
    public let feedback: ArtifactFeedback?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        // null clears the rating; a word this build does not know is no rating.
        feedback = (try c.decodeIfPresent(String.self, forKey: .feedback)).flatMap(ArtifactFeedback.init(rawValue:))
    }

    enum Keys: String, CodingKey { case feedback }
}

/// `GET /api/artifacts/[slug]/source`: the markup exactly as stored.
public struct ArtifactSource: Sendable, Decodable {
    public let content: String
}

// MARK: Repair

/// `POST /api/artifacts/[slug]/repair` answers 202 with a job to poll.
public struct ArtifactRepairStart: Sendable, Decodable {
    public let jobId: String
    public let status: String?
}

/// A background job (`GET /api/jobs/[id]`), as far as a repair needs it.
public struct ArtifactJob: Sendable, Decodable {
    public enum Status: String, Sendable { case pending, running, succeeded, failed, unknown }

    public struct Outcome: Sendable, Decodable {
        public let changed: Bool?
        public let message: String?
    }

    public let id: String
    public let status: Status
    public let result: Outcome?
    public let error: String?

    public var isFinished: Bool { status == .succeeded || status == .failed }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        status = (try c.decodeIfPresent(String.self, forKey: .status)).flatMap(Status.init(rawValue:)) ?? .unknown
        result = try? c.decodeIfPresent(Outcome.self, forKey: .result)
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }

    enum Keys: String, CodingKey { case id, status, result, error }
}

struct ArtifactJobEnvelope: Sendable, Decodable {
    let job: ArtifactJob
}
