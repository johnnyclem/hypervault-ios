import Foundation

// Moving truth in and out: proposal drafts, the sidecar's inbox, importing a
// stream or a page ledger, and the export files.

private extension KeyedDecodingContainer {
    func soft<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

// MARK: Proposal drafts

public enum TruthProposalStatus: String, Sendable, Codable, CaseIterable, Identifiable, Hashable {
    case open, exported, filed, dismissed

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TruthProposalStatus(rawValue: raw) ?? .open
    }

    /// Where a draft in this state can be moved. Dismissing is the person's act and is sticky:
    /// the candidate is never proposed again.
    public var moves: [TruthProposalStatus] {
        switch self {
        case .open, .exported: return [.filed, .dismissed]
        case .filed, .dismissed: return [.open]
        }
    }

    public var moveTitle: String {
        switch self {
        case .open: return "Reopen"
        case .exported: return "Mark exported"
        case .filed: return "Mark filed"
        case .dismissed: return "Dismiss"
        }
    }
}

/// A draft chat compaction (or an agent) staged for stenographer to file.
public struct TruthProposal: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    /// "tombstone" (a TB draft) or "uv".
    public let kind: String
    public let targetRef: String
    public let line: JSONValue
    public let origin: String
    public let status: TruthProposalStatus
    public let createdAt: Date?
    public let exportedAt: Date?
    public let decidedAt: Date?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = c.soft(String.self, .kind) ?? "uv"
        targetRef = c.soft(String.self, .targetRef) ?? ""
        line = c.soft(JSONValue.self, .line) ?? .null
        origin = c.soft(String.self, .origin) ?? "api"
        status = c.soft(TruthProposalStatus.self, .status) ?? .open
        createdAt = c.soft(Date.self, .createdAt)
        exportedAt = c.soft(Date.self, .exportedAt)
        decidedAt = c.soft(Date.self, .decidedAt)
    }

    enum Keys: String, CodingKey { case id, kind, targetRef, line, origin, status, createdAt, exportedAt, decidedAt }

    public var isTombstone: Bool { kind == "tombstone" }

    /// Where the draft came from, in words: the origin is a slug ("chat-compaction", "api").
    public var originPhrase: String {
        switch origin {
        case "chat-compaction": return "chat"
        case "api": return "the API"
        default: return origin.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        }
    }

    private var draft: JSONValue? { line["draft"] ?? (line["kind"] != nil ? line : nil) }

    /// The words of the draft: a TB's claim or a UV's assertion.
    public var headline: String {
        let key = isTombstone ? "claim" : "assertion"
        return draft?[key]?.string ?? "(no text)"
    }

    public var evidenceLines: [String] {
        draft?["evidence"]?.array?.compactMap { item -> String? in
            if let text = item.string { return text }
            guard let ref = item["ref"]?.string else { return nil }
            return [item["kind"]?.string, ref].compactMap { $0 }.joined(separator: " ")
        } ?? []
    }

    public var basis: String? { draft?["basis"]?.string }

    public var verifyBy: String? {
        guard let value = draft?["verifyBy"] else { return nil }
        if let text = value.string { return text }
        return TruthVerifyBy(kind: value["kind"]?.string ?? "inspect", value: value["value"]?.string ?? "", detail: value["detail"]?.string).sentence
    }

    public var signalDetail: String? { line["signal"]?["detail"]?.string }
}

public struct TruthProposalList: Sendable, Codable, Equatable {
    public let proposals: [TruthProposal]

    public init(proposals: [TruthProposal] = []) { self.proposals = proposals }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        proposals = c.soft([TruthProposal].self, .proposals) ?? []
    }

    enum Keys: String, CodingKey { case proposals }
}

extension TruthProposal: Equatable {}

// MARK: The sidecar's inbox

