import HyperVaultKit
import XCTest
@testable import HyperVault

/// A counter the mock routes can bump from any thread.
private final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var bodies: [Data] = []

    func record(_ request: URLRequest) -> Int {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        bodies.append(request.httpBody ?? Data())
        return calls
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    var allBodies: [Data] { lock.lock(); defer { lock.unlock() }; return bodies }
}

@MainActor
private func eventually(_ timeout: TimeInterval = 4, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

// MARK: Task boards

@MainActor
final class TaskBoardModelTests: XCTestCase {
    private let project = "eurorack-choir"

    private func board(version: Int, psu: String = "todo", firmware: String = "blocked") -> String {
        TaskBoardPreviewData.boardJSON
            .replacingOccurrences(of: #""version":42"#, with: #""version":\#(version)"#)
            .replacingOccurrences(
                of: #""id":"t-psu","title":"Pick a power supply","type":"task","status":"todo""#,
                with: #""id":"t-psu","title":"Pick a power supply","type":"task","status":"\#(psu)""#
            )
            .replacingOccurrences(
                of: #""id":"t-fw","title":"Wait for the firmware drop","type":"task","status":"blocked""#,
                with: #""id":"t-fw","title":"Wait for the firmware drop","type":"task","status":"\#(firmware)""#
            )
    }

    private func model(_ routes: [MockRoute]) -> TaskBoardModel {
        let env = AppEnvironment.preview(routes: routes)
        return TaskBoardModel(client: env.client, cache: env.cache, namespace: "tests", project: project, title: "Eurorack Choir Module")
    }

    private func get(_ version: Int) -> MockRoute {
        .json(.get, "/api/tasklists/\(project)", #"{"slug":"tasks-\#(project)","tasklist":\#(board(version: version))}"#)
    }

    /// What a write answers: the task and the whole list at its new revision.
    private func written(_ list: String) -> HTTPResponse {
        HTTPResponse(status: 200, data: Data(#"{"task":{"id":"t-psu","title":"x"},"tasklist":\#(list),"message":"ok"}"#.utf8))
    }

    func testATickShowsAtOnceAndIsConfirmedByTheServer() async throws {
        let tally = Tally()
        let answer = written(board(version: 43, psu: "in_progress"))
        let patch = MockRoute(.patch, "/api/tasklists/\(project)/tasks/t-psu") { request in
            _ = tally.record(request)
            return answer
        }
        let model = model([get(42), patch])
        await model.start()
        XCTAssertEqual(model.board?.version, 42)

        model.enqueue(.setStatus(taskID: "t-psu", to: .inProgress))
        XCTAssertEqual(model.board?.task("t-psu")?.status, .inProgress, "the tick lands before the server answers")
        XCTAssertEqual(model.confirmed?.version, 42)

        let settled = await eventually { model.pending.isEmpty }
        XCTAssertTrue(settled)
        XCTAssertEqual(model.confirmed?.version, 43)
        XCTAssertEqual(model.board?.task("t-psu")?.status, .inProgress)
        let sent = try HVCoding.decoder(.verbatim).decode(JSONValue.self, from: try XCTUnwrap(tally.allBodies.first))
        XCTAssertEqual(sent["expected_version"], 42)
        XCTAssertEqual(sent["patch"]?["status"], "in_progress")
    }

    func testAChangeToAnotherTaskIsSentAgainOnTopOfTheLatest() async throws {
        let tally = Tally()
        let latest = board(version: 43, firmware: "todo")
        let conflict = HTTPResponse(status: 409, data: Data(#"{"error":"Version conflict","conflict":true,"latest":\#(latest)}"#.utf8))
        let answer = written(board(version: 44, psu: "in_progress", firmware: "todo"))
        let patch = MockRoute(.patch, "/api/tasklists/\(project)/tasks/t-psu") { request in
            tally.record(request) == 1 ? conflict : answer
        }
        let model = model([get(42), patch])
        await model.start()
        model.enqueue(.setStatus(taskID: "t-psu", to: .inProgress))

        let settled = await eventually { model.pending.isEmpty && model.confirmed?.version == 44 }
        XCTAssertTrue(settled)
        XCTAssertNil(model.clash)
        XCTAssertEqual(tally.count, 2)
        XCTAssertEqual(model.board?.task("t-fw")?.status, .todo, "what someone else changed is kept")
        XCTAssertEqual(model.board?.task("t-psu")?.status, .inProgress)
        let second = try HVCoding.decoder(.verbatim).decode(JSONValue.self, from: try XCTUnwrap(tally.allBodies.last))
        XCTAssertEqual(second["expected_version"], 43, "pinned to the revision it was sent on top of")
    }

    func testAChangeToWhatSomeoneElseChangedIsPutToThePerson() async throws {
        let tally = Tally()
        let latest = board(version: 43, psu: "blocked")
        let conflict = HTTPResponse(status: 409, data: Data(#"{"error":"Version conflict","conflict":true,"latest":\#(latest)}"#.utf8))
        let answer = written(board(version: 44, psu: "done"))
        let patch = MockRoute(.patch, "/api/tasklists/\(project)/tasks/t-psu") { request in
            tally.record(request) == 1 ? conflict : answer
        }
        let model = model([get(42), patch])
        await model.start()
        model.enqueue(.setStatus(taskID: "t-psu", to: .done))

        let asked = await eventually { model.clash != nil }
        XCTAssertTrue(asked)
        XCTAssertEqual(model.board?.task("t-psu")?.status, .blocked, "the latest list is shown while the person decides")
        XCTAssertTrue(model.pending.isEmpty)
        XCTAssertEqual(tally.count, 1)

        model.resolveClash(keepMine: true)
        let landed = await eventually { model.confirmed?.version == 44 }
        XCTAssertTrue(landed)
        XCTAssertEqual(model.board?.task("t-psu")?.status, .done)
        XCTAssertNil(model.clash)
    }

    func testARefusedChangeStopsBeingShownAndSaysWhy() async throws {
        let patch = MockRoute.failure(.patch, "/api/tasklists/\(project)/tasks/t-psu", status: 404, message: "No task \"t-psu\" in this list.")
        let model = model([get(42), patch])
        var said: String?
        model.onFailure = { said = $0 }
        await model.start()
        model.enqueue(.setStatus(taskID: "t-psu", to: .done))
        XCTAssertEqual(model.board?.task("t-psu")?.status, .done)
        let settled = await eventually { model.pending.isEmpty }
        XCTAssertTrue(settled)
        XCTAssertEqual(model.board?.task("t-psu")?.status, .todo, "rolled back")
        XCTAssertEqual(said, "No task \"t-psu\" in this list.")
    }

    func testAddingATaskShowsItAtOnceUnderATemporaryName() async throws {
        let answer = written(board(version: 43))
        let patch = MockRoute(.post, "/api/tasklists/\(project)/tasks") { _ in answer }
        let model = model([get(42), patch])
        await model.start()
        let before = model.board?.tasks.count ?? 0
        model.add(title: "  Sketch the panel  ", parent: "epic-hw")
        XCTAssertEqual(model.board?.tasks.count, before + 1)
        XCTAssertTrue(model.board?.tasks.contains { TaskBoardModel.isTemporary($0.id) } ?? false)
        let settled = await eventually { model.pending.isEmpty }
        XCTAssertTrue(settled)
        XCTAssertFalse(model.board?.tasks.contains { TaskBoardModel.isTemporary($0.id) } ?? true)
    }
}

// MARK: Mail

@MainActor
final class MailModelTests: XCTestCase {
    private func model(_ routes: [MockRoute]) -> MailModel {
        let env = AppEnvironment.preview(routes: routes)
        return MailModel(client: env.client, cache: env.cache, namespace: "tests")
    }

    func testTheInboxLoadsWithItsMailbox() async throws {
        let model = model(MailPreviewData.routes)
        await model.start()
        XCTAssertEqual(model.mailboxState, .loaded)
        XCTAssertEqual(model.listState, .loaded)
        XCTAssertEqual(model.active?.address, "ana@vault.cool")
        XCTAssertEqual(model.mailboxes.count, 2)
        XCTAssertEqual(model.threads.count, 4)
        XCTAssertEqual(model.totalUnread, 2)
        XCTAssertFalse(model.isShowingSavedCopy)
    }

    func testMovingAThreadTakesItOffTheListAndPutsItBackIfRefused() async throws {
        let threadID = MailPreviewData.threadID
        let page = MailPreviewData.thread
        let failing = [
            MockRoute(.get, "/api/mail/messages") { request in
                let isThread = request.url?.query?.contains("thread_id") == true
                return HTTPResponse(status: 200, data: Data((isThread ? page : MailPreviewData.inbox).utf8))
            },
            MockRoute.json(.get, "/api/mail/owner/mailboxes", MailPreviewData.mailboxes),
            MockRoute.json(.patch, "/api/mail/messages/*", #"{"error":"claim_released: Pick an address first.","code":"claim_released"}"#, status: 409),
        ]
        let model = model(failing)
        await model.start()
        let thread = try XCTUnwrap(model.threads.first { $0.id == threadID })
        do {
            _ = try await model.move(thread, to: .archive)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(MailModel.sentence(error), "Pick an address first.")
        }
        XCTAssertTrue(model.threads.contains { $0.id == threadID }, "put back")
    }

    func testReadingAThreadClearsItsUnreadMessagesOnTheServerAndOnScreen() async throws {
        let model = model(MailPreviewData.routes + [.json(.patch, "/api/mail/messages/*", #"{"message":{"id":"m1"}}"#)])
        await model.start()
        let thread = try XCTUnwrap(model.threads.first { $0.unread })
        await model.markRead(thread)
        XCTAssertFalse(model.threads.first { $0.id == thread.id }?.unread ?? true)
    }

    func testMailThatIsNotSetUpSaysSo() async throws {
        let model = model(MailPreviewData.unavailableRoutes)
        await model.start()
        guard case .failed(let message) = model.mailboxState else { return XCTFail("expected a failure") }
        XCTAssertEqual(message, "Agent Mail is not set up on this server yet.")
        XCTAssertEqual(model.mailboxProblem, .unavailable)
        XCTAssertTrue(model.isMailUnavailable, "the screen shows its calm notice and turns writing off")
    }

    func testALostConnectionIsNotTakenForMailThatIsNotSetUp() async throws {
        let transport = MailOfflineTransport()
        let client = HVClient(baseURL: URL(string: "https://offline.hypervault.test")!, transport: transport, tokens: StaticTokenProvider(), retry: .none)
        let cache = DiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("hv-offline-\(UUID().uuidString)"))
        let model = MailModel(client: client, cache: cache, namespace: "tests")
        await model.start()
        XCTAssertEqual(model.mailboxProblem, .offline)
        XCTAssertFalse(model.isMailUnavailable, "a dropped connection keeps its way to try again")
    }

    func testAServerFaultIsNeitherOfThose() async throws {
        let model = model([.failure(.get, "/api/mail/owner/mailboxes", status: 500, message: "Something broke.")])
        await model.start()
        XCTAssertEqual(model.mailboxProblem, .other)
        XCTAssertFalse(model.isMailUnavailable)
    }

    func testANoteThatWentThroughIsSentWhateverTheAnswerLooksLike() async throws {
        let sends = Tally()
        let post = MockRoute(.post, "/api/mail/messages") { request in
            _ = sends.record(request)
            return HTTPResponse(status: 201, data: Data(#"{"ok":true}"#.utf8))
        }
        let model = model([post] + MailPreviewData.routes)
        await model.start()
        try await model.send(subject: "Plan", text: "Start with the garden notes.")
        XCTAssertEqual(sends.count, 1)
        XCTAssertEqual(model.filter, .sent)
    }

    /// Found by the local end-to-end run: an account with no claimed address and no mail has no mailbox until
    /// its messages are first read, and the list of mailboxes never makes the box. The first visit asked for
    /// the mailboxes, got none, read the messages (which made the box) and left Compose off until a refresh.
    func testAFirstVisitThatFindsNoMailboxAsksAgainOnceTheMessagesHaveMadeOne() async throws {
        let made = MailReplySent()
        let mailboxes = MockRoute(.get, "/api/mail/owner/mailboxes") { _ in
            HTTPResponse(status: 200, data: Data((made.value ? MailPreviewData.mailboxes : #"{"mailboxes":[]}"#).utf8))
        }
        let messages = MockRoute(.get, "/api/mail/messages") { _ in
            made.mark()
            return HTTPResponse(status: 200, data: Data(MailPreviewData.inbox.utf8))
        }
        let model = model([mailboxes, messages])
        await model.start()
        XCTAssertEqual(model.mailboxes.count, 2, "the mailboxes were not asked for again after the box was made")
        XCTAssertNotNil(model.active, "Compose stays off with no active mailbox")
    }

    func testMailThatWorksIsNotMarkedUnavailable() async throws {
        let model = model(MailPreviewData.routes)
        await model.start()
        XCTAssertFalse(model.isMailUnavailable)
    }
}

/// Says whether the reply route has been called, for a route that must answer differently afterwards.
private final class MailReplySent: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func mark() { lock.lock(); flag = true; lock.unlock() }
}

@MainActor
final class MailThreadModelTests: XCTestCase {
    private let box = MailPreviewData.boxA

    /// A thread that loads, a reply route that answers `reply`, and a thread route
    /// that fails once the reply has gone through.
    private func model(reply: HTTPResponse, refreshFails: Bool, sent: MailReplySent, sends: Tally) -> MailThreadModel {
        let replyRoute = MockRoute(.post, "/api/mail/messages/*") { request in
            _ = sends.record(request)
            sent.mark()
            return reply
        }
        let threadRoute = MockRoute(.get, "/api/mail/messages") { _ in
            if refreshFails, sent.value { return HTTPResponse(status: 500, data: Data(#"{"error":"The server had a problem."}"#.utf8)) }
            return HTTPResponse(status: 200, data: Data(MailPreviewData.thread.utf8))
        }
        let env = AppEnvironment.preview(routes: [replyRoute, threadRoute] + MailPreviewData.threadRoutes)
        return MailThreadModel(client: env.client, threadID: MailPreviewData.threadID, mailbox: box)
    }

    private let created = HTTPResponse(status: 201, data: Data(#"{"message":{"id":"r1","thread_id":"11111111-1111-4111-8111-111111111111"},"thread_id":"11111111-1111-4111-8111-111111111111"}"#.utf8))

    func testAReplyThatWentThroughIsSentEvenIfTheThreadCannotBeReadAfterwards() async throws {
        let sends = Tally()
        let model = model(reply: created, refreshFails: true, sent: MailReplySent(), sends: sends)
        await model.load()
        XCTAssertEqual(model.phase, .loaded)
        try await model.reply("Thanks, that works.")
        XCTAssertEqual(sends.count, 1)
        XCTAssertFalse(model.isSending, "the button is free again, and the screen clears the draft")
    }

    func testAReplyWhoseAnswerIsNotReadableIsStillSent() async throws {
        let sends = Tally()
        let odd = HTTPResponse(status: 201, data: Data(#"{"ok":true}"#.utf8))
        let model = model(reply: odd, refreshFails: false, sent: MailReplySent(), sends: sends)
        await model.load()
        try await model.reply("Thanks.")
        XCTAssertEqual(sends.count, 1)
    }

    func testAReplyTheServerRefusesStillThrowsSoTheDraftStaysForAnotherTry() async throws {
        let sends = Tally()
        let refused = HTTPResponse(status: 403, data: Data(#"{"error":"missing_scope: This key cannot send mail.","code":"missing_scope"}"#.utf8))
        let model = model(reply: refused, refreshFails: false, sent: MailReplySent(), sends: sends)
        await model.load()
        do {
            try await model.reply("Thanks.")
            XCTFail("a refused reply is not a sent one")
        } catch {
            XCTAssertEqual(MailModel.sentence(error), "This key cannot send mail.")
        }
        XCTAssertFalse(model.isSending)
    }
}

/// A network that is never there: every request fails the way a phone with no signal does.
private struct MailOfflineTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        throw URLError(.notConnectedToInternet)
    }
}

// MARK: Truth review

@MainActor
final class TruthReviewModelTests: XCTestCase {
    private func model(_ routes: [MockRoute]) -> TruthReviewModel {
        TruthReviewModel(client: AppEnvironment.preview(routes: routes).client)
    }

    func testTheDeckOpensOnTheFirstCardOfAHostedLedger() async throws {
        let model = model(TruthPreviewData.reviewRoutes)
        await model.start(preferring: nil)
        XCTAssertEqual(model.ledger?.slug, "team")
        XCTAssertTrue(model.isHosted)
        XCTAssertEqual(model.handle, "johnnyclem")
        XCTAssertEqual(model.rooms.map(\.title), ["Ops room"])
        XCTAssertEqual(model.deck.current?.kind, .uv)
        XCTAssertEqual(model.deck.total, 3)
    }

    func testADecisionTakesTheCardOffTheDeckAndSaysWhatHappened() async throws {
        let sent = Tally()
        let route = MockRoute(.post, "/api/truth/review/01M1E6JK81TR57BA191BG8Y0Q3") { request in
            _ = sent.record(request)
            return HTTPResponse(status: 201, data: Data(#"{"id":"x","action":"approve","status":"approved","approvals":{"missing":["a second approver"]}}"#.utf8))
        }
        let model = model([route] + TruthPreviewData.reviewRoutes)
        await model.start(preferring: nil)
        let item = try XCTUnwrap(model.deck.current)
        let outcome = try await model.decide(.approve, item: item, draft: TruthDecisionDraft())
        XCTAssertEqual(outcome.sentence, "Your approval is on the record. Still needs a second approver.")
        XCTAssertNotEqual(model.deck.current?.id, item.id)
        XCTAssertEqual(sent.count, 1)
        let body = try HVCoding.decoder(.verbatim).decode(JSONValue.self, from: try XCTUnwrap(sent.allBodies.first))
        XCTAssertEqual(body["action"], "approve")
        XCTAssertEqual(body["ledger"], "team")
    }

    func testAnAppealGoesToTheContestingUV() async throws {
        let sent = Tally()
        let route = MockRoute(.post, "/api/truth/review/01M1E6JK82QWPK6VS437JKMJPZ") { request in
            _ = sent.record(request)
            return HTTPResponse(status: 201, data: Data(#"{"id":"x","action":"strike","status":"struck"}"#.utf8))
        }
        let model = model([route] + TruthPreviewData.reviewRoutes)
        await model.start(preferring: nil)
        let appeal = try XCTUnwrap(model.deck.items.first { $0.kind == .appeal })
        var draft = TruthDecisionDraft()
        draft.opinion = "Nonsense."
        _ = try await model.decide(.strike, item: appeal, draft: draft)
        XCTAssertEqual(sent.count, 1)
    }

    func testAMissingHandleIsAskedForThenTheDecisionGoesThrough() async throws {
        let attempts = Tally()
        let refuse = MockRoute(.post, "/api/truth/review/01M1E6JK81TR57BA191BG8Y0Q3") { request in
            if attempts.record(request) == 1 {
                return HTTPResponse(status: 409, data: Data(#"{"error":"Choose your truth handle first","handle_required":true}"#.utf8))
            }
            return HTTPResponse(status: 201, data: Data(#"{"id":"x","action":"approve","status":"promoted"}"#.utf8))
        }
        let routes = [refuse, .json(.put, "/api/truth/handle", #"{"handle":"johnny"}"#, status: 201)] + TruthPreviewData.reviewRoutes
        let model = model(routes)
        await model.start(preferring: nil)
        let item = try XCTUnwrap(model.deck.current)
        do {
            _ = try await model.decide(.approve, item: item, draft: TruthDecisionDraft())
            XCTFail("expected the handle to be asked for")
        } catch {
            XCTAssertEqual((error as? HVError)?.isTruthHandleRequired, true)
        }
        XCTAssertNil(model.handle)
        XCTAssertEqual(model.deck.current?.id, item.id, "nothing was decided")
        try await model.saveHandle("johnny")
        XCTAssertEqual(model.handle, "johnny")
        let outcome = try await model.decide(.approve, item: item, draft: TruthDecisionDraft())
        XCTAssertEqual(outcome.status, "promoted")
    }

    func testTryAgainAfterTheLedgersFailedToLoadLoadsThem() async throws {
        let asked = Tally()
        let flaky = MockRoute(.get, "/api/truth/ledgers") { request in
            if asked.record(request) == 1 {
                return HTTPResponse(status: 500, data: Data(#"{"error":"The server had a problem. Try again in a moment."}"#.utf8))
            }
            return HTTPResponse(status: 200, data: Data(TruthPreviewData.ledgers.utf8))
        }
        let model = model([flaky] + TruthPreviewData.reviewRoutes)
        await model.start(preferring: nil)
        XCTAssertEqual(model.phase, .failed("The server had a problem. Try again in a moment."))
        XCTAssertNil(model.ledger)

        await model.retry(preferring: nil)
        XCTAssertEqual(asked.count, 2, "the ledgers were asked for again")
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.ledger?.slug, "team")
        XCTAssertEqual(model.deck.total, 3)
    }

    func testTheScreenComingBackAfterAFailedFirstLoadStartsAgain() async throws {
        let asked = Tally()
        let flaky = MockRoute(.get, "/api/truth/ledgers") { request in
            if asked.record(request) == 1 { return HTTPResponse(status: 500, data: Data(#"{"error":"Try again."}"#.utf8)) }
            return HTTPResponse(status: 200, data: Data(TruthPreviewData.ledgers.utf8))
        }
        let model = model([flaky] + TruthPreviewData.reviewRoutes)
        await model.start(preferring: nil)
        await model.start(preferring: nil)
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.ledger?.slug, "team")
    }

    func testTryAgainAfterTheDeckFailedReloadsTheDeckOnly() async throws {
        let asked = Tally()
        let flaky = MockRoute(.get, "/api/truth/review") { request in
            if asked.record(request) == 1 { return HTTPResponse(status: 500, data: Data(#"{"error":"Something broke."}"#.utf8)) }
            return HTTPResponse(status: 200, data: Data(TruthPreviewData.docket.utf8))
        }
        let model = model([flaky] + TruthPreviewData.reviewRoutes)
        await model.start(preferring: nil)
        XCTAssertEqual(model.phase, .failed("Something broke."))
        XCTAssertNotNil(model.ledger)
        await model.retry(preferring: nil)
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.deck.total, 3)
    }

    func testAMirrorLedgerOffersNothingToDecide() async throws {
        let model = model(TruthPreviewData.reviewRoutes)
        await model.start(preferring: "default")
        XCTAssertFalse(model.isHosted)
        let item = try XCTUnwrap(model.deck.current)
        XCTAssertFalse(model.state(of: .approve, for: item).isAvailable)
    }
}
