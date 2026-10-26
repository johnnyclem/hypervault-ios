import Foundation

// The review docket: what waits on the person, one card per item, and the five
// things they can do with it. The preconditions are the web's (and the
// server's); they live here so the screen can say what an action does before it
// is tried, and why one is not offered.

private extension KeyedDecodingContainer {
    func soft<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

// MARK: Trace (the derivation tree)

/// One row of a trace: an entry, its status and standing, who signed it and who
/// answers for it. `failing` marks the premise the entry above fails on, with
/// the reason.
public struct TruthTraceNode: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    /// "TB", "UV" or "RULING" (a precedent).
    public let type: String
    public let status: String?
    public let standing: TruthStanding?
    public let reasons: [TruthReason]
    public let text: String
    public let signedBy: String?
    public let answerableBy: String?
    /// How the entry above pins this premise ("derives", or "wiki" for cited-not-pinned).
    public let kind: String?
    public let failing: String?
    public let premises: [TruthTraceNode]
    /// The premise is not held in this ledger.
    public let missing: Bool

    public init(
        id: String, type: String = "TB", status: String? = nil, standing: TruthStanding? = nil, reasons: [TruthReason] = [],
        text: String = "", signedBy: String? = nil, answerableBy: String? = nil, kind: String? = nil, failing: String? = nil,
        premises: [TruthTraceNode] = [], missing: Bool = false
    ) {
        self.id = id
        self.type = type
        self.status = status
        self.standing = standing
        self.reasons = reasons
        self.text = text
        self.signedBy = signedBy
        self.answerableBy = answerableBy
        self.kind = kind
        self.failing = failing
        self.premises = premises
        self.missing = missing
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        type = c.soft(String.self, .type) ?? "TB"
        status = c.soft(String.self, .status)
        standing = TruthStanding(wire: c.soft(String.self, .standing))
        reasons = c.soft([TruthReason].self, .reasons) ?? []
        text = c.soft(String.self, .text) ?? ""
        signedBy = c.soft(String.self, .signedBy)
        answerableBy = c.soft(String.self, .answerableBy)
        kind = c.soft(String.self, .kind)
        failing = c.soft(String.self, .failing)
        premises = c.soft([TruthTraceNode].self, .premises) ?? []
        missing = c.soft(Bool.self, .missing) ?? false
    }

    enum Keys: String, CodingKey {
        case id, type, status, standing, reasons, text, signedBy, answerableBy, kind, failing, premises, missing
    }

    public var isPrecedent: Bool { type == "RULING" }

    /// The badge for the type: "TB", "UV" or "precedent".
    public var typeTag: String { isPrecedent ? "precedent" : type }

    public var statusLabel: String {
        if missing { return "not held here" }
        if isPrecedent { return status ?? "current" }
        return TruthStatus.label(status)
    }

    /// "was struck": what is wrong with this premise, when it is the one that fails.
    public var failingPhrase: String? {
        guard let failing else { return nil }
        return TruthReason(premise: id, reason: failing).phrase
    }
}

/// A trace row with where it sits, so a premise that appears twice stays two rows.
public struct TruthTraceRow: Sendable, Hashable, Identifiable {
    public let path: String
    public let node: TruthTraceNode
    public let depth: Int

    public var id: String { path }
}

public enum TruthTrace {
    /// One row per node, the root first, premises under their entry.
    public static func rows(_ root: TruthTraceNode) -> [TruthTraceRow] {
        var out: [TruthTraceRow] = []
        func walk(_ node: TruthTraceNode, path: String, depth: Int) {
            out.append(TruthTraceRow(path: path, node: node, depth: depth))
            for premise in node.premises { walk(premise, path: path + ">" + premise.id, depth: depth + 1) }
        }
        walk(root, path: root.id, depth: 0)
        return out
    }

    /// Whether the trace has anything under its root.
    public static func hasPremises(_ root: TruthTraceNode) -> Bool { !root.premises.isEmpty }
}

// MARK: The docket

public enum TruthDocketKind: String, Sendable, Codable, Hashable {
    case uv
    case appeal
    case derivationReview = "derivation-review"
    case migration

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TruthDocketKind(rawValue: raw) ?? .uv
    }

    public var title: String {
        switch self {
        case .uv: return "UV"
        case .appeal: return "TB under appeal"
        case .derivationReview: return "Derivation review"
        case .migration: return "Page import"
        }
    }

    /// A proposal on the docket (the detector's review, or a page line), rather than an entry.
    public var isProposal: Bool { self == .derivationReview || self == .migration }
}