public struct SidecarProposal: Sendable, Decodable, Hashable, Identifiable {
    public let id: String
    public let author: String?
    public let createdAt: Date?
    public let kind: String
    public let draft: JSONValue?
    public let signalDetail: String?
    public let targetRef: String?
    public let requiresNotary: Bool

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        author = c.soft(String.self, .author)
        createdAt = c.soft(Date.self, .createdAt)
        let body = c.soft(JSONValue.self, .body)
        kind = body?["kind"]?.string ?? "uv"
        draft = body?["draft"]
        signalDetail = body?["signal"]?["detail"]?.string
        targetRef = body?["targetRef"]?.string
        requiresNotary = body?["requiresNotary"]?.bool ?? false
    }

    enum Keys: String, CodingKey { case id, author, createdAt, body }

    public var isTombstone: Bool { kind == "tombstone" }

    public var headline: String {
        draft?[isTombstone ? "claim" : "assertion"]?.string ?? "(no text)"
    }

    public var basis: String? { draft?["basis"]?.string }
}

public struct SidecarObjection: Sendable, Decodable, Hashable, Identifiable {
    public let id: String
    public let createdAt: Date?
    public let tbId: String?
    public let literal: String?
    public let objection: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        createdAt = c.soft(Date.self, .createdAt)
        tbId = c.soft(String.self, .tbId)
        literal = c.soft(String.self, .literal)
        objection = c.soft(String.self, .objection)
    }

    enum Keys: String, CodingKey { case id, createdAt, tbId, literal, objection }
}

/// `GET /api/truth/inbox`. A list is nil when the sidecar did not answer that route.
public struct TruthInbox: Sendable, Decodable {
    public let configured: Bool
    public let notary: Bool
    public let proposals: [SidecarProposal]?
    public let objections: [SidecarObjection]?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        configured = c.soft(Bool.self, .configured) ?? false
        notary = c.soft(Bool.self, .notary) ?? false
        proposals = c.soft([SidecarProposal].self, .proposals)
        objections = c.soft([SidecarObjection].self, .objections)
    }

    enum Keys: String, CodingKey { case configured, notary, proposals, objections }
}

public struct TruthInboxDecision: Sendable, Decodable {
    public let signedBy: String?
    public let dismissedBy: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        signedBy = c.soft(String.self, .signedBy)
        dismissedBy = c.soft(String.self, .dismissedBy)
    }

    enum Keys: String, CodingKey { case signedBy, dismissedBy }
}

// MARK: The person's handle

/// `GET /api/truth/signers`: the signer registry. The `human` entry is the person.
public struct TruthSigners: Sendable, Decodable {
    public struct Signer: Sendable, Decodable, Hashable, Identifiable {
        public let id: String
        public let role: String

        public init(id: String, role: String) {
            self.id = id
            self.role = role
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            id = c.soft(String.self, .id) ?? ""
            role = c.soft(String.self, .role) ?? "agent"
        }

        enum Keys: String, CodingKey { case id, role }

        public var isHuman: Bool { role == "human" }
    }

    public let signers: [Signer]

    public init(signers: [Signer] = []) { self.signers = signers }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        signers = c.soft([Signer].self, .signers) ?? []
    }

    enum Keys: String, CodingKey { case signers }

    /// The name the person signs under, once chosen.
    public var handle: String? { signers.first(where: \.isHuman)?.id }
    public var agents: [Signer] { signers.filter { !$0.isHuman } }
}

public struct TruthHandleResult: Sendable, Decodable {
    public let handle: String
}

// MARK: Importing

public struct TruthImportLineError: Sendable, Decodable, Hashable, Identifiable {
    public let line: Int
    public let error: String

    public var id: String { "\(line)|\(error)" }

    public init(line: Int, error: String) {
        self.line = line
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        line = c.soft(Int.self, .line) ?? 0
        error = c.soft(String.self, .error) ?? "Refused."
    }

    enum Keys: String, CodingKey { case line, error }
}

