import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

// The truth ledger: hosted and mirror ledgers, UVs and TBs, contests, the review docket, derivations and
// what rests on a fact, events, exports and imports. Each journey runs as a person who did not exist a
// moment ago, so a ledger's handle, history and docket start empty.

final class LocalE2ETruthTests: LocalE2ECase {

    private struct Person {
        let api: HVClient
        let token: String
        let id: String
        let handle: String
    }

    /// A new person with a ledger of their own and a truth handle chosen.
    private func person(_ label: String = "truth") async throws -> (Person, String) {
        let fresh = try await freshMember(label)
        let handle = unique("handle")
        let set = try await send(.setTruthHandle(handle), fresh.client)
        XCTAssertEqual(set.handle, handle)
        let slug = unique("case")
        let made = try await send(.createTruthLedger(slug: slug, name: "Case \(slug)", kind: .hosted), fresh.client)
        XCTAssertEqual(made.ledger.slug, slug)
        return (Person(api: fresh.client, token: fresh.token, id: fresh.userID, handle: handle), slug)
    }

    private func assertLine(_ draft: TruthAssertDraft, _ slug: String, _ api: HVClient) async throws -> TruthLine {
        let result = try await send(.assertTruth(draft, ledger: slug), api)
        return try XCTUnwrap(result.line, "the server answered without the line it wrote")
    }

    private func uv(_ text: String, basis: String = "I checked", verify: String = "run it") -> TruthAssertDraft {
        var draft = TruthAssertDraft(type: .uv)
        draft.text = text
        draft.basis = basis
        draft.verifyBy = verify
        return draft
    }

    private func tb(_ text: String, ref: String = "docs/spec.md") -> TruthAssertDraft {
        var draft = TruthAssertDraft(type: .tb)
        draft.text = text
        draft.evidence = [TruthEvidenceDraft(kind: .file, ref: ref, detail: "the spec")]
        return draft
    }

    /// An agent holding a key of the person's: what asserts a UV the person did not draft themselves.
    private func agent(of p: Person, _ api: HVClient? = nil) async throws -> HVClient {
        let key = try await send(.createAgentKey(name: unique("truth agent")), api ?? p.api)
        return client(key.key)
    }

    // MARK: Ledgers and the handle

    func testLedgersAreCreatedListedAndTheHandleIsChosenOnce() async throws {
        let fresh = try await freshMember("ledgers")
        let api = fresh.client

        // A new person has the one default ledger, a mirror, and cannot sign a TB before choosing a name.
        let (initial, raw) = try await fetch(.truthLedgers, api)
        XCTAssertEqual(initial.ledgers.count, rawCount(raw, "ledgers"))
        XCTAssertEqual(initial.defaultSlug, raw["default"]?.string)
        let first = try XCTUnwrap(initial.ledgers.first)
        XCTAssertEqual(first.slug, initial.defaultSlug)
        XCTAssertEqual(first.kind, .mirror)
        XCTAssertFalse(first.isHosted)

        let slug = unique("hosted")
        XCTAssertNil(TruthLedgerSlug.problem(slug))
        let created = try await send(.createTruthLedger(slug: slug, name: "My case", kind: .hosted), api)
        XCTAssertEqual(created.ledger.kind, .hosted)
        XCTAssertEqual(created.ledger.name, "My case")
        XCTAssertNotNil(created.ledger.createdAt)

        let tbAttempt = await expectFailure(409, .assertTruth(tb("Needs a name"), ledger: slug), api)
        XCTAssertTrue(HVError.api(try XCTUnwrap(tbAttempt)).isTruthHandleRequired, "the Kit cannot tell the handle is missing: \(String(describing: tbAttempt?.body))")

        let handle = unique("signer")
        XCTAssertNil(TruthHandle.problem(handle))
        let set = try await send(.setTruthHandle(handle), api)
        XCTAssertEqual(set.handle, handle)
        let again = try await send(.setTruthHandle(handle), api)
        XCTAssertEqual(again.handle, handle, "choosing the same name again is fine")
        await expectFailure(409, .setTruthHandle(unique("other")), api)
        XCTAssertNotNil(TruthHandle.problem("  "))
        await expectFailure(400, .setTruthHandle("anonymous"), api)

        let list = try await send(.truthLedgers, api)
        XCTAssertEqual(list.ledgers.count, 2)
        XCTAssertEqual(list.hosted.map(\.slug), [slug])
        XCTAssertEqual(list.choose(preferring: slug)?.slug, slug)
        XCTAssertEqual(list.chooseForReview(preferring: nil)?.slug, slug, "review defaults to a hosted ledger")

        await expectFailure(409, .createTruthLedger(slug: slug, kind: .hosted), api)
        XCTAssertNotNil(TruthLedgerSlug.problem("Has Spaces"))
        await expectFailure(400, .createTruthLedger(slug: "Has Spaces", kind: .hosted), api)
        let mirror = try await send(.createTruthLedger(slug: unique("mirror"), kind: .mirror), api)
        XCTAssertEqual(mirror.ledger.kind, .mirror)
        let strangers = try await send(.truthLedgers, client(env.token))
        XCTAssertFalse(strangers.ledgers.contains { $0.slug == slug }, "another person's ledger is listed")
        XCTAssertEqual(TruthLedgerSlug.suggest(from: "My Case 2026!").isEmpty, false)
    }

