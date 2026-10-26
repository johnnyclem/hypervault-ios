import Foundation

// The truth ledger: asserted truths and what rests on them. Wire shapes are
// app/api/truth/** and lib/truth/*.ts; the format is stenographer's (version 2).
//
//  - TB: a signed ground truth. A person answers for it.
//  - UV: an unverified assertion, believed and not yet checked.
//
// Status says what happened to an entry. Standing says what happened beneath
// it: sound, clouded (it rests on something open or under appeal) or
// unsupported (it rests on something that has fallen). They are never merged.

private extension KeyedDecodingContainer {
    func soft<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

// MARK: Ledgers

public enum TruthLedgerKind: String, Sendable, Codable, Hashable {
    /// A stream imported from stenographer; read-only here.
    case mirror
    /// A ledger written here: the person and their agents assert into it.
    case hosted

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TruthLedgerKind(rawValue: raw) ?? .mirror
    }

    public var title: String { self == .hosted ? "Hosted" : "Mirror" }
}

public struct TruthLedger: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let slug: String
    public let name: String
    public let kind: TruthLedgerKind
    public let createdAt: Date?
    public let proposalsSeq: Int?

    public init(id: String, slug: String, name: String, kind: TruthLedgerKind, createdAt: Date? = nil, proposalsSeq: Int? = nil) {
        self.id = id
        self.slug = slug
        self.name = name
        self.kind = kind
        self.createdAt = createdAt
        self.proposalsSeq = proposalsSeq
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        slug = try c.decode(String.self, forKey: .slug)
        id = c.soft(String.self, .id) ?? slug
        name = c.soft(String.self, .name) ?? slug
        kind = c.soft(TruthLedgerKind.self, .kind) ?? .mirror
        createdAt = c.soft(Date.self, .createdAt)
        proposalsSeq = c.soft(Int.self, .proposalsSeq)
    }

    enum Keys: String, CodingKey { case id, slug, name, kind, createdAt, proposalsSeq }

    public var isHosted: Bool { kind == .hosted }
}

public struct TruthLedgerList: Sendable, Codable, Equatable {
    /// The slug the routes use when none is named.
    public let defaultSlug: String
    public let ledgers: [TruthLedger]

    public init(defaultSlug: String = "default", ledgers: [TruthLedger] = []) {
        self.defaultSlug = defaultSlug
        self.ledgers = ledgers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultSlug = c.soft(String.self, .defaultSlug) ?? "default"
        ledgers = c.soft([TruthLedger].self, .ledgers) ?? []
    }

    enum CodingKeys: String, CodingKey { case defaultSlug = "default", ledgers }

    public var hosted: [TruthLedger] { ledgers.filter(\.isHosted) }

    /// The ledger to open first: the one asked for, else the default, else the first.
    public func choose(preferring slug: String?) -> TruthLedger? {
        if let slug, let match = ledgers.first(where: { $0.slug == slug }) { return match }
        return ledgers.first(where: { $0.slug == defaultSlug }) ?? ledgers.first
    }

    /// The ledger the review session opens on: a hosted one when there is one.
    public func chooseForReview(preferring slug: String?) -> TruthLedger? {
        if let slug, let match = ledgers.first(where: { $0.slug == slug }) { return match }
        return hosted.first ?? ledgers.first
    }
}

/// `POST /api/truth/ledgers` answers `{ ledger }`.
public struct TruthLedgerEnvelope: Sendable, Codable, Equatable {
    public let ledger: TruthLedger
}

public enum TruthLedgerSlug {
    /// 1 to 64 lowercase letters, digits, "-" or "_", starting with a letter or digit.
    public static func problem(_ slug: String) -> String? {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_")
        guard let first = slug.first, first.isASCII, first.isLetter || first.isNumber, slug.count <= 64,
              slug.allSatisfy({ allowed.contains($0) })
        else { return "Use 1 to 64 lowercase letters, digits, - or _, starting with a letter or digit." }
        return nil
    }

    /// A slug made of a name the person typed: lowercase, dashes between words.
    public static func suggest(from name: String) -> String {
        var out = ""
        var pendingDash = false
        for character in name.lowercased() {
            if character.isASCII, character.isLetter || character.isNumber {
                if pendingDash, !out.isEmpty { out.append("-") }
                pendingDash = false
                out.append(character)
            } else {
                pendingDash = true
            }
        }
        return String(out.prefix(64))
    }
}

// MARK: Types, standing, status