/// `POST /api/truth/import`: one transaction per file.
public struct TruthImportResult: Sendable, Decodable {
    public let committed: Bool
    public let lines: Int
    public let upserted: Int
    public let errors: [TruthImportLineError]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        committed = c.soft(Bool.self, .committed) ?? true
        lines = c.soft(Int.self, .lines) ?? 0
        upserted = c.soft(Int.self, .upserted) ?? 0
        errors = c.soft([TruthImportLineError].self, .errors) ?? []
    }

    enum Keys: String, CodingKey { case committed, lines, upserted, errors }

    public var sentence: String {
        upserted == 0 ? "Nothing new: the ledger already held every line." : "Imported \(upserted) entr\(upserted == 1 ? "y" : "ies") from \(lines) new line\(lines == 1 ? "" : "s")."
    }
}

/// `POST /api/truth/import/page`: every line of a page ledger becomes a proposal on the docket.
public struct TruthPageImportResult: Sendable, Decodable {
    public let filed: Int
    public let skipped: Int
    public let errors: [TruthImportLineError]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        filed = c.soft(Int.self, .filed) ?? 0
        skipped = c.soft(Int.self, .skipped) ?? 0
        errors = c.soft([TruthImportLineError].self, .errors) ?? []
    }

    enum Keys: String, CodingKey { case filed, skipped, errors }

    public var sentence: String {
        if filed == 0 { return skipped > 0 ? "Nothing new: those lines are already on the docket." : "No lines were found." }
        return "\(filed) line\(filed == 1 ? "" : "s") waiting on the docket. Nothing is truth until you approve it there."
    }
}

public enum TruthImportFailure {
    /// The lines a refused file was refused on (a 422 carries every bad line by number).
    public static func lineErrors(in error: Error) -> [TruthImportLineError] {
        guard let hv = error as? HVError, case .api(let failure) = hv,
              let list = failure.body?["errors"]?.array
        else { return [] }
        return list.compactMap { item in
            guard let line = item["line"]?.int, let text = item["error"]?.string else { return nil }
            return TruthImportLineError(line: line, error: text)
        }
    }
}

/// A look at a JSONL file before it is sent: how many lines and of what, and
/// the first line that is not a JSON object. The server's codec is the judge;
/// this only saves a round trip for an obvious mistake.
public struct TruthImportPreview: Sendable, Equatable {
    public var lineCount = 0
    public var tbCount = 0
    public var uvCount = 0
    public var otherCount = 0
    public var firstProblem: TruthImportLineError?
    public var bytes = 0

    public init() {}

    public static let maxBytes = 2_000_000

    public static func parse(_ text: String) -> TruthImportPreview {
        var out = TruthImportPreview()
        out.bytes = text.utf8.count
        var number = 0
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            number += 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            out.lineCount += 1
            guard let data = line.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                if out.firstProblem == nil { out.firstProblem = TruthImportLineError(line: number, error: "This line is not a JSON object.") }
                continue
            }
            switch object["type"] as? String {
            case "TB": out.tbCount += 1
            case "UV": out.uvCount += 1
            default: out.otherCount += 1
            }
        }
        return out
    }

    public var isTooLarge: Bool { bytes > Self.maxBytes }

    public var canSend: Bool { lineCount > 0 && firstProblem == nil && !isTooLarge }

    public var summary: String {
        guard lineCount > 0 else { return "Nothing to import." }
        var parts: [String] = []
        if tbCount > 0 { parts.append("\(tbCount) TB") }
        if uvCount > 0 { parts.append("\(uvCount) UV") }
        if otherCount > 0 { parts.append("\(otherCount) other") }
        return "\(lineCount) line\(lineCount == 1 ? "" : "s"): \(parts.joined(separator: ", "))."
    }
}

public enum TruthFiles {
    /// `truth-<slug>.jsonl`, the route's own name for an export.
    public static func exportName(slug: String) -> String { "truth-\(slug).jsonl" }
    public static func proposalsName(slug: String) -> String { "proposals-\(slug).jsonl" }
}

/// `PUT /api/truth/review` answers the schedule.
public struct TruthReviewScheduleEnvelope: Sendable, Decodable {
    public let review: TruthReviewSchedule
}

/// `PATCH /api/chat-settings { truth }`.
public struct TruthChatSetting: Sendable, Decodable {
    public let truth: Bool?
}
