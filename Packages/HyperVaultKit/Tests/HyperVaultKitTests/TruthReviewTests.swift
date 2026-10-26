import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

/// The docket is `buildDocket` in lib/truth/docket.ts; the decisions are POST /api/truth/review/[id].
final class TruthReviewTests: XCTestCase {
    let base = URL(string: "https://hv.test")!

    func client(_ transport: MockTransport) -> HVClient {
        HVClient(baseURL: base, transport: transport, tokens: StaticTokenProvider(), retry: .none, sleep: { _ in })
    }

    static let hosted = TruthLedger(id: "l1", slug: "team", name: "Team", kind: .hosted)
    static let mirror = TruthLedger(id: "l2", slug: "default", name: "Default", kind: .mirror)

    static let docketJSON = """
    {"ledger":{"id":"l1","slug":"team","name":"Team","kind":"hosted"},
     "docket":{"items":[
      {"kind":"uv","id":"UV1","subject":"UV1","text":"Retries are idempotent across regions.","author":"agent:Claude Code","agentSessionId":"sess-1",
       "createdAt":"2026-10-23T12:00:00.000Z","ageMs":172800000,"nominated":true,"suspect":false,"stale":true,
       "freshness":{"state":"stale","horizonSeconds":1814400,"since":"2026-09-01T10:00:00.000Z","anchor":{"kind":"asserted"},"at":"2026-10-25T12:00:00.000Z","expiresAt":"2026-09-22T10:00:00.000Z"},
       "deferredUntil":null,"status":"open","standing":"clouded","evidence":[],"basis":"the design doc says so",
       "verifyBy":{"kind":"inspect","value":"src/retry.ts","detail":"a region-scoped idempotency key"},"contests":null,
       "line":{"id":"UV1","type":"UV"},
       "approvals":{"approvers":1,"human":false,"agentSessions":1,"nominated":true,"missing":["a human approval"],
         "list":[{"by":"agent:Claude Code","role":"agent","agent_session_id":"sess-1","evidence":[{"kind":"commit","ref":"9f2c1ab","detail":"adds the key"}],"note":"checked","created_at":"2026-10-24T12:00:00.000Z"}]},
       "derivation":{"id":"UV1","type":"UV","status":"open","standing":"clouded","reasons":[{"premise":"P1","reason":"premise-open"}],"text":"Retries are idempotent across regions.","premises":[{"id":"P1","type":"UV","status":"open","standing":"sound","reasons":[],"text":"Regions share a store.","premises":[],"kind":"derives","failing":"premise-open"}]}},
      {"kind":"appeal","id":"TB1","subject":"TB1","text":"LOG_BUDGET is 100.","author":"johnnyclem","agentSessionId":null,"createdAt":"2026-10-25T08:00:00.000Z","ageMs":14400000,
       "nominated":false,"suspect":false,"stale":false,"deferredUntil":null,"status":"contested","standing":"sound",
       "evidence":[{"kind":"commit","ref":"9f2c1ab"}],"line":{"id":"TB1","type":"TB"},
       "appeals":{"tombstone":{"id":"TB1"},"status":"contested","contestedBy":[{"id":"UV9","assertion":"It went back to 30.","author":"alex"},{"id":"UV10","assertion":"It is 60 now.","author":"sam"}]},
       "derivation":{"id":"TB1","type":"TB","status":"contested","standing":"sound","reasons":[],"text":"LOG_BUDGET is 100.","premises":[]}},
      {"kind":"derivation-review","id":"11111111-1111-4111-8111-111111111111","subject":"UV1","text":"The cap is region-wide.","author":"detector:derivation","agentSessionId":null,
       "createdAt":"2026-10-25T09:00:00.000Z","ageMs":10800000,"nominated":false,"suspect":true,"stale":false,"deferredUntil":null,"status":"open","standing":null,"evidence":[],
       "basis":"UV1 was refuted","contests":"UV1","line":{"kind":"uv"},"review":{"contests":"UV1","detail":"A premise was refuted.","proposalId":"11111111-1111-4111-8111-111111111111","rank":2},"derivation":null},
      {"kind":"migration","id":"22222222-2222-4222-8222-222222222222","subject":"page:ledger-page","text":"Retries stop at 5, not 3.","author":"detector:hypervault-migration","agentSessionId":null,
       "createdAt":"2026-10-25T10:00:00.000Z","ageMs":7200000,"nominated":false,"suspect":false,"stale":false,"deferredUntil":"2026-11-02T10:00:00.000Z","status":"open","standing":null,"evidence":[],
       "line":{"kind":"uv"},"migration":{"page":{"slug":"ledger-page","line_id":"L7","owner":"gpt-4"},"literal":{"dead":"3","current":"5"},"proposalId":"22222222-2222-4222-8222-222222222222"},"derivation":null}],
      "size":3,"nominated":1,"stale":1,"asOf":"2026-10-25T12:00:00.000Z","oldest":{"id":"UV1","kind":"uv","createdAt":"2026-10-23T12:00:00.000Z","ageMs":172800000}},
     "review":{"cadence":"daily","last_at":null,"due":true,"next_at":"2026-10-25T12:00:00.000Z"}}
    """

