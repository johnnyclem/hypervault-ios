import Foundation

// What rests on a fact, and what moved: the trace's other half (dependents),
// the ripple (everything downstream), the stale worklist, and the events feed.
// See docs/truth-graph.md and docs/truth-events.md.

private extension KeyedDecodingContainer {
    func soft<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

/// An entry in brief: what the ripple, the worklist and a trace's "rests on it" list show.
public struct TruthEntryBrief: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let type: TruthEntryType
    public let status: String?
    public let standing: TruthStanding?
    public let reasons: [TruthReason]
    public let text: String
    public let signedBy: String?
    public let answerableBy: String?
    /// How many derivations above a root (a ripple's entries only).
    public let depth: Int?
    /// The premise it was reached through (a ripple's entries only).
    public let via: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        type = c.soft(TruthEntryType.self, .type) ?? .uv
        status = c.soft(String.self, .status)
        standing = TruthStanding(wire: c.soft(String.self, .standing))
        reasons = c.soft([TruthReason].self, .reasons) ?? []
        text = c.soft(String.self, .text) ?? ""
        signedBy = c.soft(String.self, .signedBy)
        answerableBy = c.soft(String.self, .answerableBy)
        depth = c.soft(Int.self, .depth)
        via = c.soft(String.self, .via)
    }

    enum Keys: String, CodingKey {
        case id, type, status, standing, reasons, text, signedBy, answerableBy, depth, via
    }

    public var reasonSentence: String? { TruthReasons.sentence(reasons, standing: standing) }
}

/// `GET /api/truth/[id]/derivation`: the premises under an entry, and the entries resting on it.
public struct TruthDerivation: Sendable, Decodable {
    public let id: String
    public let root: TruthTraceNode
    public let dependents: [TruthEntryBrief]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = c.soft(String.self, .id) ?? ""
        root = try c.decode(TruthTraceNode.self, forKey: .derivation)
        dependents = c.soft([TruthEntryBrief].self, .dependents) ?? []
    }

    enum Keys: String, CodingKey { case id, derivation, dependents }

    public var rows: [TruthTraceRow] { TruthTrace.rows(root) }
}

// MARK: Context items

/// A memory or a document that rests on entries.
public struct TruthContextItem: Sendable, Codable, Hashable, Identifiable {
    public let kind: String
    public let id: String
    public let title: String
    public let slug: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = c.soft(String.self, .kind) ?? "memory"
        title = c.soft(String.self, .title) ?? "Untitled"
        slug = c.soft(String.self, .slug)
    }

    enum Keys: String, CodingKey { case kind, id, title, slug }

    public var isMemory: Bool { kind == "memory" }
}

// MARK: The ripple

public struct TruthRippleContext: Sendable, Decodable, Hashable, Identifiable {
    public let kind: String
    public let refID: String
    public let item: TruthContextItem?
    public let relation: String
    public let entryId: String
    /// Whether a change to the entry reaches the item (a "source" is provenance and does not).
    public let affected: Bool
    public let stale: Bool
    public let staleKind: String?
    public let note: String?

    public var id: String { "\(entryId)|\(kind)|\(refID)" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        kind = c.soft(String.self, .kind) ?? "memory"
        refID = c.soft(String.self, .id) ?? ""
        item = c.soft(TruthContextItem.self, .item)
        relation = c.soft(String.self, .relation) ?? "rests_on"
        entryId = c.soft(String.self, .entryId) ?? ""
        affected = c.soft(Bool.self, .affected) ?? true
        stale = c.soft(Bool.self, .stale) ?? false
        staleKind = c.soft(String.self, .staleKind)
        note = c.soft(String.self, .note)
    }

    enum Keys: String, CodingKey { case kind, id, item, relation, entryId, affected, stale, staleKind, note }

    public var title: String { item?.title ?? "A \(kind) that is no longer here" }

    public var relationPhrase: String {
        switch relation {
        case "rests_on": return "rests on it"
        case "cites": return "cites it"
        case "source": return "is where it came from"
        default: return relation.replacingOccurrences(of: "_", with: " ")
        }
    }
}