public enum TruthEntryType: String, Sendable, Codable, Hashable {
    case tb = "TB"
    case uv = "UV"

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TruthEntryType(rawValue: raw.uppercased()) ?? .uv
    }

    /// "TB" or "UV": the tag on a row.
    public var tag: String { rawValue }

    public var title: String { self == .tb ? "Signed truth" : "Unverified claim" }
}

public enum TruthStanding: String, Sendable, Codable, Hashable, CaseIterable {
    case sound, clouded, unsupported

    /// An unknown standing reads as sound-with-no-claim: the caller keeps it optional.
    public init?(wire: String?) {
        guard let wire, let value = TruthStanding(rawValue: wire) else { return nil }
        self = value
    }

    public var title: String {
        switch self {
        case .sound: return "Sound"
        case .clouded: return "Clouded"
        case .unsupported: return "Unsupported"
        }
    }

    /// What it means, in a sentence.
    public var meaning: String {
        switch self {
        case .sound: return "Everything it rests on holds."
        case .clouded: return "Something it rests on is still open or under appeal."
        case .unsupported: return "Something it rests on has fallen, so it no longer counts as truth."
        }
    }
}

/// How a status reads and how loudly it should be shown. Quiet by default:
/// only "under appeal" asks for attention.
public enum TruthStatusTone: Sendable, Equatable {
    case settled, open, attention, history
}

public enum TruthStatus {
    /// The status as a person reads it: "contested" is "under appeal" everywhere the product shows it.
    public static func label(_ status: String?) -> String {
        switch status {
        case "active": return "Active"
        case "contested": return "Under appeal"
        case "overridden": return "Overridden"
        case "open": return "Open"
        case "verified": return "Verified"
        case "refuted": return "Refuted"
        case "struck": return "Struck"
        case .some(let other) where !other.isEmpty: return other.prefix(1).uppercased() + other.dropFirst()
        default: return "Unknown"
        }
    }

    public static func tone(_ status: String?) -> TruthStatusTone {
        switch status {
        case "active", "verified": return .settled
        case "open": return .open
        case "contested": return .attention
        default: return .history
        }
    }
}

/// A premise an entry fails on, and why. `premise` is where it was found;
/// `via` is the direct premise it was reached through, when they differ.
public struct TruthReason: Sendable, Codable, Hashable {
    public let premise: String
    public let reason: String
    public let via: String?

    public init(premise: String, reason: String, via: String? = nil) {
        self.premise = premise
        self.reason = reason
        self.via = via
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        premise = c.soft(String.self, .premise) ?? ""
        reason = c.soft(String.self, .reason) ?? ""
        via = c.soft(String.self, .via)
    }

    enum Keys: String, CodingKey { case premise, reason, via }

    /// "open", "under appeal", "refuted": the codec's `premise-…` code in words.
    public var phrase: String {
        switch reason {
        case "premise-missing": return "is not in this ledger"
        case "premise-open": return "is still unverified"
        case "premise-under-appeal": return "is under appeal"
        case "premise-overridden": return "was overridden"
        case "premise-refuted": return "was refuted"
        case "premise-superseded": return "was superseded"
        case "premise-struck": return "was struck"
        default: return reason.replacingOccurrences(of: "premise-", with: "").replacingOccurrences(of: "-", with: " ")
        }
    }

    /// A single failing premise names itself; the sentence for a row is `TruthReasons.sentence`.
    public func sentence(shortening: Bool = true) -> String {
        "\(TruthID.short(premise, enabled: shortening)) \(phrase)"
    }
}

public enum TruthReasons {
    /// Why an entry is clouded or unsupported, in a line: "Rests on 6EYK, which is still unverified."
    public static func sentence(_ reasons: [TruthReason], standing: TruthStanding?) -> String? {
        guard standing != .sound, !reasons.isEmpty else { return nil }
        let lead = standing == .unsupported ? "Cannot stand:" : "Clouded by"
        let named = reasons.prefix(2).map { $0.sentence() }.joined(separator: "; ")
        let more = reasons.count > 2 ? " and \(reasons.count - 2) more" : ""
        return "\(lead) \(named)\(more)."
    }
}

public enum TruthID {
    /// Ids are 26-character ULIDs; the last six are what people can tell apart.
    public static func short(_ id: String, enabled: Bool = true) -> String {
        guard enabled, id.count > 10 else { return id }
        return "…" + id.suffix(6)
    }
}

// MARK: Lines