    // MARK: Asserting and reading

    func testAssertingUVsAndTBsAndReadingTheOverview() async throws {
        let (p, slug) = try await person()
        let uvText = "The deploy takes 40 seconds"
        let uvResult = try await send(.assertTruth(uv(uvText, basis: "I timed it twice", verify: "run it"), ledger: slug), p.api)
        let uvLine = try XCTUnwrap(uvResult.line)
        XCTAssertEqual(uvLine.type, .uv)
        XCTAssertEqual(uvLine.assertion, uvText)
        XCTAssertEqual(uvLine.basis, "I timed it twice")
        XCTAssertEqual(uvLine.verifyBy?.value, "run it")
        XCTAssertEqual(uvLine.status, "open")
        XCTAssertEqual(uvLine.author, p.handle)
        XCTAssertEqual(uvResult.standing, .sound)
        XCTAssertFalse(uvLine.id.isEmpty)
        XCTAssertNotNil(uvLine.ts)

        let tbResult = try await send(.assertTruth(tb("The spec lives in docs/spec.md"), ledger: slug), p.api)
        let tbLine = try XCTUnwrap(tbResult.line)
        XCTAssertEqual(tbLine.type, .tb)
        XCTAssertEqual(tbLine.claim, "The spec lives in docs/spec.md")
        XCTAssertEqual(tbLine.signedBy, p.handle)
        XCTAssertEqual(tbLine.answerableBy, p.handle)
        XCTAssertEqual(tbLine.evidence.count, 1)
        XCTAssertEqual(tbLine.evidence.first?.kind, "file")
        XCTAssertEqual(tbLine.evidence.first?.ref, "docs/spec.md")
        XCTAssertEqual(tbLine.status, "active")

        // The drafts the Kit refuses are refused by the server as well.
        XCTAssertNotNil(TruthAssertDraft(type: .tb).problem)
        var noEvidence = TruthAssertDraft(type: .tb)
        noEvidence.text = "Nothing behind it"
        noEvidence.evidence = [TruthEvidenceDraft(kind: .file, ref: "")]
        XCTAssertNotNil(noEvidence.problem)
        await expectFailure(400, .assertTruth(noEvidence, ledger: slug), p.api)
        var noBasis = uv("No basis")
        noBasis.basis = ""
        XCTAssertNotNil(noBasis.problem)
        await expectFailure(400, .assertTruth(noBasis, ledger: slug), p.api)
        await expectFailure(404, .assertTruth(uv("Nowhere"), ledger: "no-such-ledger-\(unique("x"))"), p.api)

        // The overview folds both lines.
        let (overview, raw) = try await fetch(.truth(ledger: slug), p.api)
        XCTAssertEqual(overview.ledger?.slug, slug)
        XCTAssertEqual(overview.entries.count, rawCount(raw, "entries"))
        XCTAssertEqual(overview.summary.total, 2)
        XCTAssertEqual(overview.summary.total, raw["summary"]?["total"]?.int)
        XCTAssertEqual(overview.summary.cited, raw["summary"]?["cited"]?.int)
        XCTAssertEqual(overview.summary.flags, raw["summary"]?["flags"]?.int)
        XCTAssertEqual(overview.citable.count, rawCount(raw, "citable"))
        XCTAssertEqual(overview.flags.count, rawCount(raw, "flags"))
        XCTAssertEqual(overview.citable.map(\.entry.id), [tbLine.id])
        XCTAssertEqual(overview.flags.map(\.id), [uvLine.id])
        XCTAssertEqual(overview.summary.cited, 1)
        XCTAssertEqual(overview.summary.flags, 1)
        XCTAssertTrue(overview.chatTruth)
        XCTAssertFalse(overview.sidecar.configured)
        XCTAssertEqual(overview.docket?.size, raw["docket"]?["size"]?.int)
        XCTAssertNotNil(overview.asOf)
        let sections = overview.sections
        XCTAssertEqual(sections.standing.map(\.id), [tbLine.id])
        XCTAssertEqual(sections.unverified.map(\.id), [uvLine.id])
        XCTAssertEqual(overview.entries.first { $0.id == uvLine.id }?.freshness?.isStale, false)
        report("truth overview", [("entries", overview.entries.count), ("citable", overview.citable.count), ("history", sections.history.count)])
        // `clouded` and `stale` are in the server's summary; the Kit's summary has no field for them.
        print("e2e truth summary keys the server sent: \(raw["summary"]?.object?.keys.sorted() ?? [])")
    }

