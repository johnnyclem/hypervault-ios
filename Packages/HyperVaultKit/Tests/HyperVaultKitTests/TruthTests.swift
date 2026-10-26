import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

/// Lines are stenographer's own golden fixtures (spec/truth-format/fixtures/valid/ledger.jsonl and
/// derivation.jsonl); the envelopes are what app/api/truth/** answers.
final class TruthTests: XCTestCase {
    let base = URL(string: "https://hv.test")!

    func client(_ transport: MockTransport) -> HVClient {
        HVClient(baseURL: base, transport: transport, tokens: StaticTokenProvider(), retry: .none, sleep: { _ in })
    }

    // Fixture lines.
    static let tb1 = #"{"schemaVersion":2,"seq":1,"id":"01M1E6JK80P9Y3CMA9HBZEND9H","type":"TB","ts":"2026-09-01T10:00:00.000Z","author":"johnnyclem","claim":"LOG_BUDGET is 100; the old value 30 is dead.","evidence":[{"kind":"commit","ref":"9f2c1ab"},{"kind":"claimed-command","ref":"grep LOG_BUDGET config.ts","detail":"LOG_BUDGET = 100"}],"signedBy":"johnnyclem","literals":[{"dead":"30","subject":"LOG_BUDGET","current":"100"}],"answerableBy":"johnnyclem","status":"active","x-steno":{"origin":"local","links":[]},"prevHash":null,"hash":"c8d3"}"#
    static let uv1 = #"{"schemaVersion":2,"seq":2,"id":"01M1E6JK81TR57BA191BG8Y0Q3","type":"UV","ts":"2026-09-01T10:01:00.000Z","author":"sam","assertion":"Retries are idempotent across regions.","basis":"the design doc says so","verifyBy":{"kind":"inspect","value":"src/retry.ts","detail":"a region-scoped idempotency key"},"contests":null,"status":"open","x-steno":{"origin":"local","links":[]},"prevHash":"c8d3","hash":"c1c0"}"#
    static let uv2 = #"{"schemaVersion":2,"seq":3,"id":"01M1E6JK82QWPK6VS437JKMJPZ","type":"UV","ts":"2026-09-01T10:02:00.000Z","author":"alex","assertion":"LOG_BUDGET went back to 30 in the hotfix.","basis":"the hotfix notes","verifyBy":{"kind":"command","value":"grep LOG_BUDGET config.ts"},"contests":"01M1E6JK80P9Y3CMA9HBZEND9H","status":"open"}"#
    static let tb2 = #"{"id":"01M1E6JK8SQAJ8K0JBRHTD10YG","type":"TB","ts":"2026-09-01T10:52:00.000Z","author":"johnnyclem","claim":"Retries are capped at 5; the old cap of 3 is dead.","evidence":[{"kind":"test","ref":"test/retry.test.ts"}],"signedBy":"johnnyclem","answerableBy":"johnnyclem","status":"active"}"#
    static let uvRefuted = #"{"id":"01M1E6JK8RY2RTGX9TRXJABTWR","type":"UV","ts":"2026-09-01T10:51:00.000Z","author":"sam","assertion":"Each retry costs 20.","basis":"the pricing doc","verifyBy":{"kind":"inspect","value":"pricing.md"},"status":"refuted"}"#

