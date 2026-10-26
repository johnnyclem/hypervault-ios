import Foundation

// Truth routes: app/api/truth/**. Every one takes `ledger=<slug>` (the default
// when left out). Acts that are the person's alone (decisions, TBs, creating a
// ledger, dismissing, the handle) answer 403 to an agent key; the app always
// calls as the person.

private func ledgerQuery(_ slug: String?, _ extra: [(String, String?)] = []) -> [URLQueryItem] {
    .make([("ledger", slug)] + extra)
}

extension Endpoint where Response == TruthLedgerList {
    public static var truthLedgers: Endpoint<TruthLedgerList> { Endpoint(.get, "/api/truth/ledgers") }
}

extension Endpoint where Response == TruthLedgerEnvelope {
    /// A new ledger. A hosted one is written here; a mirror is filled by importing.
    public static func createTruthLedger(slug: String, name: String? = nil, kind: TruthLedgerKind) -> Endpoint<TruthLedgerEnvelope> {
        var body: [String: JSONValue] = ["slug": .string(slug), "kind": .string(kind.rawValue)]
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { body["name"] = .string(name) }
        return Endpoint(.post, "/api/truth/ledgers", body: .jsonValue(.object(body)))
    }
}

extension Endpoint where Response == TruthOverview {
    public static func truth(ledger: String? = nil) -> Endpoint<TruthOverview> {
        Endpoint(.get, "/api/truth", query: ledgerQuery(ledger))
    }
}

extension Endpoint where Response == TruthDerivation {
    /// The trace: the premises under an entry, the failing one marked, and what rests on it.
    public static func truthDerivation(id: String, ledger: String? = nil) -> Endpoint<TruthDerivation> {
        Endpoint(.get, "/api/truth/\(id)/derivation", query: ledgerQuery(ledger))
    }
}

extension Endpoint where Response == TruthRipple {
    public static func truthRipple(id: String, ledger: String? = nil) -> Endpoint<TruthRipple> {
        Endpoint(.get, "/api/truth/\(id)/ripple", query: ledgerQuery(ledger))
    }
}

extension Endpoint where Response == TruthStaleWorklist {
    /// Every memory and page whose entries moved. Across every ledger unless one is named.
    public static func truthStale(ledger: String? = nil) -> Endpoint<TruthStaleWorklist> {
        Endpoint(.get, "/api/truth/stale", query: ledgerQuery(ledger))
    }
}

extension Endpoint where Response == NoContent {
    public static func resolveTruthStale(_ resolution: TruthStaleResolution, item: TruthContextItem, entries: [String], to successors: [String] = [], ledger: String?) -> Endpoint<NoContent> {
        Endpoint(.post, "/api/truth/stale", body: .jsonValue(resolution.body(item: item, entries: entries, to: successors, ledger: ledger)))
    }

    /// Drop an entry from a mirror ledger's read model (the stream keeps its lines).
    public static func deleteTruthEntry(id: String, ledger: String?) -> Endpoint<NoContent> {
        Endpoint(.delete, "/api/truth/\(id)", query: ledgerQuery(ledger))
    }

    /// Dismissing a draft or the sidecar's proposal never answers anything the app reads.
    public static func setTruthProposal(id: String, status: TruthProposalStatus, ledger: String?) -> Endpoint<NoContent> {
        Endpoint(.patch, "/api/truth/proposals/\(id)", query: ledgerQuery(ledger), body: .jsonValue(.object(["status": .string(status.rawValue)])))
    }

    /// Sitting down to review restarts the reminder clock.
    public static func startTruthReview() -> Endpoint<NoContent> {
        Endpoint(.post, "/api/truth/review", body: .jsonValue(.object([:])))
    }
}

extension Endpoint where Response == TruthReviewPayload {
    public static func truthReview(ledger: String) -> Endpoint<TruthReviewPayload> {
        Endpoint(.get, "/api/truth/review", query: ledgerQuery(ledger))
    }
}

extension Endpoint where Response == TruthReviewScheduleEnvelope {
    public static func setTruthCadence(_ cadence: TruthCadence?) -> Endpoint<TruthReviewScheduleEnvelope> {
        Endpoint(.put, "/api/truth/review", body: .jsonValue(.object(["cadence": cadence.map { .string($0.rawValue) } ?? .null])))
    }
}

extension Endpoint where Response == TruthDecisionOutcome {
    /// The person's decision on a docket item. `target` is the item, or on an appeal the contesting UV.
    public static func decideTruth(target: String, body: JSONValue) -> Endpoint<TruthDecisionOutcome> {
        Endpoint(.post, "/api/truth/review/\(target)", body: .jsonValue(body))
    }
}

extension Endpoint where Response == TruthAskAnswer {
    /// "Ask an agent": the item goes to an agent room as the person; the replies come back.
    public static func askTruth(target: String, body: JSONValue) -> Endpoint<TruthAskAnswer> {
        Endpoint(.post, "/api/truth/review/\(target)/ask", body: .jsonValue(body), timeout: 120)
    }
}