public struct TruthApprovalRecord: Sendable, Codable, Hashable {
    public let by: String
    public let role: String
    public let agentSessionId: String?
    public let evidence: [TruthEvidence]
    public let note: String?
    public let createdAt: Date?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        by = c.soft(String.self, .by) ?? "someone"
        role = c.soft(String.self, .role) ?? "agent"
        agentSessionId = c.soft(String.self, .agentSessionId)
        evidence = c.soft([TruthEvidence].self, .evidence) ?? []
        note = c.soft(String.self, .note)
        createdAt = c.soft(Date.self, .createdAt)
    }

    enum Keys: String, CodingKey { case by, role, agentSessionId, evidence, note, createdAt }
}

/// The record so far on a UV: who approved, and what promotion still needs.
public struct TruthApprovals: Sendable, Codable, Hashable {
    public let approvers: Int
    public let human: Bool
    public let agentSessions: Int
    public let nominated: Bool
    /// "a human approval", "a second approver", "evidence".
    public let missing: [String]
    public let list: [TruthApprovalRecord]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        approvers = c.soft(Int.self, .approvers) ?? 0
        human = c.soft(Bool.self, .human) ?? false
        agentSessions = c.soft(Int.self, .agentSessions) ?? 0
        nominated = c.soft(Bool.self, .nominated) ?? false
        missing = c.soft([String].self, .missing) ?? []
        list = c.soft([TruthApprovalRecord].self, .list) ?? []
    }

    enum Keys: String, CodingKey { case approvers, human, agentSessions, nominated, missing, list }

    /// What stands between this UV and promotion once the person has approved.
    public var missingBesidesYou: [String] { missing.filter { $0 != "a human approval" } }

    public var isReadyToPromote: Bool { missing.isEmpty }

    /// "1 approver (you, 0 agent sessions)": the record in a line.
    public var recordLine: String {
        let who = human ? "you" : "no person yet"
        return "\(approvers) approver\(approvers == 1 ? "" : "s") (\(who), \(agentSessions) agent session\(agentSessions == 1 ? "" : "s"))"
    }
}

public struct TruthContestingUV: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let assertion: String
    public let author: String

    public init(id: String, assertion: String, author: String) {
        self.id = id
        self.assertion = assertion
        self.author = author
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        assertion = c.soft(String.self, .assertion) ?? ""
        author = c.soft(String.self, .author) ?? ""
    }

    enum Keys: String, CodingKey { case id, assertion, author }
}

public struct TruthDocketReview: Sendable, Codable, Hashable {
    public let contests: String
    public let detail: String
    public let proposalId: String
    public let rank: Int?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        contests = c.soft(String.self, .contests) ?? ""
        detail = c.soft(String.self, .detail) ?? ""
        proposalId = c.soft(String.self, .proposalId) ?? ""
        rank = c.soft(Int.self, .rank)
    }

    enum Keys: String, CodingKey { case contests, detail, proposalId, rank }
}

public struct TruthLiteral: Sendable, Codable, Hashable {
    public let dead: String
    public let subject: String?
    public let current: String?

    public init(dead: String, subject: String? = nil, current: String? = nil) {
        self.dead = dead
        self.subject = subject
        self.current = current
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        dead = c.soft(String.self, .dead) ?? ""
        subject = c.soft(String.self, .subject)
        current = c.soft(String.self, .current)
    }

    enum Keys: String, CodingKey { case dead, subject, current }
}

/// A page-ledger line brought in: where it came from and the value it would retire.
public struct TruthDocketMigration: Sendable, Codable, Hashable {
    public let page: JSONValue?
    public let literal: TruthLiteral?
    public let proposalId: String

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        page = c.soft(JSONValue.self, .page)
        literal = c.soft(TruthLiteral.self, .literal)
        proposalId = c.soft(String.self, .proposalId) ?? ""
    }

    enum Keys: String, CodingKey { case page, literal, proposalId }

    public var pageSlug: String? { page?["slug"]?.string }
    public var lineID: String? { page?["line_id"]?.string ?? page?["lineId"]?.string }
    public var typedBy: String? { page?["owner"]?.string }
}