    static var overviewJSON: String {
        """
        {"ledger":{"id":"l1","slug":"team","name":"Team","kind":"hosted"},
         "summary":{"cited":2,"contested":1,"flags":1,"displaced":1,"total":4,"open_proposals":3},
         "as_of":"2026-10-25T12:00:00.000Z","chat_truth":true,"sidecar":{"configured":false,"notary":false},
         "docket":{"size":3,"nominated":1,"stale":1,"as_of":"2026-10-25T12:00:00.000Z","oldest_age_ms":172800000},
         "review":{"cadence":"weekly","last_at":"2026-10-18T12:00:00.000Z","due":true,"next_at":"2026-10-25T12:00:00.000Z"},
         "citable":[
           {"entry":\(tb1),"standing":"sound","reasons":[],"answerable_by":"johnnyclem","contested_by":[\(uv2)]},
           {"entry":\(tb2),"standing":"clouded","reasons":[{"premise":"01M1E6JK81TR57BA191BG8Y0Q3","reason":"premise-open"}],"answerable_by":"johnnyclem","contested_by":[]}],
         "flags":[\(uv1)],
         "displaced":[\(uvRefuted)],
         "entries":[
           {"id":"01M1E6JK80P9Y3CMA9HBZEND9H","type":"TB","status":"contested","standing":"sound","reasons":[],"corroborated":false,"freshness":null,"answerable_by":"johnnyclem","author":"johnnyclem","ts":"2026-09-01T10:00:00.000Z","source":"manual","updated_at":"2026-10-20T00:00:00.000Z"},
           {"id":"01M1E6JK81TR57BA191BG8Y0Q3","type":"UV","status":"open","standing":"sound","reasons":[],"corroborated":true,"freshness":{"state":"stale","horizonSeconds":1814400,"since":"2026-09-01T10:01:00.000Z","anchor":{"kind":"asserted"},"at":"2026-10-25T12:00:00.000Z","expiresAt":"2026-09-22T10:01:00.000Z"},"answerable_by":null,"author":"sam","ts":"2026-09-01T10:01:00.000Z","source":"manual","updated_at":"2026-10-20T00:00:00.000Z"},
           {"id":"01M1E6JK8SQAJ8K0JBRHTD10YG","type":"TB","status":"active","standing":"clouded","reasons":[{"premise":"01M1E6JK81TR57BA191BG8Y0Q3","reason":"premise-open"}],"corroborated":false,"freshness":null,"answerable_by":"johnnyclem","author":"johnnyclem","ts":"2026-09-01T10:52:00.000Z","source":"manual","updated_at":"2026-10-20T00:00:00.000Z"},
           {"id":"01M1E6JK8RY2RTGX9TRXJABTWR","type":"UV","status":"refuted","standing":"sound","reasons":[],"corroborated":false,"freshness":null,"answerable_by":null,"author":"sam","ts":"2026-09-01T10:51:00.000Z","source":"manual","updated_at":"2026-10-20T00:00:00.000Z"}]}
        """
    }

    func overview() throws -> TruthOverview {
        try HVCoding.decoder().decode(TruthOverview.self, from: Data(Self.overviewJSON.utf8))
    }

    // MARK: Ledgers

    func testLedgerListChoosesDefaultsAndHosted() throws {
        let json = #"{"default":"default","ledgers":[{"id":"a","slug":"default","name":"Default","kind":"mirror","created_at":"2026-09-01T10:00:00.000Z","proposals_seq":0},{"id":"b","slug":"team","name":"Team","kind":"hosted","created_at":"2026-10-01T10:00:00.000Z","proposals_seq":4}]}"#
        let list = try HVCoding.decoder().decode(TruthLedgerList.self, from: Data(json.utf8))
        XCTAssertEqual(list.ledgers.count, 2)
        XCTAssertEqual(list.choose(preferring: nil)?.slug, "default")
        XCTAssertEqual(list.choose(preferring: "team")?.slug, "team")
        XCTAssertEqual(list.choose(preferring: "gone")?.slug, "default")
        XCTAssertEqual(list.chooseForReview(preferring: nil)?.slug, "team")
        XCTAssertEqual(list.hosted.map(\.slug), ["team"])
        XCTAssertTrue(list.ledgers[1].isHosted)
        XCTAssertEqual(list.ledgers[1].proposalsSeq, 4)
        // survives the cache
        let back = try HVCoding.decoder(.verbatim).decode(TruthLedgerList.self, from: try HVCoding.encoder(.verbatim).encode(list))
        XCTAssertEqual(back, list)
    }

    func testSlugRules() {
        XCTAssertNil(TruthLedgerSlug.problem("team-2"))
        XCTAssertNotNil(TruthLedgerSlug.problem("Team"))
        XCTAssertNotNil(TruthLedgerSlug.problem("-team"))
        XCTAssertNotNil(TruthLedgerSlug.problem(""))
        XCTAssertNotNil(TruthLedgerSlug.problem(String(repeating: "a", count: 65)))
        XCTAssertEqual(TruthLedgerSlug.suggest(from: "  Ana's  Case File!  "), "ana-s-case-file")
        XCTAssertNil(TruthLedgerSlug.problem(TruthLedgerSlug.suggest(from: "Ana's Case File")))
    }

    // MARK: Lines and standing

    func testALineReadsLikeTheLedgerWroteIt() throws {
        let tb = try HVCoding.decoder().decode(TruthLine.self, from: Data(Self.tb1.utf8))
        XCTAssertEqual(tb.type, .tb)
        XCTAssertEqual(tb.text, "LOG_BUDGET is 100; the old value 30 is dead.")
        XCTAssertEqual(tb.signedBy, "johnnyclem")
        XCTAssertEqual(tb.evidence.count, 2)
        XCTAssertEqual(tb.evidence[1].kind, "claimed-command")
        XCTAssertTrue(tb.evidence[0].isSettling)
        XCTAssertNotNil(tb.ts)

        let uv = try HVCoding.decoder().decode(TruthLine.self, from: Data(Self.uv1.utf8))
        XCTAssertEqual(uv.type, .uv)
        XCTAssertEqual(uv.text, "Retries are idempotent across regions.")
        XCTAssertEqual(uv.verifyBy?.sentence, "inspect: src/retry.ts (a region-scoped idempotency key)")
        XCTAssertNil(uv.contests)

        let contesting = try HVCoding.decoder().decode(TruthLine.self, from: Data(Self.uv2.utf8))
        XCTAssertEqual(contesting.contests, "01M1E6JK80P9Y3CMA9HBZEND9H")
    }