    // MARK: Contests, appeals, the docket

    func testAContestPutsATBUnderAppealAndTheDocketLetsThePersonDecide() async throws {
        let (p, slug) = try await person()
        let tbResult = try await send(.assertTruth(tb("The script lives in scripts/deploy.sh", ref: "scripts/deploy.sh"), ledger: slug), p.api)
        let tbID = try XCTUnwrap(tbResult.line?.id)
        let agent = try await agent(of: p)

        // An agent's UV that contests it: nobody approves or refutes what they drafted themselves.
        let contest = Endpoint<JSONValue>(.post, "/api/truth/entries", body: .jsonValue([
            "type": "UV", "ledger": .string(slug), "assertion": "It moved to ops/deploy.sh", "basis": "saw the diff",
            "verifyBy": ["kind": "inspect", "value": "git log"], "contests": .string(tbID),
        ]), keys: .verbatim)
        let contested = try await send(contest, agent)
        XCTAssertTrue(contested["line"]?["author"]?.string?.hasPrefix("agent:") ?? false, "an agent's line names it: \(contested["line"]?["author"] ?? .null)")
        let appealID = try XCTUnwrap(contested["line"]?["id"]?.string)
        XCTAssertEqual(contested["line"]?["contests"]?.string, tbID)

        // The TB is under appeal: no longer citable, and flagged.
        let overview = try await send(.truth(ledger: slug), p.api)
        XCTAssertEqual(overview.entries.first { $0.id == tbID }?.status, "contested")
        XCTAssertEqual(overview.summary.contested, 1)
        let row = try XCTUnwrap(overview.sections.all.first { $0.id == tbID })
        XCTAssertEqual(TruthStatus.label(row.status), "Under appeal")
        XCTAssertEqual(TruthStatus.tone(row.status), .attention)

        // An event says so.
        let events = try await send(.truthEvents(limit: 20, kinds: [.challenged]), p.api)
        let event = try XCTUnwrap(events.events.first { $0.entryId == tbID }, "no 'challenged' event")
        XCTAssertEqual(event.kind, .challenged)
        XCTAssertEqual(event.entryType, .tb)
        XCTAssertEqual(event.priorStatus, "active")
        XCTAssertEqual(event.newStatus, "contested")
        XCTAssertEqual(event.byEntryId, appealID)
        XCTAssertTrue(event.kind.isSetback)
        XCTAssertFalse(event.summary.isEmpty)

        // The docket has the UV, the appeal against the TB, and the review schedule.
        let (review, reviewRaw) = try await fetch(.truthReview(ledger: slug), p.api)
        XCTAssertEqual(review.docket.items.count, rawCount(reviewRaw["docket"] ?? .null, "items"))
        XCTAssertEqual(review.docket.size, review.docket.items.count)
        let appeal = try XCTUnwrap(review.docket.items.first { $0.kind == .appeal }, "kinds: \(review.docket.items.map(\.kind))")
        XCTAssertEqual(appeal.id, tbID)
        XCTAssertEqual(appeal.contestedBy.map(\.id), [appealID])
        XCTAssertEqual(appeal.contestedBy.first?.assertion, "It moved to ops/deploy.sh")
        let uvItem = try XCTUnwrap(review.docket.items.first { $0.kind == .uv && $0.id == appealID })
        XCTAssertEqual(uvItem.subject, tbID)
        XCTAssertEqual(uvItem.basis, "saw the diff")
        XCTAssertEqual(uvItem.contests, tbID)
        XCTAssertEqual(uvItem.approvals?.missing.contains("a human approval"), true)
        XCTAssertNotNil(uvItem.freshness)
        XCTAssertNotNil(uvItem.derivation)
        XCTAssertFalse(review.review.due)

        // What each action on the card is, per the Kit's rules, against what the server does.
        let ledger = review.ledger
        let strike = TruthDocketRules.state(of: .strike, for: appeal, in: ledger)
        XCTAssertTrue(strike.isAvailable, strike.unavailableReason ?? "")
        XCTAssertFalse(TruthDocketRules.state(of: .refute, for: appeal, in: ledger).isAvailable, "the person signed the TB and cannot refute the appeal")
        var draft = TruthDecisionDraft()
        draft.opinion = "The file is where it was."
        let target = try XCTUnwrap(TruthDocketRules.target(of: .strike, for: appeal, draft: draft))
        XCTAssertEqual(target, appealID)
        XCTAssertNil(TruthDocketRules.problem(with: .strike, for: appeal, draft: draft))

        // Refute without evidence is refused; strike the appeal with an opinion and the TB is released.
        // (Nobody who stands behind a TB may refute the appeal against it: the server says so, with a reason.)
        let refuseBody = TruthDocketRules.body(of: .refute, for: uvItem, ledger: slug, draft: TruthDecisionDraft())
        await expectFailure(409, .decideTruth(target: uvItem.id, body: refuseBody), p.api, message: "cannot refute the appeal")
        let struck = try await send(.decideTruth(target: target, body: TruthDocketRules.body(of: .strike, for: appeal, ledger: slug, draft: draft)), p.api)
        XCTAssertEqual(struck.status, "struck")
        XCTAssertEqual(struck.sentence, "Struck.")
        XCTAssertTrue(struck.settled)
        let released = try await send(.truth(ledger: slug), p.api)
        XCTAssertEqual(released.entries.first { $0.id == tbID }?.status, "active", "striking the appeal should release the TB")
        XCTAssertEqual(released.summary.contested, 0)
        let upheld = try await send(.truthEvents(limit: 20, kinds: [.upheld]), p.api)
        XCTAssertTrue(upheld.events.contains { $0.entryId == tbID }, "no 'upheld' event after the appeal was struck")
        await expectFailure(404, .decideTruth(target: "01ZZZZZZZZZZZZZZZZZZZZZZZZ", body: refuseBody), p.api)
    }