/// One card.
public struct TruthDocketItem: Sendable, Codable, Hashable, Identifiable {
    public let kind: TruthDocketKind
    public let id: String
    public let subject: String
    public let text: String
    public let author: String
    public let agentSessionId: String?
    public let createdAt: Date?
    public let ageMs: Double
    public let nominated: Bool
    public let suspect: Bool
    public let stale: Bool
    public let freshness: TruthFreshness?
    public let deferredUntil: Date?
    public let status: String?
    public let standing: TruthStanding?
    public let evidence: [TruthEvidence]
    public let basis: String?
    public let verifyBy: TruthVerifyBy?
    public let contests: String?
    /// An appeal: the open UVs contesting the TB.
    public let contestedBy: [TruthContestingUV]
    public let review: TruthDocketReview?
    public let migration: TruthDocketMigration?
    public let approvals: TruthApprovals?
    public let derivation: TruthTraceNode?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        kind = c.soft(TruthDocketKind.self, .kind) ?? .uv
        id = try c.decode(String.self, forKey: .id)
        subject = c.soft(String.self, .subject) ?? id
        text = c.soft(String.self, .text) ?? ""
        author = c.soft(String.self, .author) ?? ""
        agentSessionId = c.soft(String.self, .agentSessionId)
        createdAt = c.soft(Date.self, .createdAt)
        ageMs = c.soft(Double.self, .ageMs) ?? 0
        nominated = c.soft(Bool.self, .nominated) ?? false
        suspect = c.soft(Bool.self, .suspect) ?? false
        stale = c.soft(Bool.self, .stale) ?? false
        freshness = c.soft(TruthFreshness.self, .freshness)
        deferredUntil = c.soft(Date.self, .deferredUntil)
        status = c.soft(String.self, .status)
        standing = TruthStanding(wire: c.soft(String.self, .standing))
        evidence = c.soft([TruthEvidence].self, .evidence) ?? []
        basis = c.soft(String.self, .basis)
        verifyBy = c.soft(TruthVerifyBy.self, .verifyBy)
        contests = c.soft(String.self, .contests)
        review = c.soft(TruthDocketReview.self, .review)
        migration = c.soft(TruthDocketMigration.self, .migration)
        approvals = c.soft(TruthApprovals.self, .approvals)
        derivation = c.soft(TruthTraceNode.self, .derivation)
        // `appeals` nests the contesting UVs; the card wants them flat.
        if let appeals = try? c.nestedContainer(keyedBy: AppealKeys.self, forKey: .appeals) {
            contestedBy = (try? appeals.decodeIfPresent([TruthContestingUV].self, forKey: .contestedBy)) ?? []
        } else {
            contestedBy = (try? c.decodeIfPresent([TruthContestingUV].self, forKey: .contestedBy)) ?? []
        }
    }

    enum Keys: String, CodingKey {
        case kind, id, subject, text, author, agentSessionId, createdAt, ageMs, nominated, suspect, stale, freshness
        case deferredUntil, status, standing, evidence, basis, verifyBy, contests, appeals, contestedBy, review
        case migration, approvals, derivation
    }

    enum AppealKeys: String, CodingKey { case contestedBy }

    /// Pushed to the end until its date.
    public func isDeferred(now: Date = Date()) -> Bool {
        guard let deferredUntil else { return false }
        return deferredUntil > now
    }

    public var ageText: String { TruthTime.age(milliseconds: ageMs) }
}

public struct TruthDocket: Sendable, Codable, Hashable {
    public let items: [TruthDocketItem]
    public let size: Int
    public let nominated: Int
    public let stale: Int
    public let asOf: Date?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        items = (try? c.decodeIfPresent([LossyItem].self, forKey: .items))?.compactMap(\.value) ?? []
        size = c.soft(Int.self, .size) ?? items.count
        nominated = c.soft(Int.self, .nominated) ?? 0
        stale = c.soft(Int.self, .stale) ?? 0
        asOf = c.soft(Date.self, .asOf)
    }

    enum Keys: String, CodingKey { case items, size, nominated, stale, asOf }

    private struct LossyItem: Decodable {
        let value: TruthDocketItem?
        init(from decoder: Decoder) throws { value = try? TruthDocketItem(from: decoder) }
    }
}