    func testStatusWordsAreHonest() {
        XCTAssertEqual(TruthStatus.label("contested"), "Under appeal")
        XCTAssertEqual(TruthStatus.label("active"), "Active")
        XCTAssertEqual(TruthStatus.label("struck"), "Struck")
        XCTAssertEqual(TruthStatus.label(nil), "Unknown")
        XCTAssertEqual(TruthStatus.label("weird"), "Weird")
        XCTAssertEqual(TruthStatus.tone("contested"), .attention)
        XCTAssertEqual(TruthStatus.tone("active"), .settled)
        XCTAssertEqual(TruthStatus.tone("refuted"), .history)
        XCTAssertEqual(TruthStatus.tone("open"), .open)
    }

    func testReasonsInWords() {
        let open = TruthReason(premise: "01M1E6JK81TR57BA191BG8Y0Q3", reason: "premise-open")
        XCTAssertEqual(open.phrase, "is still unverified")
        XCTAssertEqual(TruthReason(premise: "x", reason: "premise-under-appeal").phrase, "is under appeal")
        XCTAssertEqual(TruthReason(premise: "x", reason: "premise-struck").phrase, "was struck")
        XCTAssertEqual(TruthReason(premise: "x", reason: "premise-something-new").phrase, "something new")
        XCTAssertEqual(TruthReasons.sentence([open], standing: .clouded), "Clouded by …BG8Y0Q3 is still unverified.".replacingOccurrences(of: "…BG8Y0Q3", with: "…" + String("01M1E6JK81TR57BA191BG8Y0Q3".suffix(6))))
        XCTAssertNil(TruthReasons.sentence([open], standing: .sound))
        XCTAssertNil(TruthReasons.sentence([], standing: .clouded))
        let many = (1...4).map { TruthReason(premise: "premise-number-\($0)", reason: "premise-refuted") }
        XCTAssertTrue(TruthReasons.sentence(many, standing: .unsupported)?.hasPrefix("Cannot stand:") ?? false)
        XCTAssertTrue(TruthReasons.sentence(many, standing: .unsupported)?.hasSuffix("and 2 more.") ?? false)
        XCTAssertEqual(TruthStanding(wire: "clouded"), .clouded)
        XCTAssertNil(TruthStanding(wire: "mystery"))
    }

    // MARK: The ledger page

    func testTheOverviewBucketsAndJoinsStanding() throws {
        let overview = try overview()
        XCTAssertEqual(overview.ledger?.slug, "team")
        XCTAssertEqual(overview.summary.cited, 2)
        XCTAssertEqual(overview.summary.openProposals, 3)
        XCTAssertTrue(overview.review?.due ?? false)
        XCTAssertEqual(overview.review?.cadence, .weekly)

        let sections = overview.sections
        XCTAssertEqual(sections.standing.count, 2)
        XCTAssertEqual(sections.unverified.count, 1)
        XCTAssertEqual(sections.history.count, 1)

        let appealed = sections.standing[0]
        XCTAssertEqual(appealed.status, "contested", "the folded status, not the line as written")
        XCTAssertEqual(appealed.contestedBy.map(\.id), ["01M1E6JK82QWPK6VS437JKMJPZ"])
        XCTAssertEqual(appealed.answerableBy, "johnnyclem")
        XCTAssertNil(appealed.reasonSentence)

        let clouded = sections.standing[1]
        XCTAssertEqual(clouded.standing, .clouded)
        XCTAssertNotNil(clouded.reasonSentence)

        let flagged = sections.unverified[0]
        XCTAssertTrue(flagged.isStale)
        XCTAssertTrue(flagged.corroborated)
        XCTAssertEqual(flagged.status, "open")

        XCTAssertEqual(sections.history[0].status, "refuted")
        XCTAssertFalse(sections.isEmpty)
    }

    func testTheOverviewSurvivesTheCache() throws {
        let overview = try overview()
        let back = try HVCoding.decoder(.verbatim).decode(TruthOverview.self, from: try HVCoding.encoder(.verbatim).encode(overview))
        XCTAssertEqual(back, overview)
        XCTAssertEqual(back.sections.standing.count, 2)
    }