    func testApprovingARefutingAndDeferringUVsOnTheDocket() async throws {
        let (p, slug) = try await person()
        let agent = try await agent(of: p)
        let aResult = try await send(.assertTruth(uv("Approve me"), ledger: slug), agent)
        let bResult = try await send(.assertTruth(uv("Refute me"), ledger: slug), agent)
        let cResult = try await send(.assertTruth(uv("Defer me"), ledger: slug), agent)
        // The person cannot approve or refute what they drafted.
        let own = try await assertLine(uv("Mine"), slug, p.api)
        let mineReview = try await send(.truthReview(ledger: slug), p.api)
        let mineItem = try XCTUnwrap(mineReview.docket.items.first { $0.id == own.id })
        await expectFailure(409, .decideTruth(target: own.id, body: TruthDocketRules.body(of: .approve, for: mineItem, ledger: slug, draft: TruthDecisionDraft())), p.api, message: "drafted")
        let a = try XCTUnwrap(aResult.line)
        let b = try XCTUnwrap(bResult.line)
        let c = try XCTUnwrap(cResult.line)
        let review = try await send(.truthReview(ledger: slug), p.api)
        func item(_ id: String) throws -> TruthDocketItem { try XCTUnwrap(review.docket.items.first { $0.id == id }) }

        // Approve: the person's approval is recorded; promotion waits for a second approver and evidence.
        var note = TruthDecisionDraft()
        note.note = "looks right"
        let approved = try await send(.decideTruth(target: a.id, body: TruthDocketRules.body(of: .approve, for: try item(a.id), ledger: slug, draft: note)), p.api)
        XCTAssertEqual(approved.status, "approved")
        XCTAssertFalse(approved.settled, "an approval that did not complete leaves the card")
        XCTAssertTrue(approved.missing.contains("a second approver"), "\(approved.missing)")
        XCTAssertTrue(approved.sentence.contains("Still needs"))
        let after = try await send(.truthReview(ledger: slug), p.api)
        let approvedItem = try XCTUnwrap(after.docket.items.first { $0.id == a.id })
        XCTAssertEqual(approvedItem.approvals?.human, true)
        XCTAssertEqual(approvedItem.approvals?.approvers, 1)
        XCTAssertEqual(approvedItem.approvals?.list.first?.note, "looks right")

        // Refute needs evidence; with it the UV is refuted.
        var refute = TruthDecisionDraft()
        refute.evidence = [TruthEvidenceDraft(kind: .test, ref: "tests/deploy_test.sh", detail: "fails")]
        XCTAssertNil(TruthDocketRules.problem(with: .refute, for: try item(b.id), draft: refute))
        let refuted = try await send(.decideTruth(target: b.id, body: TruthDocketRules.body(of: .refute, for: try item(b.id), ledger: slug, draft: refute)), p.api)
        XCTAssertEqual(refuted.status, "refuted")
        let overview = try await send(.truth(ledger: slug), p.api)
        XCTAssertEqual(overview.entries.first { $0.id == b.id }?.status, "refuted")
        XCTAssertTrue(overview.sections.history.contains { $0.id == b.id }, "a refuted UV belongs to history")

        // Defer sets it aside; asking for it back by deferring to a moment ago undoes it.
        var deferral = TruthDecisionDraft()
        deferral.until = Date().addingTimeInterval(3 * 24 * 3600)
        let deferred = try await send(.decideTruth(target: c.id, body: TruthDocketRules.body(of: .deferral, for: try item(c.id), ledger: slug, draft: deferral)), p.api)
        XCTAssertEqual(deferred.action, "defer")
        XCTAssertNotNil(deferred.deferredUntil)
        XCTAssertEqual(deferred.sentence, "Deferred.")
        let deferredDeck = try await send(.truthReview(ledger: slug), p.api)
        XCTAssertTrue(try XCTUnwrap(deferredDeck.docket.items.first { $0.id == c.id }).isDeferred())
        _ = try await send(.decideTruth(target: c.id, body: TruthDocketRules.undoDeferralBody(ledger: slug)), p.api)
        let undone = try await send(.truthReview(ledger: slug), p.api)
        XCTAssertFalse(try XCTUnwrap(undone.docket.items.first { $0.id == c.id }).isDeferred())

        // Sitting down to review, and the cadence reminder.
        _ = try await send(.startTruthReview(), p.api)
        let weekly = try await send(.setTruthCadence(.weekly), p.api)
        XCTAssertEqual(weekly.review.cadence, .weekly)
        let scheduled = try await send(.truthReview(ledger: slug), p.api)
        XCTAssertEqual(scheduled.review.cadence, .weekly)
        XCTAssertNotNil(scheduled.review.lastAt)
        let none = try await send(.setTruthCadence(nil), p.api)
        XCTAssertNil(none.review.cadence)
    }