    func payload() throws -> TruthReviewPayload {
        try HVCoding.decoder().decode(TruthReviewPayload.self, from: Data(Self.docketJSON.utf8))
    }

    // MARK: Decoding

    func testTheDocketDecodesEveryKindOfCard() throws {
        let payload = try payload()
        XCTAssertEqual(payload.ledger?.slug, "team")
        XCTAssertEqual(payload.docket.size, 3)
        XCTAssertEqual(payload.docket.items.count, 4)
        XCTAssertTrue(payload.review.due)
        XCTAssertEqual(payload.review.cadence, .daily)

        let uv = payload.docket.items[0]
        XCTAssertEqual(uv.kind, .uv)
        XCTAssertTrue(uv.nominated)
        XCTAssertTrue(uv.stale)
        XCTAssertEqual(uv.freshness?.isStale, true)
        XCTAssertEqual(uv.standing, .clouded)
        XCTAssertEqual(uv.agentSessionId, "sess-1")
        XCTAssertEqual(uv.verifyBy?.value, "src/retry.ts")
        XCTAssertEqual(uv.approvals?.missing, ["a human approval"])
        XCTAssertEqual(uv.approvals?.list.first?.agentSessionId, "sess-1")
        XCTAssertEqual(uv.approvals?.list.first?.evidence.first?.ref, "9f2c1ab")
        XCTAssertEqual(uv.approvals?.recordLine, "1 approver (no person yet, 1 agent session)")
        XCTAssertEqual(uv.derivation?.premises.first?.failing, "premise-open")
        XCTAssertEqual(uv.ageText, "2d")

        let appeal = payload.docket.items[1]
        XCTAssertEqual(appeal.kind, .appeal)
        XCTAssertEqual(appeal.contestedBy.map(\.id), ["UV9", "UV10"])
        XCTAssertEqual(appeal.evidence.count, 1)

        let review = payload.docket.items[2]
        XCTAssertEqual(review.kind, .derivationReview)
        XCTAssertEqual(review.review?.rank, 2)
        XCTAssertTrue(review.suspect)
        XCTAssertNil(review.derivation)

        let migration = payload.docket.items[3]
        XCTAssertEqual(migration.kind, .migration)
        XCTAssertEqual(migration.migration?.pageSlug, "ledger-page")
        XCTAssertEqual(migration.migration?.lineID, "L7")
        XCTAssertEqual(migration.migration?.typedBy, "gpt-4")
        XCTAssertEqual(migration.migration?.literal?.dead, "3")
        XCTAssertTrue(migration.isDeferred(now: ISO.date("2026-10-26T00:00:00Z")))
        XCTAssertFalse(migration.isDeferred(now: ISO.date("2026-11-05T00:00:00Z")))
    }