public struct TruthEvidence: Sendable, Codable, Hashable {
    public let kind: String
    public let ref: String
    public let detail: String?

    public init(kind: String, ref: String, detail: String? = nil) {
        self.kind = kind
        self.ref = ref
        self.detail = detail
    }

    public init(from decoder: Decoder) throws {
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            kind = "note"
            ref = text
            detail = nil
            return
        }
        let c = try decoder.container(keyedBy: Keys.self)
        kind = c.soft(String.self, .kind) ?? "note"
        ref = c.soft(String.self, .ref) ?? ""
        detail = c.soft(String.self, .detail)
    }

    enum Keys: String, CodingKey { case kind, ref, detail }

    /// Evidence that can settle a claim, as opposed to a question about it.
    public var isSettling: Bool { TruthEvidenceKind(rawValue: kind)?.isSettling ?? false }
}

public enum TruthEvidenceKind: String, Sendable, CaseIterable, Identifiable, Hashable {
    case commit, file, test
    case claimedCommand = "claimed-command"
    case wiki, message, chat, ticket, doc

    public var id: String { rawValue }

    /// Commits, files, tests, commands and wiki pages can settle a claim; the rest only raise it.
    public var isSettling: Bool {
        switch self {
        case .commit, .file, .test, .claimedCommand, .wiki: return true
        case .message, .chat, .ticket, .doc: return false
        }
    }

    public var title: String {
        switch self {
        case .claimedCommand: return "command"
        default: return rawValue
        }
    }
}

/// How a UV says it can be checked.
public struct TruthVerifyBy: Sendable, Codable, Hashable {
    public let kind: String
    public let value: String
    public let detail: String?

    public init(kind: String, value: String, detail: String? = nil) {
        self.kind = kind
        self.value = value
        self.detail = detail
    }

    public init(from decoder: Decoder) throws {
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            kind = "inspect"
            value = text
            detail = nil
            return
        }
        let c = try decoder.container(keyedBy: Keys.self)
        kind = c.soft(String.self, .kind) ?? "inspect"
        value = c.soft(String.self, .value) ?? ""
        detail = c.soft(String.self, .detail)
    }

    enum Keys: String, CodingKey { case kind, value, detail }

    public var sentence: String {
        var out = "\(kind): \(value)"
        if let detail, !detail.isEmpty { out += " (\(detail))" }
        return out
    }
}

/// A TB or UV as the ledger wrote it.
public struct TruthLine: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let type: TruthEntryType
    public let ts: Date?
    public let author: String?
    public let status: String?
    public let claim: String?
    public let assertion: String?
    public let basis: String?
    public let verifyBy: TruthVerifyBy?
    public let contests: String?
    public let signedBy: String?
    public let answerableBy: String?
    public let evidence: [TruthEvidence]

    public init(
        id: String, type: TruthEntryType, ts: Date? = nil, author: String? = nil, status: String? = nil,
        claim: String? = nil, assertion: String? = nil, basis: String? = nil, verifyBy: TruthVerifyBy? = nil,
        contests: String? = nil, signedBy: String? = nil, answerableBy: String? = nil, evidence: [TruthEvidence] = []
    ) {
        self.id = id
        self.type = type
        self.ts = ts
        self.author = author
        self.status = status
        self.claim = claim
        self.assertion = assertion
        self.basis = basis
        self.verifyBy = verifyBy
        self.contests = contests
        self.signedBy = signedBy
        self.answerableBy = answerableBy
        self.evidence = evidence
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        type = c.soft(TruthEntryType.self, .type) ?? .uv
        ts = c.soft(Date.self, .ts)
        author = c.soft(String.self, .author)
        status = c.soft(String.self, .status)
        claim = c.soft(String.self, .claim)
        assertion = c.soft(String.self, .assertion)
        basis = c.soft(String.self, .basis)
        verifyBy = c.soft(TruthVerifyBy.self, .verifyBy)
        contests = c.soft(String.self, .contests)
        signedBy = c.soft(String.self, .signedBy)
        answerableBy = c.soft(String.self, .answerableBy)
        evidence = c.soft([TruthEvidence].self, .evidence) ?? []
    }

    enum Keys: String, CodingKey {
        case id, type, ts, author, status, claim, assertion, basis, verifyBy, contests, signedBy, answerableBy, evidence
    }

    /// The words of the claim: a TB's claim or a UV's assertion.
    public var text: String {
        let words = type == .tb ? (claim ?? assertion) : (assertion ?? claim)
        return words ?? "(no text)"
    }

    public var statusLabel: String { TruthStatus.label(status) }
}