/// `GET /api/truth/review`: the session's opening view.
public struct TruthReviewPayload: Sendable, Codable, Hashable {
    public let ledger: TruthLedger?
    public let docket: TruthDocket
    public let review: TruthReviewSchedule

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        ledger = c.soft(TruthLedger.self, .ledger)
        docket = try c.decode(TruthDocket.self, forKey: .docket)
        review = c.soft(TruthReviewSchedule.self, .review) ?? TruthReviewSchedule()
    }

    enum Keys: String, CodingKey { case ledger, docket, review }
}

// MARK: Decisions

public enum TruthAction: String, Sendable, CaseIterable, Identifiable, Hashable {
    case approve, refute, deferral = "defer", strike, ask

    public var id: String { rawValue }
}

/// What an action does to a card, and whether it is on offer.
public struct TruthActionState: Sendable, Equatable {
    public let action: TruthAction
    public let label: String
    /// One line on what it does.
    public let explanation: String
    public let isAvailable: Bool
    /// Why it is not on offer, when it is not.
    public let unavailableReason: String?
}

/// What the person has typed for a decision.
public struct TruthDecisionDraft: Sendable, Equatable {
    public var note = ""
    public var opinion = ""
    public var evidence: [TruthEvidenceDraft] = [TruthEvidenceDraft()]
    /// When a deferred item comes back; nil means a week.
    public var until: Date?
    /// On an appeal: the contesting UV the decision goes to.
    public var appealTarget: String?
    public var roomID: String?
    public var question = ""

    public init() {}
}

public struct TruthEvidenceDraft: Sendable, Equatable, Identifiable {
    public let id = UUID()
    public var kind: TruthEvidenceKind = .file
    public var ref = ""
    public var detail = ""

    public init(kind: TruthEvidenceKind = .file, ref: String = "", detail: String = "") {
        self.kind = kind
        self.ref = ref
        self.detail = detail
    }

    public static func == (lhs: TruthEvidenceDraft, rhs: TruthEvidenceDraft) -> Bool {
        lhs.kind == rhs.kind && lhs.ref == rhs.ref && lhs.detail == rhs.detail
    }

    public var isFilled: Bool { !ref.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var json: JSONValue {
        var out: [String: JSONValue] = ["kind": .string(kind.rawValue), "ref": .string(ref.trimmingCharacters(in: .whitespacesAndNewlines))]
        let note = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { out["detail"] = .string(note) }
        return .object(out)
    }
}

public enum TruthDocketRules {
    public static let mirrorReason = "This ledger mirrors stenographer: its items are decided there."
    public static let defaultDeferral: TimeInterval = 7 * 24 * 3600

    // MARK: What each action is, and whether it is on offer

    public static func state(of action: TruthAction, for item: TruthDocketItem, in ledger: TruthLedger?) -> TruthActionState {
        let label = self.label(of: action, for: item)
        let explanation = self.explanation(of: action, for: item)
        func make(_ reason: String?) -> TruthActionState {
            TruthActionState(action: action, label: label, explanation: explanation, isAvailable: reason == nil, unavailableReason: reason)
        }
        if let ledger, !ledger.isHosted { return make(mirrorReason) }
        let needsContestingUV = item.kind == .appeal && item.contestedBy.isEmpty
        switch action {
        case .approve:
            return make(needsContestingUV ? "No open UV is contesting this TB." : nil)
        case .refute:
            if item.kind == .appeal {
                return make("You signed this TB, so you cannot refute the appeal against it. Approve the appeal, strike it, or leave it standing.")
            }
            return make(nil)
        case .deferral:
            return make(nil)
        case .strike:
            if item.kind.isProposal { return make("This is a proposal: approve it or dismiss it.") }
            return make(needsContestingUV ? "No open UV is contesting this TB." : nil)
        case .ask:
            if item.kind.isProposal { return make("Only entries can be put to a room.") }
            return make(needsContestingUV ? "No open UV is contesting this TB." : nil)
        }
    }

    public static func label(of action: TruthAction, for item: TruthDocketItem) -> String {
        switch action {
        case .approve:
            if item.kind.isProposal { return "Approve" }
            return item.kind == .appeal ? "Approve appeal" : "Approve"
        case .refute: return item.kind.isProposal ? "Dismiss" : "Refute"
        case .deferral: return "Defer"
        case .strike: return "Strike"
        case .ask: return "Ask an agent"
        }
    }