    // MARK: Derivations, restating a fact, and what rests on it

    func testSupersedingAPremiseUndermineWhatRestsOnItAndTheRippleFindsIt() async throws {
        let (p, slug) = try await person()
        let base = try await assertLine(tb("The API returns 200", ref: "tests/api_test.rb"), slug, p.api)
        let derived = Endpoint<JSONValue>(.post, "/api/truth/entries", body: .jsonValue([
            "type": "TB", "ledger": .string(slug), "claim": "Clients can rely on the API", "evidence": [["kind": "doc", "ref": "docs/api.md"]],
            "derives": [.string(base.id)], "inference": "If it answers 200 they can rely on it.",
        ]), keys: .verbatim)
        let derivedLine = try await send(derived, p.api)
        let derivedID = try XCTUnwrap(derivedLine["line"]?["id"]?.string)

        // The trace of the derived entry shows its premise; nothing is failing yet.
        let (trace, traceRaw) = try await fetch(.truthDerivation(id: derivedID, ledger: slug), p.api)
        XCTAssertEqual(trace.id, derivedID)
        XCTAssertEqual(trace.root.id, derivedID)
        XCTAssertEqual(trace.root.premises.map(\.id), [base.id])
        XCTAssertEqual(trace.root.standing, .sound)
        XCTAssertEqual(trace.rows.count, 2)
        XCTAssertEqual(trace.rows.map(\.depth), [0, 1])
        XCTAssertTrue(TruthTrace.hasPremises(trace.root))
        XCTAssertEqual(trace.dependents.count, rawCount(traceRaw, "dependents"))
        let baseTrace = try await send(.truthDerivation(id: base.id, ledger: slug), p.api)
        XCTAssertEqual(baseTrace.dependents.map(\.id), [derivedID], "the premise should list what rests on it")

        // A memory that rests on the base fact, and the ripple of the base fact.
        let memory = try await send(Endpoint<MemoryKept>(.post, "/api/memories", body: .jsonValue([
            "content": .string("Notes that lean on the API fact \(uniqueWord())"), "title": "Rests on the API", "rests_on": [.string(base.id)], "truth_ledger": .string(slug),
        ])), p.api)
        let page = try await send(.memoryPage(id: memory.id), p.api)
        let edge = try XCTUnwrap(page.truth?.restsOn.first, "the memory page lists no truth edge")
        XCTAssertEqual(edge.entryId, base.id)
        XCTAssertEqual(edge.ledger, slug)
        XCTAssertEqual(edge.relation, "rests_on")
        XCTAssertFalse(edge.isStale)
        XCTAssertEqual(page.truth?.stale, 0)
        let (ripple, rippleRaw) = try await fetch(.truthRipple(id: base.id, ledger: slug), p.api)
        XCTAssertEqual(ripple.roots.map(\.id), [base.id])
        XCTAssertEqual(ripple.entries.map(\.id), [derivedID])
        XCTAssertEqual(ripple.context.count, rawCount(rippleRaw, "context"))
        XCTAssertEqual(ripple.context.map(\.entryId), [base.id])
        XCTAssertEqual(ripple.context.first?.item?.title, "Rests on the API")
        XCTAssertEqual(ripple.context.first?.relation, "rests_on")
        XCTAssertFalse(ripple.sentence.isEmpty)

        // Restate the base fact: the old one is overridden, the derived one is unsupported, the memory is stale.
        let restated = Endpoint<TruthAssertResult>(.post, "/api/truth/entries", body: .jsonValue([
            "type": "TB", "ledger": .string(slug), "claim": "The API returns 204", "evidence": [["kind": "test", "ref": "tests/api_test.rb"]],
            "supersedes": .string(base.id),
        ]))
        let result = try await send(restated, p.api)
        XCTAssertEqual(result.overrode, base.id)
        let newID = try XCTUnwrap(result.line?.id)
        let overview = try await send(.truth(ledger: slug), p.api)
        XCTAssertEqual(overview.entries.first { $0.id == base.id }?.status, "overridden")
        XCTAssertEqual(overview.entries.first { $0.id == derivedID }?.standing, .unsupported)
        XCTAssertTrue(overview.displaced.contains { $0.id == base.id }, "the overridden TB should be listed as displaced")
        let unsupported = try XCTUnwrap(overview.entries.first { $0.id == derivedID })
        XCTAssertEqual(unsupported.reasons.first?.premise, base.id)
        XCTAssertEqual(unsupported.reasons.first?.reason, "premise-overridden")
        let failing = try await send(.truthDerivation(id: derivedID, ledger: slug), p.api)
        XCTAssertEqual(failing.root.standing, .unsupported)
        XCTAssertEqual(failing.root.reasons.first?.reason, "premise-overridden")
        let premise = try XCTUnwrap(failing.root.premises.first)
        XCTAssertEqual(premise.id, base.id)
        XCTAssertEqual(premise.status, "overridden")
        XCTAssertEqual(premise.failing, "premise-overridden", "the failing premise is marked on the premise")
        XCTAssertNotNil(premise.failingPhrase)
        XCTAssertEqual(premise.kind, "derives")
        let undermined = try await send(.truthEvents(limit: 20, kinds: [.undermined, .overturned]), p.api)
        XCTAssertTrue(undermined.events.contains { $0.kind == .undermined && $0.entryId == derivedID }, "events: \(undermined.events.map { "\($0.kind)" })")
        XCTAssertTrue(undermined.events.contains { $0.kind == .overturned && $0.entryId == base.id })

        // The stale worklist names the memory, with the successor; reaffirming it clears the worklist.
        let (stale, staleRaw) = try await fetch(.truthStale(ledger: slug), p.api)
        XCTAssertEqual(stale.total, staleRaw["total"]?.int)
        XCTAssertEqual(stale.items.count, rawCount(staleRaw, "items"))
        let item = try XCTUnwrap(stale.items.first { $0.item?.id == memory.id }, "the memory is not on the stale worklist")
        XCTAssertEqual(item.item?.isMemory, true)
        XCTAssertEqual(item.edges.map { $0.entryId }, [base.id])
        XCTAssertEqual(item.edges.first?.staleKind, "overturned")
        XCTAssertEqual(item.edges.first?.successor?.id, newID, "raw: \(staleRaw.jsonString())")
        XCTAssertFalse(item.edges.first?.readableWhatMoved.isEmpty ?? true)
        let pageStale = try await send(.memoryPage(id: memory.id), p.api)
        XCTAssertEqual(pageStale.truth?.stale, 1)
        let contextItem = try XCTUnwrap(item.item)
        _ = try await send(.resolveTruthStale(.relink, item: contextItem, entries: [base.id], to: [newID], ledger: slug), p.api)
        let cleared = try await send(.truthStale(ledger: slug), p.api)
        XCTAssertNil(cleared.items.first { $0.item?.id == memory.id }, "relinking left the memory on the worklist")
        let relinked = try await send(.memoryPage(id: memory.id), p.api)
        XCTAssertEqual(relinked.truth?.restsOn.map(\.entryId), [newID])
        XCTAssertEqual(relinked.truth?.stale, 0)
    }