/// A UV's freshness by the reader's clock (spec, Freshness): stale past its horizon.
public struct TruthFreshness: Sendable, Codable, Hashable {
    public let isStale: Bool
    public let since: Date?
    public let horizonSeconds: Int?
    public let expiresAt: Date?

    public init(isStale: Bool, since: Date? = nil, horizonSeconds: Int? = nil, expiresAt: Date? = nil) {
        self.isStale = isStale
        self.since = since
        self.horizonSeconds = horizonSeconds
        self.expiresAt = expiresAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let state = c.soft(String.self, .state)
        isStale = c.soft(Bool.self, .isStale) ?? (state == "stale")
        since = c.soft(Date.self, .since)
        horizonSeconds = c.soft(Int.self, .horizonSeconds)
        expiresAt = c.soft(Date.self, .expiresAt)
    }

    enum Keys: String, CodingKey { case state, isStale, since, horizonSeconds, expiresAt }
}

// MARK: The overview of a ledger

public struct TruthSummary: Sendable, Codable, Hashable {
    public let cited: Int
    public let contested: Int
    public let flags: Int
    public let displaced: Int
    public let total: Int
    public let openProposals: Int

    public init(cited: Int = 0, contested: Int = 0, flags: Int = 0, displaced: Int = 0, total: Int = 0, openProposals: Int = 0) {
        self.cited = cited
        self.contested = contested
        self.flags = flags
        self.displaced = displaced
        self.total = total
        self.openProposals = openProposals
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        cited = c.soft(Int.self, .cited) ?? 0
        contested = c.soft(Int.self, .contested) ?? 0
        flags = c.soft(Int.self, .flags) ?? 0
        displaced = c.soft(Int.self, .displaced) ?? 0
        total = c.soft(Int.self, .total) ?? 0
        openProposals = c.soft(Int.self, .openProposals) ?? 0
    }

    enum Keys: String, CodingKey { case cited, contested, flags, displaced, total, openProposals }
}

public enum TruthCadence: String, Sendable, Codable, CaseIterable, Hashable, Identifiable {
    case daily, weekly

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

/// When the review is next due (`GET /api/truth` and `/api/truth/review`).
public struct TruthReviewSchedule: Sendable, Codable, Hashable {
    public let cadence: TruthCadence?
    public let lastAt: Date?
    public let due: Bool
    public let nextAt: Date?

    public init(cadence: TruthCadence? = nil, lastAt: Date? = nil, due: Bool = false, nextAt: Date? = nil) {
        self.cadence = cadence
        self.lastAt = lastAt
        self.due = due
        self.nextAt = nextAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        cadence = c.soft(TruthCadence.self, .cadence)
        lastAt = c.soft(Date.self, .lastAt)
        due = c.soft(Bool.self, .due) ?? false
        nextAt = c.soft(Date.self, .nextAt)
    }

    enum Keys: String, CodingKey { case cadence, lastAt, due, nextAt }
}

/// The docket's headline on the ledger page: how many wait, and for how long.
public struct TruthDocketHeadline: Sendable, Codable, Hashable {
    public let size: Int
    public let nominated: Int
    public let stale: Int
    public let oldestAgeMs: Double?

    public init(size: Int = 0, nominated: Int = 0, stale: Int = 0, oldestAgeMs: Double? = nil) {
        self.size = size
        self.nominated = nominated
        self.stale = stale
        self.oldestAgeMs = oldestAgeMs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        size = c.soft(Int.self, .size) ?? 0
        nominated = c.soft(Int.self, .nominated) ?? 0
        stale = c.soft(Int.self, .stale) ?? 0
        oldestAgeMs = c.soft(Double.self, .oldestAgeMs)
    }

    enum Keys: String, CodingKey { case size, nominated, stale, oldestAgeMs }

    /// "3 items waiting on you, 1 nominated by agents; the oldest has waited 2 days." or "Nothing waits on you."
    public var sentence: String {
        guard size > 0 else { return "Nothing waits on you." }
        var out = "\(size) item\(size == 1 ? "" : "s") waiting on you"
        if nominated > 0 { out += ", \(nominated) nominated by agents" }
        if stale > 0 { out += ", \(stale) stale" }
        if let oldestAgeMs { out += "; the oldest has waited \(TruthTime.wait(milliseconds: oldestAgeMs))" }
        return out + "."
    }
}

public enum TruthTime {
    /// "under an hour", "5 hours", "3 days": how long something has waited.
    public static func wait(milliseconds: Double) -> String {
        let hours = Int(milliseconds / 3_600_000)
        if hours < 1 { return "under an hour" }
        if hours < 48 { return "\(hours) hour\(hours == 1 ? "" : "s")" }
        let days = hours / 24
        return "\(days) day\(days == 1 ? "" : "s")"
    }