    func testABrokenCardDoesNotTakeTheDocketWithIt() throws {
        let json = #"{"docket":{"items":[{"kind":"uv","id":"A","text":"ok"},{"kind":"uv"},"junk"],"size":1},"review":{}}"#
        let payload = try HVCoding.decoder().decode(TruthReviewPayload.self, from: Data(json.utf8))
        XCTAssertEqual(payload.docket.items.map(\.id), ["A"])
    }

    // MARK: What each action does and whether it is on offer

    func items() throws -> [TruthDocketItem] { try payload().docket.items }

    func testOnAUVEveryActionIsOnOfferAndSaysWhatItDoes() throws {
        let uv = try items()[0]
        for action in TruthAction.allCases {
            let state = TruthDocketRules.state(of: action, for: uv, in: Self.hosted)
            XCTAssertTrue(state.isAvailable, "\(action)")
            XCTAssertFalse(state.explanation.isEmpty)
            XCTAssertNil(state.unavailableReason)
        }
        XCTAssertEqual(TruthDocketRules.state(of: .approve, for: uv, in: Self.hosted).label, "Approve")
        // the person has not approved yet; the agent has, so the UV is promoted on their approval
        XCTAssertTrue(TruthDocketRules.explanation(of: .approve, for: uv).hasPrefix("Promotes the UV"))
    }