public struct TruthRipple: Sendable, Decodable {
    public let roots: [TruthEntryBrief]
    public let missing: [String]
    public let entries: [TruthEntryBrief]
    public let context: [TruthRippleContext]
    public let affectedCount: Int
    public let staleCount: Int

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        roots = c.soft([TruthEntryBrief].self, .roots) ?? []
        missing = c.soft([String].self, .missing) ?? []
        entries = c.soft([TruthEntryBrief].self, .entries) ?? []
        context = c.soft([TruthRippleContext].self, .context) ?? []
        if let counts = try? c.nestedContainer(keyedBy: CountKeys.self, forKey: .counts) {
            affectedCount = (try? counts.decodeIfPresent(Int.self, forKey: .affected)) ?? 0
            staleCount = (try? counts.decodeIfPresent(Int.self, forKey: .stale)) ?? 0
        } else {
            affectedCount = context.filter(\.affected).count
            staleCount = context.filter(\.stale).count
        }
    }

    enum Keys: String, CodingKey { case roots, missing, entries, context, counts }
    enum CountKeys: String, CodingKey { case affected, stale }

    public var isEmpty: Bool { entries.isEmpty && context.isEmpty }

    /// "2 entries and 3 notes rest on it": the ripple in a line.
    public var sentence: String {
        if isEmpty { return "Nothing rests on this." }
        var parts: [String] = []
        if !entries.isEmpty { parts.append("\(entries.count) other entr\(entries.count == 1 ? "y" : "ies")") }
        if !context.isEmpty { parts.append("\(context.count) memor\(context.count == 1 ? "y or page" : "ies and pages")") }
        return parts.joined(separator: " and ") + " rest on it" + (affectedCount > 0 ? ", \(affectedCount) of them would feel a change." : ".")
    }
}

// MARK: The stale worklist

/// A memory or page whose entries moved since it last saw them.
public struct TruthStaleEdge: Sendable, Decodable, Hashable, Identifiable {
    public let entryId: String
    public let relation: String
    public let seenStatus: String?
    public let seenStanding: String?
    public let staleSince: Date?
    public let staleKind: String?
    public let staleSummary: String?
    public let note: String?
    public let entry: TruthEntryBrief?
    /// The TB that superseded the entry, when one did: what a re-derived item usually rests on next.
    public let successor: TruthEntryBrief?

    public var id: String { entryId }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let link = try? c.nestedContainer(keyedBy: LinkKeys.self, forKey: .link)
        entryId = (try? link?.decodeIfPresent(String.self, forKey: .entryId)) ?? c.soft(String.self, .entryId) ?? ""
        relation = (try? link?.decodeIfPresent(String.self, forKey: .relation)) ?? "rests_on"
        seenStatus = (try? link?.decodeIfPresent(String.self, forKey: .seenStatus)) ?? nil
        seenStanding = (try? link?.decodeIfPresent(String.self, forKey: .seenStanding)) ?? nil
        staleSince = (try? link?.decodeIfPresent(Date.self, forKey: .staleSince)) ?? nil
        staleKind = (try? link?.decodeIfPresent(String.self, forKey: .staleKind)) ?? nil
        staleSummary = (try? link?.decodeIfPresent(String.self, forKey: .staleSummary)) ?? nil
        note = (try? link?.decodeIfPresent(String.self, forKey: .note)) ?? nil
        entry = c.soft(TruthEntryBrief.self, .entry)
        successor = c.soft(TruthEntryBrief.self, .successor)
    }

    enum Keys: String, CodingKey { case link, entryId, entry, successor }
    enum LinkKeys: String, CodingKey { case entryId, relation, seenStatus, seenStanding, staleSince, staleKind, staleSummary, note }

    /// What moved, as a sentence: the server's own summary, else the kind of event.
    public var whatMoved: String {
        if let staleSummary, !staleSummary.isEmpty { return staleSummary }
        switch staleKind {
        case "challenged": return "It is now under appeal."
        case "overturned": return "It was overturned."
        case "upheld": return "The appeal against it failed."
        case "verified": return "It was verified."
        case "undermined": return "Something beneath it fell."
        case "restored": return "It was mended."
        default: return "It changed."
        }
    }
}