    /// The short age on a card: "just now", "12m", "5h", "3d".
    public static func age(milliseconds: Double) -> String {
        let minutes = Int(milliseconds / 60_000)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours)h" }
        return "\(hours / 24)d"
    }
}

/// What the sidecar can do on this server.
public struct TruthSidecar: Sendable, Codable, Hashable {
    public let configured: Bool
    public let notary: Bool

    public init(configured: Bool = false, notary: Bool = false) {
        self.configured = configured
        self.notary = notary
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        configured = c.soft(Bool.self, .configured) ?? false
        notary = c.soft(Bool.self, .notary) ?? false
    }

    enum Keys: String, CodingKey { case configured, notary }
}

/// One entry of the read model, with its folded status and standing
/// (`entries[]` in `GET /api/truth`).
public struct TruthEntrySummary: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let type: TruthEntryType
    public let status: String?
    public let standing: TruthStanding?
    public let reasons: [TruthReason]
    public let corroborated: Bool
    public let freshness: TruthFreshness?
    public let answerableBy: String?
    public let author: String?
    public let ts: Date?
    public let source: String?

    public init(
        id: String, type: TruthEntryType, status: String? = nil, standing: TruthStanding? = nil, reasons: [TruthReason] = [],
        corroborated: Bool = false, freshness: TruthFreshness? = nil, answerableBy: String? = nil, author: String? = nil,
        ts: Date? = nil, source: String? = nil
    ) {
        self.id = id
        self.type = type
        self.status = status
        self.standing = standing
        self.reasons = reasons
        self.corroborated = corroborated
        self.freshness = freshness
        self.answerableBy = answerableBy
        self.author = author
        self.ts = ts
        self.source = source
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        type = c.soft(TruthEntryType.self, .type) ?? .uv
        status = c.soft(String.self, .status)
        standing = TruthStanding(wire: c.soft(String.self, .standing))
        reasons = c.soft([TruthReason].self, .reasons) ?? []
        corroborated = c.soft(Bool.self, .corroborated) ?? false
        freshness = c.soft(TruthFreshness.self, .freshness)
        answerableBy = c.soft(String.self, .answerableBy)
        author = c.soft(String.self, .author)
        ts = c.soft(Date.self, .ts)
        source = c.soft(String.self, .source)
    }

    enum Keys: String, CodingKey {
        case id, type, status, standing, reasons, corroborated, freshness, answerableBy, author, ts, source
    }
}

/// A citable TB with the UVs disputing it.
public struct TruthCitable: Sendable, Codable, Hashable {
    public let entry: TruthLine
    public let standing: TruthStanding?
    public let reasons: [TruthReason]
    public let answerableBy: String?
    public let contestedBy: [TruthLine]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        entry = try c.decode(TruthLine.self, forKey: .entry)
        standing = TruthStanding(wire: c.soft(String.self, .standing))
        reasons = c.soft([TruthReason].self, .reasons) ?? []
        answerableBy = c.soft(String.self, .answerableBy)
        contestedBy = c.soft([TruthLine].self, .contestedBy) ?? []
    }

    enum Keys: String, CodingKey { case entry, standing, reasons, answerableBy, contestedBy }
}

/// One row of the ledger page, whichever bucket it came from.
public struct TruthEntryRow: Sendable, Codable, Hashable, Identifiable {
    public let line: TruthLine
    public let status: String?
    public let standing: TruthStanding?
    public let reasons: [TruthReason]
    public let freshness: TruthFreshness?
    public let corroborated: Bool
    public let answerableBy: String?
    /// The UVs disputing it, for a TB under appeal.
    public let contestedBy: [TruthLine]

    public var id: String { line.id }
    public var type: TruthEntryType { line.type }

    public init(
        line: TruthLine, status: String? = nil, standing: TruthStanding? = nil, reasons: [TruthReason] = [],
        freshness: TruthFreshness? = nil, corroborated: Bool = false, answerableBy: String? = nil, contestedBy: [TruthLine] = []
    ) {
        self.line = line
        self.status = status ?? line.status
        self.standing = standing
        self.reasons = reasons
        self.freshness = freshness
        self.corroborated = corroborated
        self.answerableBy = answerableBy ?? line.answerableBy
        self.contestedBy = contestedBy
    }