    func testAnEmptyLedgerIsEmpty() throws {
        let empty = try HVCoding.decoder().decode(TruthOverview.self, from: Data(#"{"ledger":{"id":"a","slug":"default","name":"Default","kind":"mirror"},"summary":{"cited":0,"contested":0,"flags":0,"displaced":0,"total":0,"open_proposals":0},"citable":[],"flags":[],"displaced":[],"entries":[]}"#.utf8))
        XCTAssertTrue(empty.sections.isEmpty)
        XCTAssertTrue(empty.chatTruth)
    }

    func testTheDocketHeadlineSentence() {
        XCTAssertEqual(TruthDocketHeadline().sentence, "Nothing waits on you.")
        XCTAssertEqual(
            TruthDocketHeadline(size: 3, nominated: 1, stale: 1, oldestAgeMs: 172_800_000).sentence,
            "3 items waiting on you, 1 nominated by agents, 1 stale; the oldest has waited 2 days."
        )
        XCTAssertEqual(TruthDocketHeadline(size: 1, oldestAgeMs: 600_000).sentence, "1 item waiting on you; the oldest has waited under an hour.")
        XCTAssertEqual(TruthTime.wait(milliseconds: 5 * 3_600_000), "5 hours")
        XCTAssertEqual(TruthTime.age(milliseconds: 30_000), "just now")
        XCTAssertEqual(TruthTime.age(milliseconds: 12 * 60_000), "12m")
        XCTAssertEqual(TruthTime.age(milliseconds: 5 * 3_600_000), "5h")
        XCTAssertEqual(TruthTime.age(milliseconds: 3 * 86_400_000), "3d")
    }

    // MARK: The trace

    static let derivationJSON = """
    {"ledger":{"id":"l1","slug":"team","name":"Team","kind":"hosted"},"id":"01M1E6JK8SQAJ8K0JBRHTD10YG",
     "derivation":{"id":"01M1E6JK8SQAJ8K0JBRHTD10YG","type":"TB","status":"active","standing":"unsupported",
       "reasons":[{"premise":"01M1E6JK8QHST8RZF45PNRBMXG","reason":"premise-struck"}],
       "text":"Retries are capped at 5; the old cap of 3 is dead.","signedBy":"johnnyclem","answerableBy":"johnnyclem",
       "premises":[
         {"id":"01M1E6JK8QHST8RZF45PNRBMXG","type":"TB","status":"struck","standing":"sound","reasons":[],"text":"The retry budget is 100.","signedBy":"johnnyclem","answerableBy":"johnnyclem","premises":[],"kind":"derives","failing":"premise-struck"},
         {"id":"01M1E6JK8RY2RTGX9TRXJABTWR","type":"UV","status":"verified","standing":"sound","reasons":[],"text":"Each retry costs 20.","premises":[],"kind":"derives"},
         {"id":"01GONE","type":"TB","status":null,"standing":null,"text":"","premises":[],"missing":true,"kind":"wiki"}]},
     "dependents":[{"id":"01M1E6JK8T990YNBMTS1KP26ZW","type":"UV","status":"open","standing":"unsupported","reasons":[{"premise":"01M1E6JK8QHST8RZF45PNRBMXG","reason":"premise-struck","via":"01M1E6JK8SQAJ8K0JBRHTD10YG"}],"signedBy":null,"answerableBy":null,"text":"The per-tenant cap is 5 too."}]}
    """

    func testTheTraceHasOneRowPerNodeAndMarksTheFailingPremise() throws {
        let trace = try HVCoding.decoder().decode(TruthDerivation.self, from: Data(Self.derivationJSON.utf8))
        let rows = trace.rows
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.map(\.depth), [0, 1, 1, 1])
        XCTAssertEqual(rows[0].node.standing, .unsupported)
        XCTAssertEqual(rows[1].node.failing, "premise-struck")
        XCTAssertEqual(rows[1].node.failingPhrase, "was struck")
        XCTAssertEqual(rows[1].node.statusLabel, "Struck")
        XCTAssertNil(rows[2].node.failing)
        XCTAssertTrue(rows[3].node.missing)
        XCTAssertEqual(rows[3].node.statusLabel, "not held here")
        XCTAssertEqual(rows[3].node.kind, "wiki")
        XCTAssertEqual(Set(rows.map(\.path)).count, 4, "every row has its own path")
        XCTAssertEqual(trace.dependents.map(\.id), ["01M1E6JK8T990YNBMTS1KP26ZW"])
        XCTAssertEqual(trace.dependents[0].reasons.first?.via, "01M1E6JK8SQAJ8K0JBRHTD10YG")
        XCTAssertTrue(TruthTrace.hasPremises(trace.root))
    }

    func testAPrecedentIsNamedAsOne() throws {
        let node = try HVCoding.decoder().decode(TruthTraceNode.self, from: Data(#"{"id":"R1","type":"RULING","status":"superseded","standing":null,"text":"Use exponential backoff.","answerableBy":"kim","premises":[]}"#.utf8))
        XCTAssertTrue(node.isPrecedent)
        XCTAssertEqual(node.typeTag, "precedent")
        XCTAssertEqual(node.statusLabel, "superseded")
    }

    func testTheSameEntryTwiceIsTwoRows() {
        let leaf = TruthTraceNode(id: "L")
        let root = TruthTraceNode(id: "R", premises: [TruthTraceNode(id: "A", premises: [leaf]), TruthTraceNode(id: "B", premises: [leaf])])
        let rows = TruthTrace.rows(root)
        XCTAssertEqual(rows.map(\.node.id), ["R", "A", "L", "B", "L"])
        XCTAssertEqual(Set(rows.map(\.id)).count, 5)
    }

    // MARK: Ripple and worklist

    func testTheRipple() throws {
        let json = """
        {"ledger":{"id":"l1","slug":"team","name":"Team","kind":"hosted"},"id":"E1",
         "roots":[{"id":"E1","type":"TB","status":"active","standing":"sound","reasons":[],"text":"Root","signedBy":"kim","answerableBy":"kim"}],
         "missing":[],
         "entries":[{"id":"E2","type":"UV","status":"open","standing":"clouded","reasons":[{"premise":"E1","reason":"premise-open"}],"text":"Derived","signedBy":null,"answerableBy":null,"depth":1,"via":"E1"}],
         "context":[{"kind":"memory","id":"mem1","item":{"kind":"memory","id":"mem1","title":"Case summary"},"relation":"rests_on","entry_id":"E2","affected":true,"stale":true,"stale_kind":"undermined","note":null},
                    {"kind":"artifact","id":"art1","item":null,"relation":"source","entry_id":"E1","affected":false,"stale":false,"stale_kind":null,"note":"deposition"}],
         "counts":{"entries":1,"context":2,"affected":1,"stale":1}}
        """
        let ripple = try HVCoding.decoder().decode(TruthRipple.self, from: Data(json.utf8))
        XCTAssertEqual(ripple.entries.count, 1)
        XCTAssertEqual(ripple.entries[0].depth, 1)
        XCTAssertEqual(ripple.entries[0].via, "E1")
        XCTAssertEqual(ripple.context.count, 2)
        XCTAssertEqual(ripple.context[0].title, "Case summary")
        XCTAssertEqual(ripple.context[0].relationPhrase, "rests on it")
        XCTAssertTrue(ripple.context[0].stale)
        XCTAssertEqual(ripple.context[1].title, "A artifact that is no longer here")
        XCTAssertEqual(ripple.context[1].relationPhrase, "is where it came from")
        XCTAssertEqual(ripple.affectedCount, 1)
        XCTAssertEqual(ripple.sentence, "1 other entry and 2 memories and pages rest on it, 1 of them would feel a change.")
        XCTAssertFalse(ripple.isEmpty)
    }

    func testStaleWorklist() throws {
        let json = """
        {"ledger":null,"items":[{"item":{"kind":"memory","id":"mem1","title":"Case summary"},"key":"memory:mem1","ledger":{"id":"l1","slug":"team","name":"Team","kind":"hosted"},
          "edges":[{"link":{"entry_id":"E1","relation":"rests_on","seen_status":"active","seen_standing":"sound","stale_since":"2026-10-24T10:00:00.000Z","stale_kind":"overturned","stale_by":null,"stale_summary":"TB E1 was overridden by E9.","note":null},
                    "ledger":null,"item":null,
                    "entry":{"id":"E1","type":"TB","status":"overridden","standing":"sound","reasons":[],"text":"Old","signedBy":"kim","answerableBy":"kim"},
                    "successor":{"id":"E9","type":"TB","status":"active","standing":"sound","reasons":[],"text":"New","signedBy":"kim","answerableBy":"kim"}}]}],
         "total":1,"as_of":"2026-10-25T12:00:00.000Z"}
        """
        let worklist = try HVCoding.decoder().decode(TruthStaleWorklist.self, from: Data(json.utf8))
        XCTAssertEqual(worklist.total, 1)
        let item = try XCTUnwrap(worklist.items.first)
        XCTAssertEqual(item.item?.title, "Case summary")
        XCTAssertEqual(item.ledger?.slug, "team")
        let edge = try XCTUnwrap(item.edges.first)
        XCTAssertEqual(edge.entryId, "E1")
        XCTAssertEqual(edge.entry?.status, "overridden")
        XCTAssertEqual(edge.successor?.id, "E9")
        XCTAssertEqual(edge.whatMoved, "TB E1 was overridden by E9.")
        XCTAssertEqual(edge.seenStatus, "active")
        XCTAssertNotNil(edge.staleSince)
    }

    func testResolvingAStaleItem() throws {
        let item = try HVCoding.decoder().decode(TruthContextItem.self, from: Data(#"{"kind":"memory","id":"mem1","title":"T"}"#.utf8))
        let body = TruthStaleResolution.relink.body(item: item, entries: ["E1"], to: ["E9"], ledger: "team")
        XCTAssertEqual(body["action"], "relink")
        XCTAssertEqual(body["kind"], "memory")
        XCTAssertEqual(body["id"], "mem1")
        XCTAssertEqual(body["entries"], ["E1"])
        XCTAssertEqual(body["to"], ["E9"])
        XCTAssertEqual(body["ledger"], "team")
        XCTAssertNil(TruthStaleResolution.reaffirm.body(item: item, entries: ["E1"], ledger: nil)["to"])
    }

    func testEvents() throws {
        let json = """
        {"events":[{"id":"ev1","entry_id":"E1","entry_type":"TB","kind":"undermined","prior_status":"active","new_status":"active","by_entry_id":"E0","by_author":"kim","authors":["kim"],"summary":"TB E1 is unsupported: a premise was struck.","created_at":"2026-10-24T10:00:00.000000+00:00","user_id":"u","source":"hosted","line":{"id":"E1"}},
                    {"id":"ev2","entry_id":"E3","entry_type":"UV","kind":"verified","prior_status":"open","new_status":"verified","by_entry_id":null,"by_author":null,"authors":[],"summary":"UV E3 was verified.","created_at":"2026-10-24T09:00:00.000000+00:00"}],
         "scope":"session","kinds":["challenged"],"ledger":"default"}
        """
        let list = try HVCoding.decoder().decode(TruthEventList.self, from: Data(json.utf8))
        XCTAssertEqual(list.events.count, 2)
        XCTAssertEqual(list.events[0].kind, .undermined)
        XCTAssertTrue(list.events[0].kind.isSetback)
        XCTAssertEqual(list.events[0].kind.title, "Undermined")
        XCTAssertEqual(list.events[0].byEntryId, "E0")
        XCTAssertFalse(list.events[1].kind.isSetback)
        XCTAssertNotNil(list.events[1].createdAt)
        let back = try HVCoding.decoder(.verbatim).decode(TruthEventList.self, from: try HVCoding.encoder(.verbatim).encode(list))
        XCTAssertEqual(back, list)
    }

    // MARK: Drafts, inbox, signers

    func testProposalDrafts() throws {
        let json = """
        {"ledger":{"id":"l1","slug":"default","name":"Default","kind":"mirror"},"proposals":[
         {"id":"p1","ledger_id":"l1","kind":"tombstone","target_ref":"shorthand:tombstone:1","origin":"chat-compaction","conversation_id":null,"status":"open","created_at":"2026-10-20T10:00:00.000000+00:00","exported_at":null,"decided_at":null,
          "line":{"schemaVersion":2,"id":"p1","type":"PROPOSAL","ts":"2026-10-20T10:00:00.000Z","author":"detector:hypervault","kind":"tb","draft":{"claim":"The old cap no longer holds.","evidence":[{"kind":"commit","ref":"abc123"},"a note"]},"targetRef":"shorthand:tombstone:1","signal":{"source":"compaction-candidate","detail":"Said in chat"},"agentSessionId":null}},
         {"id":"p2","ledger_id":"l1","kind":"uv","target_ref":"x","origin":"api","status":"filed","created_at":"2026-10-20T10:00:00.000000+00:00",
          "line":{"kind":"uv","draft":{"assertion":"It is idempotent.","basis":"The docs say so","verifyBy":{"kind":"inspect","value":"src/retry.ts"}},"signal":{"source":"compaction-candidate"}}}]}
        """
        let list = try HVCoding.decoder().decode(TruthProposalList.self, from: Data(json.utf8))
        XCTAssertEqual(list.proposals.count, 2)
        let tb = list.proposals[0]
        XCTAssertTrue(tb.isTombstone)
        XCTAssertEqual(tb.headline, "The old cap no longer holds.")
        XCTAssertEqual(tb.evidenceLines, ["commit abc123", "a note"])
        XCTAssertEqual(tb.signalDetail, "Said in chat")
        let uv = list.proposals[1]
        XCTAssertEqual(uv.headline, "It is idempotent.")
        XCTAssertEqual(uv.basis, "The docs say so")
        XCTAssertEqual(uv.verifyBy, "inspect: src/retry.ts")
        XCTAssertEqual(uv.status, .filed)
        XCTAssertEqual(TruthProposalStatus.open.moves, [.filed, .dismissed])
        XCTAssertEqual(TruthProposalStatus.dismissed.moves, [.open])
    }

    func testTheSidecarInbox() throws {
        let json = """
        {"configured":true,"notary":false,
         "proposals":[{"id":"sp1","type":"PROPOSAL","createdAt":"2026-10-20T10:00:00.000Z","author":"detector:x","body":{"kind":"tombstone","draft":{"claim":"X is dead."},"signal":{"source":"s","detail":"seen twice"},"targetRef":"t","requiresNotary":true,"status":"open"}}],
         "objections":null}
        """
        let inbox = try HVCoding.decoder().decode(TruthInbox.self, from: Data(json.utf8))
        XCTAssertTrue(inbox.configured)
        XCTAssertFalse(inbox.notary)
        XCTAssertEqual(inbox.proposals?.first?.headline, "X is dead.")
        XCTAssertEqual(inbox.proposals?.first?.requiresNotary, true)
        XCTAssertEqual(inbox.proposals?.first?.signalDetail, "seen twice")
        XCTAssertNil(inbox.objections)
    }

    func testSigners() throws {
        let json = #"{"signers":[{"id":"agent:Claude Code","role":"agent"},{"id":"johnnyclem","role":"human"}]}"#
        let signers = try HVCoding.decoder().decode(TruthSigners.self, from: Data(json.utf8))
        XCTAssertEqual(signers.handle, "johnnyclem")
        XCTAssertEqual(signers.agents.map(\.id), ["agent:Claude Code"])
        XCTAssertNil(TruthSigners().handle)
    }

    func testHandleChecks() {
        XCTAssertNotNil(TruthHandle.problem("   "))
        XCTAssertNotNil(TruthHandle.problem(String(repeating: "a", count: 65)))
        XCTAssertNil(TruthHandle.problem("johnny"))
    }

    func testHandleRequiredIsRecognised() async {
        let transport = MockTransport(routes: [.json(.post, "/api/truth/entries", #"{"error":"Choose your truth handle first (PUT /api/truth/handle) — it is the name your truth is signed with.","handle_required":true}"#, status: 409)])
        do {
            _ = try await client(transport).send(.assertTruth(TruthAssertDraft(type: .uv), ledger: "team"))
            XCTFail("expected a refusal")
        } catch let error as HVError {
            XCTAssertTrue(error.isTruthHandleRequired)
            XCTAssertEqual(error.status, 409)
        } catch {
            XCTFail("\(error)")
        }
        let other = HVError.api(APIFailure(status: 409, message: "A mirror ledger", body: ["error": "A mirror ledger"]))
        XCTAssertFalse(other.isTruthHandleRequired)
    }

    // MARK: Importing

    func testImportPreview() {
        let text = [TruthTests.tb1, TruthTests.uv1, "", TruthTests.uv2, #"{"type":"TRANSITION","target":"x","status":"verified"}"#].joined(separator: "\n")
        let preview = TruthImportPreview.parse(text)
        XCTAssertEqual(preview.lineCount, 4)
        XCTAssertEqual(preview.tbCount, 1)
        XCTAssertEqual(preview.uvCount, 2)
        XCTAssertEqual(preview.otherCount, 1)
        XCTAssertNil(preview.firstProblem)
        XCTAssertTrue(preview.canSend)
        XCTAssertEqual(preview.summary, "4 lines: 1 TB, 2 UV, 1 other.")

        let bad = TruthImportPreview.parse(TruthTests.tb1 + "\nnot json\n[1,2]")
        XCTAssertEqual(bad.firstProblem?.line, 2)
        XCTAssertFalse(bad.canSend)
        XCTAssertEqual(TruthImportPreview.parse("  \n").summary, "Nothing to import.")
        XCTAssertFalse(TruthImportPreview.parse("").canSend)
    }

    func testImportSendsRawLinesAndReadsTheResult() async throws {
        let transport = MockTransport(routes: [.json(.post, "/api/truth/import", #"{"ledger":{"id":"l","slug":"default","name":"Default","kind":"mirror"},"committed":true,"lines":3,"upserted":2,"errors":[],"ids":["a","b"],"events":1}"#)])
        let result = try await client(transport).send(.importTruth(jsonl: Self.tb1 + "\n" + Self.uv1, ledger: "default"))
        XCTAssertTrue(result.committed)
        XCTAssertEqual(result.upserted, 2)
        XCTAssertEqual(result.sentence, "Imported 2 entries from 3 new lines.")
        let request = await transport.requests[0]
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-ndjson")
        XCTAssertEqual(request.url?.query, "ledger=default")
        XCTAssertEqual(String(decoding: request.httpBody ?? Data(), as: UTF8.self).split(separator: "\n").count, 2)
    }

    func testARefusedFileNamesEveryBadLine() async {
        let body = #"{"error":"The stream was refused; nothing was written.","committed":false,"upserted":0,"lines":0,"errors":[{"line":2,"error":"a version 1 line"},{"line":5,"error":"hash does not match"}]}"#
        let transport = MockTransport(routes: [.json(.post, "/api/truth/import", body, status: 422)])
        do {
            _ = try await client(transport).send(.importTruth(jsonl: "x", ledger: nil))
            XCTFail("expected a refusal")
        } catch {
            let lines = TruthImportFailure.lineErrors(in: error)
            XCTAssertEqual(lines.map(\.line), [2, 5])
            XCTAssertEqual(lines[1].error, "hash does not match")
            XCTAssertEqual((error as? HVError)?.userMessage, "The stream was refused; nothing was written.")
        }
    }

    func testPageImport() async throws {
        let transport = MockTransport(routes: [.json(.post, "/api/truth/import/page", #"{"ledger":{"id":"l","slug":"team","name":"Team","kind":"hosted"},"page":{"slug":"ledger-page","version_id":"v"},"filed":3,"skipped":1,"entries":0,"errors":[],"ids":["a"]}"#, status: 201)])
        let result = try await client(transport).send(.importTruthPage(slug: "ledger-page", ledger: "team"))
        XCTAssertEqual(result.filed, 3)
        XCTAssertEqual(result.sentence, "3 lines waiting on the docket. Nothing is truth until you approve it there.")
        let requests = await transport.requests
        let body = try HVCoding.decoder(.verbatim).decode(JSONValue.self, from: try XCTUnwrap(requests[0].httpBody))
        XCTAssertEqual(body["slug"], "ledger-page")
        XCTAssertNil(body["jsonl"])
    }

    // MARK: Endpoints

    func testEndpointsCarryTheLedger() async throws {
        let transport = MockTransport(routes: [
            .json(.get, "/api/truth", Self.overviewJSON),
            .json(.get, "/api/truth/E1/derivation", Self.derivationJSON),
            MockRoute(.get, "/api/truth/export") { _ in HTTPResponse(status: 200, headers: ["x-truth-last-seq": "9"], data: Data("{}\n".utf8)) },
            .json(.get, "/api/truth/proposals", #"{"proposals":[]}"#),
            .json(.patch, "/api/truth/proposals/p1", #"{"ok":true}"#),
        ])
        let api = client(transport)
        _ = try await api.send(.truth(ledger: "team"))
        _ = try await api.send(.truthDerivation(id: "E1", ledger: "team"))
        let exported = try await api.sendRaw(.exportTruth(ledger: "team", sinceSeq: 4))
        XCTAssertEqual(exported.header("X-Truth-Last-Seq"), "9")
        _ = try await api.send(.truthProposals(status: .exported, ledger: "team"))
        _ = try await api.send(.setTruthProposal(id: "p1", status: .dismissed, ledger: "team"))
        let sent = await transport.requests
        XCTAssertEqual(sent[0].url?.query, "ledger=team")
        XCTAssertEqual(sent[1].url?.query, "ledger=team")
        let exportQuery = try XCTUnwrap(sent[2].url?.query)
        XCTAssertTrue(exportQuery.contains("ledger=team") && exportQuery.contains("sinceSeq=4"))
        XCTAssertTrue(try XCTUnwrap(sent[3].url?.query).contains("status=exported"))
        XCTAssertEqual(sent[4].httpMethod, "PATCH")
        let patch = try HVCoding.decoder(.verbatim).decode(JSONValue.self, from: try XCTUnwrap(sent[4].httpBody))
        XCTAssertEqual(patch["status"], "dismissed")
    }

    func testFileNames() {
        XCTAssertEqual(TruthFiles.exportName(slug: "team"), "truth-team.jsonl")
        XCTAssertEqual(TruthFiles.proposalsName(slug: "team"), "proposals-team.jsonl")
    }
}