    // MARK: Exports, mirrors, proposals, settings

    func testAHostedLedgerExportsItsStreamAndAMirrorTakesItBack() async throws {
        let (p, slug) = try await person()
        let a = try await assertLine(uv("First claim \(uniqueWord())"), slug, p.api)
        let b = try await assertLine(tb("Second, settled", ref: "README.md"), slug, p.api)

        let exported = try await send(.exportTruth(ledger: slug), p.api)
        let text = String(decoding: exported, as: UTF8.self)
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2, text)
        let parsed = try lines.map { try HVCoding.decoder(.verbatim).decode(JSONValue.self, from: Data($0.utf8)) }
        XCTAssertEqual(parsed.compactMap { $0["id"]?.string }, [a.id, b.id], "the stream is in seq order")
        XCTAssertEqual(parsed.compactMap { $0["seq"]?.int }, [1, 2])
        XCTAssertEqual(parsed[1]["prevHash"]?.string, parsed[0]["hash"]?.string, "the hash chain is not whole")
        let since = try await send(.exportTruth(ledger: slug, sinceSeq: 1), p.api)
        XCTAssertEqual(String(decoding: since, as: UTF8.self).split(separator: "\n").count, 1)

        // A mirror ledger is filled by importing a stream; the same stream gives the same entries.
        let mirrorSlug = unique("mirror")
        _ = try await send(.createTruthLedger(slug: mirrorSlug, name: "Mirror", kind: .mirror), p.api)
        let imported = try await send(.importTruth(jsonl: text, ledger: mirrorSlug), p.api)
        XCTAssertTrue(imported.committed)
        XCTAssertEqual(imported.lines, 2)
        XCTAssertEqual(imported.upserted, 2)
        XCTAssertTrue(imported.errors.isEmpty, "\(imported.errors)")
        let mirror = try await send(.truth(ledger: mirrorSlug), p.api)
        XCTAssertEqual(Set(mirror.entries.map(\.id)), Set([a.id, b.id]))
        XCTAssertEqual(mirror.summary.total, 2)
        XCTAssertEqual(mirror.entries.first { $0.id == b.id }?.type, .tb)
        // A hosted ledger refuses an import, a mirror refuses a write, and a broken chain is refused.
        await expectFailure(409, .importTruth(jsonl: text, ledger: slug), p.api)
        await expectFailure(409, .assertTruth(uv("Written to a mirror"), ledger: mirrorSlug), p.api)
        let broken = lines[1].replacingOccurrences(of: "Second, settled", with: "Second, tampered")
        let victim = unique("tampered")
        _ = try await send(.createTruthLedger(slug: victim, kind: .mirror), p.api)
        await expectFailure(422, .importTruth(jsonl: lines[0] + "\n" + broken, ledger: victim), p.api, message: "refused")
        // Dropping an entry from a mirror's read model.
        _ = try await send(.deleteTruthEntry(id: a.id, ledger: mirrorSlug), p.api)
        let dropped = try await send(.truth(ledger: mirrorSlug), p.api)
        XCTAssertNil(dropped.entries.first { $0.id == a.id })
        await expectFailure(409, .deleteTruthEntry(id: a.id, ledger: slug), p.api)