extension Endpoint where Response == TruthRoomList {
    public static var truthRooms: Endpoint<TruthRoomList> { Endpoint(.get, "/api/rooms") }
}

extension Endpoint where Response == TruthAssertResult {
    public static func assertTruth(_ draft: TruthAssertDraft, ledger: String) -> Endpoint<TruthAssertResult> {
        Endpoint(.post, "/api/truth/entries", body: .jsonValue(draft.body(ledger: ledger)))
    }
}

extension Endpoint where Response == TruthHandleResult {
    /// Choose the name truth is signed under. Once; the same again is fine, a different one is a 409.
    public static func setTruthHandle(_ handle: String) -> Endpoint<TruthHandleResult> {
        Endpoint(.put, "/api/truth/handle", body: .jsonValue(.object(["handle": .string(handle.trimmingCharacters(in: .whitespacesAndNewlines))])))
    }
}

extension Endpoint where Response == TruthSigners {
    public static var truthSigners: Endpoint<TruthSigners> { Endpoint(.get, "/api/truth/signers") }
}

extension Endpoint where Response == TruthEventList {
    public static func truthEvents(limit: Int = 50, kinds: [TruthEventKind] = []) -> Endpoint<TruthEventList> {
        Endpoint(.get, "/api/truth/events", query: .make([
            ("limit", String(limit)),
            ("kind", kinds.isEmpty ? nil : kinds.map(\.rawValue).joined(separator: ",")),
        ]))
    }
}

extension Endpoint where Response == TruthProposalList {
    public static func truthProposals(status: TruthProposalStatus = .open, ledger: String? = nil) -> Endpoint<TruthProposalList> {
        Endpoint(.get, "/api/truth/proposals", query: ledgerQuery(ledger, [("status", status.rawValue)]))
    }
}

extension Endpoint where Response == TruthInbox {
    public static var truthInbox: Endpoint<TruthInbox> { Endpoint(.get, "/api/truth/inbox") }
}

extension Endpoint where Response == TruthInboxDecision {
    /// Sign a sidecar proposal as its notary, under the person's truth handle.
    public static func notarizeTruth(id: String) -> Endpoint<TruthInboxDecision> {
        Endpoint(.post, "/api/truth/inbox/\(id)", body: .jsonValue(.object(["action": "notarize"])))
    }

    public static func dismissSidecarProposal(id: String, reason: String) -> Endpoint<TruthInboxDecision> {
        Endpoint(.post, "/api/truth/inbox/\(id)", body: .jsonValue(.object(["action": "dismiss", "reason": .string(reason)])))
    }
}

extension Endpoint where Response == TruthImportResult {
    /// One file of a stenographer stream into a mirror ledger.
    public static func importTruth(jsonl: String, ledger: String?) -> Endpoint<TruthImportResult> {
        Endpoint(
            .post, "/api/truth/import", query: ledgerQuery(ledger),
            body: .raw(Data(jsonl.utf8), contentType: "application/x-ndjson"), timeout: 60
        )
    }
}

extension Endpoint where Response == TruthPageImportResult {
    /// A page ledger, by the page's slug or pasted lines. Every line is a proposal; none is truth yet.
    public static func importTruthPage(slug: String? = nil, jsonl: String? = nil, ledger: String?) -> Endpoint<TruthPageImportResult> {
        var body: [String: JSONValue] = [:]
        if let slug, !slug.isEmpty { body["slug"] = .string(slug) }
        if let jsonl, !jsonl.isEmpty { body["jsonl"] = .string(jsonl) }
        return Endpoint(.post, "/api/truth/import/page", query: ledgerQuery(ledger), body: .jsonValue(.object(body)), timeout: 60)
    }
}

extension Endpoint where Response == Data {
    /// The ledger's stream, every line verbatim in seq order.
    public static func exportTruth(ledger: String?, sinceSeq: Int? = nil) -> Endpoint<Data> {
        Endpoint(data: .get, "/api/truth/export", query: ledgerQuery(ledger, [("sinceSeq", sinceSeq.map(String.init))]))
    }

    /// The ledger's proposals stream. `mark` writes the chain: the drafts become "exported".
    public static func exportTruthProposals(ledger: String?, mark: Bool) -> Endpoint<Data> {
        Endpoint(data: .get, "/api/truth/proposals/export", query: ledgerQuery(ledger, [("status", "open"), ("mark", mark ? "1" : nil)]))
    }
}

extension Endpoint where Response == TruthChatSetting {
    /// Whether chat cites the ledgers.
    public static func citeTruthInChat(_ on: Bool) -> Endpoint<TruthChatSetting> {
        Endpoint(.patch, "/api/chat-settings", body: .jsonValue(.object(["truth": .bool(on)])))
    }
}