    /// One line, in the person's terms, on what the action does to this card.
    public static func explanation(of action: TruthAction, for item: TruthDocketItem) -> String {
        switch action {
        case .approve:
            switch item.kind {
            case .migration:
                return "Asserts this page line as a UV in your name; it then waits for a second approver like any UV."
            case .derivationReview:
                return "Asserts the detector's UV in your name, contesting the premise."
            case .appeal:
                return "Approves the UV that contests this TB. With a second approver it overturns the TB."
            case .uv:
                let waiting = item.approvals?.missingBesidesYou ?? []
                if waiting.isEmpty { return "Promotes the UV: a TB signed by you, answerable to you, carrying the approvals." }
                return "Your approval goes on the record. The UV is promoted once \(joined(waiting)) arrive\(waiting.count == 1 ? "s" : ""): ask an agent to verify it with settling evidence."
            }
        case .refute:
            switch item.kind {
            case .migration: return "Dismisses this page line for good; importing the page again will not raise it."
            case .derivationReview: return "Dismisses the review; the detector will not raise it again."
            case .appeal: return "Not yours to refute: you signed the TB."
            case .uv: return "Refutes it with evidence you give. Anything resting on it is looked at again."
            }
        case .deferral:
            return "Sets it aside until a date you choose (a week by default). It moves to the end of the docket."
        case .strike:
            if item.kind == .appeal { return "Strikes the UV contesting this TB, with your opinion. A struck appeal releases the TB." }
            return "Strikes it with your opinion, answerable to you. A struck item stays struck."
        case .ask:
            return "Puts the claim, basis and verify-by to an agent room as you. The replies come back on this card."
        }
    }

    private static func joined(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + (items.last ?? "")
        }
    }

    // MARK: Where it goes and what it carries

    /// The id the decision is posted to: on an appeal, the contesting UV the
    /// person chose (the first, if they chose none); deferring always goes to the card.
    public static func target(of action: TruthAction, for item: TruthDocketItem, draft: TruthDecisionDraft) -> String? {
        if action == .deferral || item.kind != .appeal { return item.id }
        if let chosen = draft.appealTarget, item.contestedBy.contains(where: { $0.id == chosen }) { return chosen }
        return item.contestedBy.first?.id
    }

    /// What is missing before the action can be sent, as a sentence; nil when it can.
    public static func problem(with action: TruthAction, for item: TruthDocketItem, draft: TruthDecisionDraft) -> String? {
        switch action {
        case .refute where !item.kind.isProposal:
            return draft.evidence.contains(where: \.isFilled) ? nil : "Give at least one piece of evidence."
        case .strike:
            return draft.opinion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Say why, in your own words." : nil
        case .ask:
            return (draft.roomID ?? "").isEmpty ? "Pick a room to ask." : nil
        default:
            return nil
        }
    }

    /// The request body of `POST /api/truth/review/{id}` (or `.../ask`).
    public static func body(of action: TruthAction, for item: TruthDocketItem, ledger: String, draft: TruthDecisionDraft, now: Date = Date()) -> JSONValue {
        var body: [String: JSONValue] = ["ledger": .string(ledger)]
        let note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
        switch action {
        case .approve:
            body["action"] = "approve"
            if !note.isEmpty, !item.kind.isProposal { body["note"] = .string(note) }
        case .refute:
            body["action"] = "refute"
            if !item.kind.isProposal {
                body["evidence"] = .array(draft.evidence.filter(\.isFilled).map(\.json))
                if !note.isEmpty { body["note"] = .string(note) }
            }
        case .deferral:
            body["action"] = "defer"
            if let until = draft.until { body["until"] = .string(HVDate.format(until)) }
        case .strike:
            body["action"] = "strike"
            body["opinion"] = .string(draft.opinion.trimmingCharacters(in: .whitespacesAndNewlines))
        case .ask:
            if let room = draft.roomID, !room.isEmpty { body["room_id"] = .string(room) }
            let question = draft.question.trimmingCharacters(in: .whitespacesAndNewlines)
            if !question.isEmpty { body["question"] = .string(question) }
        }
        return .object(body)
    }

    /// Undoing a deferral: ask for the card back by deferring it to a moment ago.
    public static func undoDeferralBody(ledger: String, now: Date = Date()) -> JSONValue {
        .object(["action": "defer", "ledger": .string(ledger), "until": .string(HVDate.format(now.addingTimeInterval(-1)))])
    }
}