    func testApprovalSaysWhatPromotionStillNeeds() throws {
        var json = Self.docketJSON
        json = json.replacingOccurrences(of: #""missing":["a human approval"]"#, with: #""missing":["a human approval","a second approver","evidence"]"#)
        let uv = try HVCoding.decoder().decode(TruthReviewPayload.self, from: Data(json.utf8)).docket.items[0]
        XCTAssertEqual(
            TruthDocketRules.explanation(of: .approve, for: uv),
            "Your approval goes on the record. The UV is promoted once a second approver and evidence arrive: ask an agent to verify it with settling evidence."
        )
    }

    func testAnAppealCannotBeRefutedByTheOneWhoSignedTheTB() throws {
        let appeal = try items()[1]
        let refute = TruthDocketRules.state(of: .refute, for: appeal, in: Self.hosted)
        XCTAssertFalse(refute.isAvailable)
        XCTAssertTrue(refute.unavailableReason?.contains("signed this TB") ?? false)
        XCTAssertEqual(TruthDocketRules.state(of: .approve, for: appeal, in: Self.hosted).label, "Approve appeal")
        XCTAssertTrue(TruthDocketRules.state(of: .strike, for: appeal, in: Self.hosted).isAvailable)
        XCTAssertTrue(TruthDocketRules.state(of: .deferral, for: appeal, in: Self.hosted).isAvailable)
    }

    func testAnAppealWithNoContestingUVOffersNothingToDecide() throws {
        var json = Self.docketJSON
        json = json.replacingOccurrences(of: #""contestedBy":[{"id":"UV9","assertion":"It went back to 30.","author":"alex"},{"id":"UV10","assertion":"It is 60 now.","author":"sam"}]"#, with: #""contestedBy":[]"#)
        let appeal = try HVCoding.decoder().decode(TruthReviewPayload.self, from: Data(json.utf8)).docket.items[1]
        XCTAssertFalse(TruthDocketRules.state(of: .approve, for: appeal, in: Self.hosted).isAvailable)
        XCTAssertFalse(TruthDocketRules.state(of: .strike, for: appeal, in: Self.hosted).isAvailable)
        XCTAssertTrue(TruthDocketRules.state(of: .deferral, for: appeal, in: Self.hosted).isAvailable)
    }

    func testProposalsAreApprovedOrDismissedNeverStruck() throws {
        let review = try items()[2]
        let migration = try items()[3]
        for card in [review, migration] {
            XCTAssertEqual(TruthDocketRules.state(of: .refute, for: card, in: Self.hosted).label, "Dismiss")
            XCTAssertTrue(TruthDocketRules.state(of: .refute, for: card, in: Self.hosted).isAvailable)
            XCTAssertFalse(TruthDocketRules.state(of: .strike, for: card, in: Self.hosted).isAvailable)
            XCTAssertFalse(TruthDocketRules.state(of: .ask, for: card, in: Self.hosted).isAvailable)
            XCTAssertTrue(TruthDocketRules.state(of: .approve, for: card, in: Self.hosted).isAvailable)
        }
        XCTAssertTrue(TruthDocketRules.explanation(of: .approve, for: migration).contains("page line"))
        XCTAssertTrue(TruthDocketRules.explanation(of: .refute, for: migration).contains("importing the page again"))
        XCTAssertTrue(TruthDocketRules.explanation(of: .approve, for: review).contains("detector"))
    }

    func testAMirrorLedgerDecidesNothing() throws {
        let uv = try items()[0]
        for action in TruthAction.allCases {
            let state = TruthDocketRules.state(of: action, for: uv, in: Self.mirror)
            XCTAssertFalse(state.isAvailable)
            XCTAssertEqual(state.unavailableReason, TruthDocketRules.mirrorReason)
        }
    }

    // MARK: What a decision needs and carries

    func testDecisionsNeedWhatTheServerNeeds() throws {
        let all = try items()
        var draft = TruthDecisionDraft()
        XCTAssertEqual(TruthDocketRules.problem(with: .refute, for: all[0], draft: draft), "Give at least one piece of evidence.")
        XCTAssertNil(TruthDocketRules.problem(with: .refute, for: all[2], draft: draft), "dismissing a review needs none")
        draft.evidence[0].ref = "  src/retry.ts:40 "
        XCTAssertNil(TruthDocketRules.problem(with: .refute, for: all[0], draft: draft))
        XCTAssertNotNil(TruthDocketRules.problem(with: .strike, for: all[0], draft: draft))
        draft.opinion = "  Nonsense.  "
        XCTAssertNil(TruthDocketRules.problem(with: .strike, for: all[0], draft: draft))
        XCTAssertNotNil(TruthDocketRules.problem(with: .ask, for: all[0], draft: draft))
        draft.roomID = "room-1"
        XCTAssertNil(TruthDocketRules.problem(with: .ask, for: all[0], draft: draft))
        XCTAssertNil(TruthDocketRules.problem(with: .approve, for: all[0], draft: TruthDecisionDraft()))
    }

    func testOnAnAppealTheDecisionGoesToTheContestingUV() throws {
        let appeal = try items()[1]
        var draft = TruthDecisionDraft()
        XCTAssertEqual(TruthDocketRules.target(of: .approve, for: appeal, draft: draft), "UV9", "the first, when none was chosen")
        draft.appealTarget = "UV10"
        XCTAssertEqual(TruthDocketRules.target(of: .approve, for: appeal, draft: draft), "UV10")
        XCTAssertEqual(TruthDocketRules.target(of: .strike, for: appeal, draft: draft), "UV10")
        draft.appealTarget = "somebody-else"
        XCTAssertEqual(TruthDocketRules.target(of: .strike, for: appeal, draft: draft), "UV9")
        XCTAssertEqual(TruthDocketRules.target(of: .deferral, for: appeal, draft: draft), "TB1", "deferring is of the card itself")
        XCTAssertEqual(TruthDocketRules.target(of: .approve, for: try items()[0], draft: draft), "UV1")
    }

    func testBodies() throws {
        let all = try items()
        var draft = TruthDecisionDraft()
        draft.note = " checked it "
        draft.opinion = "No."
        draft.evidence = [TruthEvidenceDraft(kind: .test, ref: "retry.test.ts", detail: "passes"), TruthEvidenceDraft()]
        draft.until = ISO.date("2026-11-01T09:00:00Z")
        draft.roomID = "room-1"
        draft.question = "Can you check?"

        let approve = TruthDocketRules.body(of: .approve, for: all[0], ledger: "team", draft: draft)
        XCTAssertEqual(approve["action"], "approve")
        XCTAssertEqual(approve["ledger"], "team")
        XCTAssertEqual(approve["note"], "checked it")

        let proposal = TruthDocketRules.body(of: .approve, for: all[2], ledger: "team", draft: draft)
        XCTAssertNil(proposal["note"], "a proposal takes no note")

        let refute = TruthDocketRules.body(of: .refute, for: all[0], ledger: "team", draft: draft)
        XCTAssertEqual(refute["action"], "refute")
        XCTAssertEqual(refute["evidence"]?.array?.count, 1, "the empty row is left out")
        XCTAssertEqual(refute["evidence"]?[0]?["kind"], "test")
        XCTAssertEqual(refute["evidence"]?[0]?["ref"], "retry.test.ts")
        XCTAssertEqual(refute["evidence"]?[0]?["detail"], "passes")

        let dismiss = TruthDocketRules.body(of: .refute, for: all[2], ledger: "team", draft: draft)
        XCTAssertNil(dismiss["evidence"])

        let strike = TruthDocketRules.body(of: .strike, for: all[0], ledger: "team", draft: draft)
        XCTAssertEqual(strike["opinion"], "No.")

        let later = TruthDocketRules.body(of: .deferral, for: all[0], ledger: "team", draft: draft)
        XCTAssertEqual(later["action"], "defer")
        XCTAssertEqual(later["until"], "2026-11-01T09:00:00.000Z")
        XCTAssertNil(TruthDocketRules.body(of: .deferral, for: all[0], ledger: "team", draft: TruthDecisionDraft())["until"])

        let ask = TruthDocketRules.body(of: .ask, for: all[0], ledger: "team", draft: draft)
        XCTAssertEqual(ask["room_id"], "room-1")
        XCTAssertEqual(ask["question"], "Can you check?")
        XCTAssertNil(ask["action"])
    }

    func testUndoingADeferralDefersToAMomentAgo() {
        let now = ISO.date("2026-10-25T12:00:00Z")
        let body = TruthDocketRules.undoDeferralBody(ledger: "team", now: now)
        XCTAssertEqual(body["action"], "defer")
        XCTAssertEqual(body["until"], "2026-10-25T11:59:59.000Z")
    }

    // MARK: What a decision answers

    func testOutcomesReadLikeTheWebsToasts() throws {
        func outcome(_ json: String) throws -> TruthDecisionOutcome {
            try HVCoding.decoder().decode(TruthDecisionOutcome.self, from: Data(json.utf8))
        }
        let promoted = try outcome(#"{"id":"UV1","action":"approve","status":"promoted","tb":{"id":"TB2"},"approvals":[{"by":"johnny"},{"by":"agent:x"}]}"#)
        XCTAssertEqual(promoted.sentence, "Promoted: the TB is written, signed by you.")
        XCTAssertTrue(promoted.settled)

        let approved = try outcome(#"{"id":"UV1","action":"approve","status":"approved","approvals":{"approvers":1,"human":true,"agentSessions":0,"nominated":false,"missing":["a second approver","evidence"]}}"#)
        XCTAssertEqual(approved.sentence, "Your approval is on the record. Still needs a second approver, evidence.")
        XCTAssertFalse(approved.settled)

        XCTAssertEqual(try outcome(#"{"id":"UV1","action":"refute","status":"refuted","reviews":2}"#).sentence, "Refuted; 2 derivation reviews filed.")
        XCTAssertEqual(try outcome(#"{"id":"UV1","action":"strike","status":"struck"}"#).sentence, "Struck.")
        XCTAssertEqual(try outcome(#"{"id":"p","action":"approve","status":"filed"}"#).sentence, "Asserted the UV against the premise.")
        XCTAssertEqual(try outcome(#"{"id":"p","action":"refute","status":"dismissed"}"#).sentence, "Dismissed.")
        let deferred = try outcome(#"{"id":"UV1","action":"defer","deferred_until":"2026-11-01T00:00:00.000Z"}"#)
        XCTAssertEqual(deferred.sentence, "Deferred.")
        XCTAssertNotNil(deferred.deferredUntil)
    }

    func testAskingARoom() throws {
        let answer = try HVCoding.decoder().decode(TruthAskAnswer.self, from: Data(#"{"id":"UV1","room_id":"r","answer":[{"handle":"claude","content":"Checked: it holds.","status":"done","created_at":"2026-10-25T12:00:00.000Z"}],"pending":0,"record":{}}"#.utf8))
        XCTAssertEqual(answer.replies?.count, 1)
        XCTAssertEqual(answer.replies?.first?.handle, "claude")
        XCTAssertFalse(answer.pending)
        let noRoom = try HVCoding.decoder().decode(TruthAskAnswer.self, from: Data(#"{"id":"UV1","answer":null,"record":{},"rooms":[{"id":"r1","title":"Ops"},{"id":"r2","title":"Legal"}]}"#.utf8))
        XCTAssertNil(noRoom.replies)
        XCTAssertEqual(noRoom.rooms.map(\.title), ["Ops", "Legal"])
    }

    func testRoomsList() throws {
        let rooms = try HVCoding.decoder().decode(TruthRoomList.self, from: Data(#"{"rooms":[{"id":"r1","title":"Ops","pending":0,"members":[]}]}"#.utf8))
        XCTAssertEqual(rooms.rooms, [TruthRoomChoice(id: "r1", title: "Ops")])
    }

    // MARK: The deck

    func testTheDeckKeepsTrackOfWhatYouHaveDealtWith() throws {
        let now = ISO.date("2026-10-26T00:00:00Z")
        var deck = TruthDeck(items: try items(), now: now)
        // the page-import card is deferred to 2 November, so it is not in this session
        XCTAssertEqual(deck.remaining.map(\.id), ["UV1", "TB1", "11111111-1111-4111-8111-111111111111"])
        XCTAssertEqual(deck.current?.id, "UV1")
        XCTAssertEqual(deck.next?.id, "TB1")
        XCTAssertEqual(deck.position, 1)
        XCTAssertEqual(deck.total, 3)
        deck.markHandled("UV1")
        XCTAssertEqual(deck.current?.id, "TB1")
        XCTAssertEqual(deck.position, 2)
        XCTAssertEqual(deck.total, 3)
        deck.skip("TB1")
        XCTAssertEqual(deck.current?.id, "11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(deck.items.last?.id, "TB1")
        deck.unmark("UV1")
        XCTAssertEqual(deck.current?.id, "UV1", "undo brings the card back")

        // a fresh docket: what is gone stops counting as handled, and a deferral that ran out is back
        deck.markHandled("UV1")
        let fresh = Array(try items().dropFirst())
        deck.replace(with: fresh, now: ISO.date("2026-11-05T00:00:00Z"))
        XCTAssertEqual(deck.handled, [])
        XCTAssertEqual(deck.remaining.count, 3)
        XCTAssertEqual(deck.current?.id, "TB1")
        for item in fresh { deck.markHandled(item.id) }
        XCTAssertTrue(deck.isFinished)
        XCTAssertNil(deck.current)
    }

    // MARK: Asserting

    func testAssertingAUV() {
        var draft = TruthAssertDraft(type: .uv)
        XCTAssertEqual(draft.problem, "Say what you believe.")
        draft.text = "  The cap is 5.  "
        XCTAssertEqual(draft.problem, "Say why you believe it.")
        draft.basis = "The config says so"
        XCTAssertTrue(draft.canSend)
        let body = draft.body(ledger: "team")
        XCTAssertEqual(body["type"], "UV")
        XCTAssertEqual(body["assertion"], "The cap is 5.")
        XCTAssertEqual(body["basis"], "The config says so")
        XCTAssertEqual(body["verifyBy"]?["kind"], "inspect")
        XCTAssertEqual(body["verifyBy"]?["value"], "(unspecified)")
        XCTAssertEqual(body["ledger"], "team")
        draft.verifyBy = "config.ts"
        XCTAssertEqual(draft.body(ledger: "team")["verifyBy"]?["value"], "config.ts")
    }

    func testAssertingATBNeedsEvidenceAndMayRetireAValue() {
        var draft = TruthAssertDraft(type: .tb)
        draft.text = "The cap is 5; 3 is dead."
        XCTAssertEqual(draft.problem, "A TB needs at least one piece of evidence.")
        draft.evidence = [TruthEvidenceDraft(kind: .commit, ref: "abc123")]
        XCTAssertTrue(draft.canSend)
        draft.deadValue = "3"
        draft.subject = "MAX_RETRIES"
        let body = draft.body(ledger: "default")
        XCTAssertEqual(body["type"], "TB")
        XCTAssertEqual(body["claim"], "The cap is 5; 3 is dead.")
        XCTAssertEqual(body["evidence"]?[0]?["kind"], "commit")
        XCTAssertEqual(body["literals"]?[0]?["dead"], "3")
        XCTAssertEqual(body["literals"]?[0]?["subject"], "MAX_RETRIES")
        XCTAssertNil(body["literals"]?[0]?["current"])
        XCTAssertNil(body["assertion"])
    }

    func testEvidenceKindsKnowWhatSettles() {
        XCTAssertTrue(TruthEvidenceKind.commit.isSettling)
        XCTAssertTrue(TruthEvidenceKind.claimedCommand.isSettling)
        XCTAssertFalse(TruthEvidenceKind.chat.isSettling)
        XCTAssertEqual(TruthEvidenceKind.claimedCommand.title, "command")
        XCTAssertEqual(TruthEvidenceKind.claimedCommand.rawValue, "claimed-command")
    }

    // MARK: Requests

    func testDecisionsGoToTheRightRoutes() async throws {
        let transport = MockTransport(routes: [
            .json(.post, "/api/truth/review/UV1", #"{"id":"UV1","action":"approve","status":"approved","approvals":{"missing":[]}}"#, status: 201),
            .json(.post, "/api/truth/review/UV1/ask", #"{"id":"UV1","answer":[],"pending":0}"#),
            .json(.get, "/api/truth/review", Self.docketJSON),
            .json(.put, "/api/truth/review", #"{"ok":true,"review":{"cadence":"weekly","last_at":null,"due":true,"next_at":null}}"#),
            .json(.put, "/api/truth/handle", #"{"handle":"johnny"}"#, status: 201),
        ])
        let api = client(transport)
        let body = TruthDocketRules.body(of: .approve, for: try items()[0], ledger: "team", draft: TruthDecisionDraft())
        let outcome = try await api.send(.decideTruth(target: "UV1", body: body))
        XCTAssertEqual(outcome.status, "approved")
        let ask = try await api.send(.askTruth(target: "UV1", body: .object(["ledger": "team", "room_id": "r1"])))
        XCTAssertEqual(ask.replies?.count, 0)
        let review = try await api.send(.truthReview(ledger: "team"))
        XCTAssertEqual(review.docket.items.count, 4)
        let schedule = try await api.send(.setTruthCadence(.weekly))
        XCTAssertEqual(schedule.review.cadence, .weekly)
        let handle = try await api.send(.setTruthHandle("  johnny "))
        XCTAssertEqual(handle.handle, "johnny")
        let sent = await transport.requests
        XCTAssertEqual(sent[2].url?.query, "ledger=team")
        let cadence = try HVCoding.decoder(.verbatim).decode(JSONValue.self, from: try XCTUnwrap(sent[3].httpBody))
        XCTAssertEqual(cadence["cadence"], "weekly")
        let named = try HVCoding.decoder(.verbatim).decode(JSONValue.self, from: try XCTUnwrap(sent[4].httpBody))
        XCTAssertEqual(named["handle"], "johnny")
    }

    func testAnAgentRoomRefusalKeepsTheServersSentence() async {
        let transport = MockTransport(routes: [.failure(.post, "/api/truth/review/UV1", status: 409, message: "\"default\" is a mirror ledger: decide its items in stenographer, whose stream it mirrors.")])
        do {
            _ = try await client(transport).send(.decideTruth(target: "UV1", body: .object([:])))
            XCTFail("expected a refusal")
        } catch let error as HVError {
            XCTAssertEqual(error.status, 409)
            XCTAssertTrue(error.userMessage.contains("mirror ledger"))
            XCTAssertFalse(error.isTruthHandleRequired)
        } catch {
            XCTFail("\(error)")
        }
    }
}

enum ISO {
    static func date(_ text: String) -> Date { HVDate.parse(text) ?? Date(timeIntervalSince1970: 0) }
}