public struct TruthStaleItem: Sendable, Decodable, Hashable, Identifiable {
    public let item: TruthContextItem?
    public let key: String
    public let ledger: TruthLedger?
    public let edges: [TruthStaleEdge]

    public var id: String { key }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        item = c.soft(TruthContextItem.self, .item)
        ledger = c.soft(TruthLedger.self, .ledger)
        edges = c.soft([TruthStaleEdge].self, .edges) ?? []
        key = c.soft(String.self, .key) ?? "\(item?.kind ?? "item"):\(item?.id ?? UUID().uuidString)"
    }

    enum Keys: String, CodingKey { case item, key, ledger, edges }
}

public struct TruthStaleWorklist: Sendable, Decodable {
    public let items: [TruthStaleItem]
    public let total: Int

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        items = c.soft([TruthStaleItem].self, .items) ?? []
        total = c.soft(Int.self, .total) ?? items.count
    }

    enum Keys: String, CodingKey { case items, total }
}

public enum TruthStaleResolution: String, Sendable, CaseIterable, Identifiable, Hashable {
    /// Looked at it and it is fine: the edges stay and move to the entries as they are now.
    case reaffirm
    /// Rests on something else now.
    case relink
    /// No longer rests on it.
    case unlink

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .reaffirm: return "Still fine"
        case .relink: return "Move to the new one"
        case .unlink: return "Stop tracking"
        }
    }

    /// The body of `POST /api/truth/stale` for one item.
    public func body(item: TruthContextItem, entries: [String], to successors: [String] = [], ledger: String?) -> JSONValue {
        var out: [String: JSONValue] = [
            "kind": .string(item.kind),
            "id": .string(item.id),
            "action": .string(rawValue),
            "entries": .array(entries.map { .string($0) }),
        ]
        if self == .relink { out["to"] = .array(successors.map { .string($0) }) }
        if let ledger { out["ledger"] = .string(ledger) }
        return .object(out)
    }
}

// MARK: Events

public enum TruthEventKind: String, Sendable, Codable, CaseIterable, Hashable {
    case challenged, overturned, upheld, verified, undermined, restored

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TruthEventKind(rawValue: raw) ?? .challenged
    }

    public var title: String {
        switch self {
        case .challenged: return "Challenged"
        case .overturned: return "Overturned"
        case .upheld: return "Upheld"
        case .verified: return "Verified"
        case .undermined: return "Undermined"
        case .restored: return "Restored"
        }
    }

    /// Whether this is bad news for the entry.
    public var isSetback: Bool {
        switch self {
        case .challenged, .overturned, .undermined: return true
        case .upheld, .verified, .restored: return false
        }
    }
}

public struct TruthEvent: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let entryId: String
    public let entryType: TruthEntryType
    public let kind: TruthEventKind
    public let priorStatus: String?
    public let newStatus: String?
    public let byEntryId: String?
    public let byAuthor: String?
    public let summary: String
    public let createdAt: Date?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        entryId = c.soft(String.self, .entryId) ?? ""
        id = c.soft(String.self, .id) ?? "\(entryId)|\(c.soft(String.self, .createdAt) ?? "")"
        entryType = c.soft(TruthEntryType.self, .entryType) ?? .uv
        kind = c.soft(TruthEventKind.self, .kind) ?? .challenged
        priorStatus = c.soft(String.self, .priorStatus)
        newStatus = c.soft(String.self, .newStatus)
        byEntryId = c.soft(String.self, .byEntryId)
        byAuthor = c.soft(String.self, .byAuthor)
        summary = c.soft(String.self, .summary) ?? ""
        createdAt = c.soft(Date.self, .createdAt)
    }

    enum Keys: String, CodingKey {
        case id, entryId, entryType, kind, priorStatus, newStatus, byEntryId, byAuthor, summary, createdAt
    }
}

public struct TruthEventList: Sendable, Codable, Equatable {
    public let events: [TruthEvent]

    public init(events: [TruthEvent] = []) { self.events = events }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        events = c.soft([TruthEvent].self, .events) ?? []
    }

    enum Keys: String, CodingKey { case events }
}