// MARK: What a decision answers

public struct TruthDecisionOutcome: Sendable, Decodable {
    public let id: String
    public let action: String
    /// "promoted", "approved", "nominated", "refuted", "struck", "filed", "dismissed"; nil for a deferral.
    public let status: String?
    public let deferredUntil: Date?
    /// What promotion still needs, when the answer carries a summary.
    public let missing: [String]
    public let reviews: Int?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = c.soft(String.self, .id) ?? ""
        action = c.soft(String.self, .action) ?? ""
        status = c.soft(String.self, .status)
        deferredUntil = c.soft(Date.self, .deferredUntil)
        // `approvals` is a summary object, or (after a promotion) the list of approvals.
        if let summary = try? c.nestedContainer(keyedBy: SummaryKeys.self, forKey: .approvals) {
            missing = (try? summary.decodeIfPresent([String].self, forKey: .missing)) ?? []
        } else {
            missing = []
        }
        reviews = c.soft(Int.self, .reviews)
    }

    enum Keys: String, CodingKey { case id, action, status, deferredUntil, approvals, reviews }
    enum SummaryKeys: String, CodingKey { case missing }

    /// The sentence for the toast: what happened, in the web's words.
    public var sentence: String {
        switch status {
        case "promoted": return "Promoted: the TB is written, signed by you."
        case "approved", "nominated":
            let waiting = missing.filter { $0 != "a human approval" }
            return waiting.isEmpty ? "Your approval is on the record." : "Your approval is on the record. Still needs \(waiting.joined(separator: ", "))."
        case "refuted":
            if let reviews, reviews > 0 { return "Refuted; \(reviews) derivation review\(reviews == 1 ? "" : "s") filed." }
            return "Refuted."
        case "struck": return "Struck."
        case "filed": return "Asserted the UV against the premise."
        case "dismissed": return "Dismissed."
        default: return action == "defer" ? "Deferred." : "Done."
        }
    }

    /// Whether the card should leave the deck: every decision but an approval that did not complete.
    public var settled: Bool { status != "approved" }
}

public struct TruthRoomChoice: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        title = c.soft(String.self, .title) ?? "Untitled room"
    }

    enum Keys: String, CodingKey { case id, title }
}

public struct TruthRoomList: Sendable, Decodable {
    public let rooms: [TruthRoomChoice]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        rooms = c.soft([TruthRoomChoice].self, .rooms) ?? []
    }

    enum Keys: String, CodingKey { case rooms }
}

public struct TruthAgentReply: Sendable, Decodable, Hashable, Identifiable {
    public let handle: String?
    public let content: String
    public let status: String?
    public let createdAt: Date?

    public var id: String { "\(handle ?? "agent")|\(createdAt?.timeIntervalSince1970 ?? 0)|\(content.prefix(16))" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        handle = c.soft(String.self, .handle)
        content = c.soft(String.self, .content) ?? ""
        status = c.soft(String.self, .status)
        createdAt = c.soft(Date.self, .createdAt)
    }

    enum Keys: String, CodingKey { case handle, content, status, createdAt }
}

/// What asking a room answers: the replies, or the rooms that could be asked.
public struct TruthAskAnswer: Sendable, Decodable {
    public let replies: [TruthAgentReply]?
    public let pending: Bool
    public let rooms: [TruthRoomChoice]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        replies = c.soft([TruthAgentReply].self, .answer)
        pending = (c.soft(Bool.self, .pending) ?? false) || (c.soft(Int.self, .pending) ?? 0) > 0
        rooms = c.soft([TruthRoomChoice].self, .rooms) ?? []
    }

    enum Keys: String, CodingKey { case answer, pending, rooms }
}

// MARK: The deck

/// The cards of a session in the order the server listed them. What the person
/// has dealt with this session stays out of the way, including an approval
/// that did not complete (the card is still on the docket, but they are done
/// with it for now), and so does anything deferred to a later date.
public struct TruthDeck: Sendable, Equatable {
    public private(set) var items: [TruthDocketItem]
    public private(set) var handled: Set<String>
    /// The clock a deferral is measured against.
    public private(set) var now: Date

    public init(items: [TruthDocketItem] = [], handled: Set<String> = [], now: Date = Date()) {
        self.items = items
        self.handled = handled
        self.now = now
    }

    public var remaining: [TruthDocketItem] {
        items.filter { !handled.contains($0.id) && !$0.isDeferred(now: now) }
    }