    /// Why it is not sound, in a line; nil for a sound entry.
    public var reasonSentence: String? { TruthReasons.sentence(reasons, standing: standing) }

    /// Whether to flag it quietly as stale.
    public var isStale: Bool { freshness?.isStale == true }
}

/// The ledger page's three lists.
public struct TruthSections: Sendable, Hashable {
    /// Citable TBs: signed truth in standing (some clouded, some under appeal).
    public let standing: [TruthEntryRow]
    /// Open UVs: believed, not verified.
    public let unverified: [TruthEntryRow]
    /// Overridden, refuted, verified, struck and unsupported: kept for the record, never cited.
    public let history: [TruthEntryRow]

    public var isEmpty: Bool { standing.isEmpty && unverified.isEmpty && history.isEmpty }
}

/// `GET /api/truth?ledger=`: one ledger's current truth, bucketed.
public struct TruthOverview: Sendable, Codable, Hashable {
    public let ledger: TruthLedger?
    public let summary: TruthSummary
    public let asOf: Date?
    public let chatTruth: Bool
    public let sidecar: TruthSidecar
    public let docket: TruthDocketHeadline?
    public let review: TruthReviewSchedule?
    public let citable: [TruthCitable]
    public let flags: [TruthLine]
    public let displaced: [TruthLine]
    public let entries: [TruthEntrySummary]

    public init(
        ledger: TruthLedger? = nil, summary: TruthSummary = TruthSummary(), asOf: Date? = nil, chatTruth: Bool = true,
        sidecar: TruthSidecar = TruthSidecar(), docket: TruthDocketHeadline? = nil, review: TruthReviewSchedule? = nil,
        citable: [TruthCitable] = [], flags: [TruthLine] = [], displaced: [TruthLine] = [], entries: [TruthEntrySummary] = []
    ) {
        self.ledger = ledger
        self.summary = summary
        self.asOf = asOf
        self.chatTruth = chatTruth
        self.sidecar = sidecar
        self.docket = docket
        self.review = review
        self.citable = citable
        self.flags = flags
        self.displaced = displaced
        self.entries = entries
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        ledger = c.soft(TruthLedger.self, .ledger)
        summary = c.soft(TruthSummary.self, .summary) ?? TruthSummary()
        asOf = c.soft(Date.self, .asOf)
        chatTruth = c.soft(Bool.self, .chatTruth) ?? true
        sidecar = c.soft(TruthSidecar.self, .sidecar) ?? TruthSidecar()
        docket = c.soft(TruthDocketHeadline.self, .docket)
        review = c.soft(TruthReviewSchedule.self, .review)
        citable = c.soft([TruthCitable].self, .citable) ?? []
        flags = c.soft([TruthLine].self, .flags) ?? []
        displaced = c.soft([TruthLine].self, .displaced) ?? []
        entries = c.soft([TruthEntrySummary].self, .entries) ?? []
    }

    enum Keys: String, CodingKey {
        case ledger, summary, asOf, chatTruth, sidecar, docket, review, citable, flags, displaced, entries
    }

    /// The three lists of the ledger page, each row joined to its folded status,
    /// standing and freshness.
    public var sections: TruthSections {
        let byId = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        func row(_ line: TruthLine) -> TruthEntryRow {
            let folded = byId[line.id]
            return TruthEntryRow(
                line: line, status: folded?.status ?? line.status, standing: folded?.standing, reasons: folded?.reasons ?? [],
                freshness: folded?.freshness, corroborated: folded?.corroborated ?? false, answerableBy: folded?.answerableBy
            )
        }
        let standing = citable.map { item -> TruthEntryRow in
            let folded = byId[item.entry.id]
            return TruthEntryRow(
                line: item.entry, status: folded?.status ?? item.entry.status, standing: item.standing ?? folded?.standing,
                reasons: item.reasons.isEmpty ? (folded?.reasons ?? []) : item.reasons,
                freshness: folded?.freshness, corroborated: folded?.corroborated ?? false,
                answerableBy: item.answerableBy ?? folded?.answerableBy, contestedBy: item.contestedBy
            )
        }
        return TruthSections(standing: standing, unverified: flags.map(row), history: displaced.map(row))
    }
}