        await expectFailure(404, .exportTruth(ledger: unique("missing")), p.api)
    }

    func testPageImportsAndProposalsAreDraftsUntilAPersonDecides() async throws {
        let (p, slug) = try await person()
        // Lines pasted from a page: every one is a proposal, none is truth yet.
        let pasted = """
        {"type":"UV","assertion":"The cache expires after 60 seconds","basis":"seen in config","verifyBy":{"kind":"inspect","value":"config/cache.yml"}}
        """
        let page = try await send(.importTruthPage(jsonl: pasted, ledger: slug), p.api)
        XCTAssertEqual(page.filed + page.skipped + page.errors.count, 1, "one pasted line: \(page)")
        let (proposals, raw) = try await fetch(.truthProposals(status: .open, ledger: slug), p.api)
        XCTAssertEqual(proposals.proposals.count, rawCount(raw, "proposals"))
        report("page import", [("filed", page.filed), ("skipped", page.skipped), ("open proposals", proposals.proposals.count)])
        if let proposal = proposals.proposals.first {
            XCTAssertEqual(proposal.status, .open)
            XCTAssertFalse(proposal.headline.isEmpty)
            let exportedDrafts = try await send(.exportTruthProposals(ledger: slug, mark: false), p.api)
            XCTAssertFalse(exportedDrafts.isEmpty)
            _ = try await send(.setTruthProposal(id: proposal.id, status: .dismissed, ledger: slug), p.api)
            let open = try await send(.truthProposals(status: .open, ledger: slug), p.api)
            XCTAssertNil(open.proposals.first { $0.id == proposal.id })
            let dismissed = try await send(.truthProposals(status: .dismissed, ledger: slug), p.api)
            XCTAssertNotNil(dismissed.proposals.first { $0.id == proposal.id })
            _ = try await send(.setTruthProposal(id: proposal.id, status: .open, ledger: slug), p.api)
        }
        await expectFailure(400, .importTruthPage(ledger: slug), p.api)
    }

    func testSignersEventsInboxRoomsAndTheChatSwitch() async throws {
        let (p, slug) = try await person()
        _ = try await send(.assertTruth(tb("Something settled", ref: "a.md"), ledger: slug), p.api)

        let signers = try await send(.truthSigners, p.api)
        XCTAssertTrue(signers.signers.contains { $0.id == p.handle && $0.isHuman }, "signers: \(signers.signers)")

        // The sidecar is not configured on this server: its inbox says so rather than failing.
        let inbox = await expectFailure(503, .truthInbox, p.api, message: "sidecar")
        XCTAssertEqual(inbox?.body?["configured"]?.bool, false)

        let rooms = try await send(.truthRooms, p.api)
        XCTAssertTrue(rooms.rooms.isEmpty)
        let events = try await send(.truthEvents(), p.api)
        XCTAssertGreaterThanOrEqual(events.events.count, 0)

        let off = try await send(.citeTruthInChat(false), p.api)
        XCTAssertEqual(off.truth, false)
        let settings = try await send(.chatSettings, p.api)
        XCTAssertFalse(settings.truth)
        let overview = try await send(.truth(ledger: slug), p.api)
        XCTAssertFalse(overview.chatTruth)
        let on = try await send(.citeTruthInChat(true), p.api)
        XCTAssertEqual(on.truth, true)

        // The notary routes need the sidecar's secret and answer plainly without it.
        let refusal = await expectFailure(503, .notarizeTruth(id: "01ZZZZZZZZZZZZZZZZZZZZZZZZ"), p.api, message: "sidecar")
        report("notarize without a sidecar", [("status", refusal?.status ?? 0)])
    }
}