    public var current: TruthDocketItem? { remaining.first }
    public var next: TruthDocketItem? { remaining.dropFirst().first }

    /// Cards dealt with so far this session (and still on the docket).
    public var dealtWith: Int { items.filter { handled.contains($0.id) }.count }

    /// 1-based position of the current card.
    public var position: Int { dealtWith + 1 }

    /// Cards in this session: what is dealt with and what is left.
    public var total: Int { dealtWith + remaining.count }

    public var isFinished: Bool { remaining.isEmpty }

    public mutating func markHandled(_ id: String) { handled.insert(id) }
    public mutating func unmark(_ id: String) { handled.remove(id) }

    /// Put a card at the back of the pile for now (it stays on the docket).
    public mutating func skip(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let card = items.remove(at: index)
        items.append(card)
    }

    /// A fresh docket from the server: keep what was handled if it is still there.
    public mutating func replace(with fresh: [TruthDocketItem], now: Date = Date()) {
        items = fresh
        handled = handled.intersection(fresh.map(\.id))
        self.now = now
    }
}

// MARK: Asserting

/// A TB or UV the person writes.
public struct TruthAssertDraft: Sendable, Equatable {
    public var type: TruthEntryType = .uv
    public var text = ""
    public var basis = ""
    public var verifyBy = ""
    public var evidence: [TruthEvidenceDraft] = [TruthEvidenceDraft()]
    public var deadValue = ""
    public var subject = ""
    public var currentValue = ""

    public init(type: TruthEntryType = .uv) { self.type = type }

    private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// What is missing, as a sentence; nil when it can be sent.
    public var problem: String? {
        if trimmed(text).isEmpty { return type == .tb ? "Say what is settled." : "Say what you believe." }
        switch type {
        case .tb: return evidence.contains(where: \.isFilled) ? nil : "A TB needs at least one piece of evidence."
        case .uv: return trimmed(basis).isEmpty ? "Say why you believe it." : nil
        }
    }

    public var canSend: Bool { problem == nil }

    /// The body of `POST /api/truth/entries`. Keys go out exactly as the route reads them.
    public func body(ledger: String) -> JSONValue {
        var out: [String: JSONValue] = ["type": .string(type.rawValue), "ledger": .string(ledger)]
        switch type {
        case .tb:
            out["claim"] = .string(trimmed(text))
            out["evidence"] = .array(evidence.filter(\.isFilled).map(\.json))
            if !trimmed(deadValue).isEmpty {
                var literal: [String: JSONValue] = ["dead": .string(trimmed(deadValue))]
                if !trimmed(subject).isEmpty { literal["subject"] = .string(trimmed(subject)) }
                if !trimmed(currentValue).isEmpty { literal["current"] = .string(trimmed(currentValue)) }
                out["literals"] = .array([.object(literal)])
            }
        case .uv:
            out["assertion"] = .string(trimmed(text))
            out["basis"] = .string(trimmed(basis))
            out["verifyBy"] = .object(["kind": "inspect", "value": .string(trimmed(verifyBy).isEmpty ? "(unspecified)" : trimmed(verifyBy))])
        }
        return .object(out)
    }
}

/// `POST /api/truth/entries` answers (201) the line as written.
public struct TruthAssertResult: Sendable, Decodable {
    public let line: TruthLine?
    public let standing: TruthStanding?
    public let overrode: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        line = c.soft(TruthLine.self, .line)
        standing = TruthStanding(wire: c.soft(String.self, .standing))
        overrode = c.soft(String.self, .overrode)
    }

    enum Keys: String, CodingKey { case line, standing, overrode }
}

// MARK: The truth handle

public enum TruthHandle {
    /// A first check before asking the server (which holds the real rules: nothing
    /// blank, anonymous, reserved or with control characters). nil when it looks fine.
    public static func problem(_ handle: String) -> String? {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Choose a name to sign under." }
        if trimmed.count > 64 { return "Keep it to 64 characters." }
        if trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { return "Use plain characters." }
        return nil
    }
}

extension HVError {
    /// `409` with `handle_required`: the person has not chosen the name they sign under.
    public var isTruthHandleRequired: Bool {
        guard case .api(let failure) = self, failure.status == 409 else { return false }
        return failure.body?["handle_required"]?.bool == true
    }
}
