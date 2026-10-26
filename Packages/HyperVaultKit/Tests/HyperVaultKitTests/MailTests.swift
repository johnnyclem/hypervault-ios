import XCTest
@testable import HyperVaultKit

/// Fixtures are rows as the owner's mail routes answer them (components/mail/__tests__/support.ts
/// in the web app, shaped by lib/mail/project.ts).
final class MailTests: XCTestCase {
    let base = URL(string: "https://hv.test")!
    let boxA = "0000000a-0000-4000-8000-00000000000a"
    let thread = "11111111-1111-4111-8111-111111111111"

    func client(_ transport: MockTransport) -> HVClient {
        HVClient(baseURL: base, transport: transport, tokens: StaticTokenProvider(), retry: .none, sleep: { _ in })
    }

    func message(
        _ id: String, thread: String = "11111111-1111-4111-8111-111111111111", subject: String = "Weekly plan",
        unread: Bool = false, author: String = #"{"type":"key","name":"Claude Code","key_id":"22222222-2222-4222-8222-222222222222"}"#,
        folder: String = "inbox", text: String? = nil, created: String = "2026-10-09T12:00:00.123456+00:00", extra: String = ""
    ) -> String {
        let body = text.map { #","in_reply_to":null,"text":"\#($0)","attachments":[]"# } ?? ""
        return """
        {"id":"\(id)","thread_id":"\(thread)","folder":"\(folder)","from":"ana@vault.cool","to":["owner"],"cc":[],
         "subject":"\(subject)","unread":\(unread),"labels":["from-agent"],"created_at":"\(created)",
         "attachment_count":0,"author":\(author),"agent_visible":true,"message_id":"<\(id)@vault.cool>"\(body)\(extra)}
        """
    }

    // MARK: Decoding

    func testMailboxListPutsThePrimaryFirst() throws {
        let json = """
        {"mailboxes":[
          {"id":"b2","claim_id":"c2","address":"ana-two@vault.cool","is_primary":false,"unread_count":0,"held_count":0,"agents_see_owner_mail":true},
          {"id":"b1","claim_id":"c1","address":"ana@vault.cool","is_primary":true,"unread_count":3,"held_count":1,"agents_see_owner_mail":false}]}
        """
        let list = try HVCoding.decoder().decode(OwnerMailboxList.self, from: Data(json.utf8))
        XCTAssertEqual(list.mailboxes.map(\.id), ["b1", "b2"])
        XCTAssertEqual(list.mailboxes[0].claimId, "c1")
        XCTAssertEqual(list.mailboxes[0].unreadCount, 3)
        XCTAssertFalse(list.mailboxes[0].agentsSeeOwnerMail)
        XCTAssertEqual(list.totalUnread, 3)
    }

    func testAnInternalBoxHasNoAddress() throws {
        let json = #"{"mailboxes":[{"id":"b","claim_id":null,"address":null,"is_primary":true,"unread_count":0,"held_count":0,"agents_see_owner_mail":true}]}"#
        let list = try HVCoding.decoder().decode(OwnerMailboxList.self, from: Data(json.utf8))
        XCTAssertNil(list.mailboxes[0].address)
        XCTAssertEqual(list.mailboxes[0].displayAddress, "No address yet")
        XCTAssertEqual(OwnerMailbox.choose(from: list.mailboxes, preferring: nil)?.id, "b")
    }

    func testChoosingAMailbox() {
        let a = OwnerMailbox(id: "a", address: nil)
        let b = OwnerMailbox(id: "b", address: "b@vault.cool")
        let c = OwnerMailbox(id: "c", address: "c@vault.cool")
        XCTAssertEqual(OwnerMailbox.choose(from: [a, b, c], preferring: "c")?.id, "c")
        XCTAssertEqual(OwnerMailbox.choose(from: [a, b, c], preferring: "gone")?.id, "b")
        XCTAssertEqual(OwnerMailbox.choose(from: [a], preferring: nil)?.id, "a")
        XCTAssertNil(OwnerMailbox.choose(from: [], preferring: nil))
    }

    func testAListPageDecodes() throws {
        let json = #"{"box":"inbox","messages":[\#(message("m1", unread: true)),\#(message("m2", folder: "archive"))],"next_cursor":"2026-10-09T12:00:00.123456Z|00000000-0000-4000-8000-000000000002"}"#
        let page = try HVCoding.decoder().decode(MailMessagePage.self, from: Data(json.utf8))
        XCTAssertEqual(page.box, .inbox)
        XCTAssertEqual(page.messages.count, 2)
        XCTAssertTrue(page.messages[0].unread)
        XCTAssertEqual(page.messages[1].folder, .archive)
        XCTAssertEqual(page.messages[0].threadId, thread)
        XCTAssertEqual(page.messages[0].author.label, "Claude Code")
        XCTAssertTrue(page.messages[0].author.isAgent)
        XCTAssertNotNil(page.messages[0].createdAt)
        XCTAssertNotNil(page.nextCursor)
        XCTAssertNil(page.messages[0].text)
    }

    func testAThreadPageHasBodiesAndAttachments() throws {
        let attachments = #","attachments":[{"id":"a1","filename":"Plan","content_type":"text/html","bytes":0,"href":"/a/plan-x7k2p9"},{"id":"a2","filename":"Old draft","content_type":"","bytes":0,"href":null}]"#
        var one = message("m1", text: "Here is the plan.")
        one = one.replacingOccurrences(of: #","attachments":[]"#, with: attachments)
        let json = #"{"messages":[\#(one)],"next_cursor":null}"#
        let page = try HVCoding.decoder().decode(MailMessagePage.self, from: Data(json.utf8))
        XCTAssertNil(page.box)
        XCTAssertNil(page.nextCursor)
        let m = page.messages[0]
        XCTAssertEqual(m.text, "Here is the plan.")
        XCTAssertEqual(m.attachments.count, 2)
        XCTAssertEqual(m.attachments[0].slug, "plan-x7k2p9")
        XCTAssertNil(m.attachments[1].slug)
    }

    func testTheOwnersOwnNoteIsYouAndNotAnAgent() throws {
        let json = message("m3", author: #"{"type":"owner","name":"","key_id":null}"#, extra: #","agent_visible":false"#)
            .replacingOccurrences(of: #""agent_visible":true,"#, with: "")
        let m = try HVCoding.decoder().decode(MailMessage.self, from: Data(json.utf8))
        XCTAssertEqual(m.author.label, "You")
        XCTAssertFalse(m.author.isAgent)
        XCTAssertTrue(m.isHiddenFromAgents)
    }

    func testAnAgentThatCallsItselfYouStillReadsAsAnAgent() throws {
        let m = try HVCoding.decoder().decode(MailMessage.self, from: Data(message("m4", author: #"{"type":"key","name":"You","key_id":"k"}"#).utf8))
        XCTAssertEqual(m.author.label, "You")
        XCTAssertTrue(m.author.isAgent)
        let system = MailAuthor(type: .key, name: "System")
        XCTAssertTrue(system.isAgent)
    }

    func testAnUnknownAuthorTypeReadsAsAnAgentAndAMissingNameAsAnAgent() throws {
        let m = try HVCoding.decoder().decode(MailMessage.self, from: Data(message("m5", author: #"{"type":"carrier-pigeon","name":"  "}"#).utf8))
        XCTAssertEqual(m.author.type, .key)
        XCTAssertEqual(m.author.label, "An agent")
    }

    func testARowWithMissingFieldsStillDecodes() throws {
        let m = try HVCoding.decoder().decode(MailMessage.self, from: Data(#"{"id":"x"}"#.utf8))
        XCTAssertEqual(m.threadId, "x")
        XCTAssertEqual(m.folder, .inbox)
        XCTAssertEqual(m.displaySubject, "(no subject)")
    }

    func testSearchHitsCarryASnippet() throws {
        let json = #"{"query":"plan","messages":[\#(message("m1", extra: #","snippet":"…the plan for the week…""#))]}"#
        let result = try HVCoding.decoder().decode(MailSearchResult.self, from: Data(json.utf8))
        XCTAssertEqual(result.query, "plan")
        XCTAssertEqual(result.messages[0].snippet, "…the plan for the week…")
    }

    func testHeldPage() throws {
        let json = #"{"count":1,"messages":[\#(message("h1", text: "From elsewhere"))],"next_cursor":null}"#
        let held = try HVCoding.decoder().decode(MailHeldPage.self, from: Data(json.utf8))
        XCTAssertEqual(held.count, 1)
        XCTAssertEqual(held.messages[0].text, "From elsewhere")
    }

    func testTheSummaryOfAnOwnersMailbox() throws {
        let json = #"{"address":"ana@vault.cool","unread_count":2,"held_count":0,"latest":[\#(message("m1", unread: true))],"mailbox_id":"b1","agents_see_owner_mail":true}"#
        let summary = try HVCoding.decoder().decode(MailboxSummary.self, from: Data(json.utf8))
        XCTAssertEqual(summary.unreadCount, 2)
        XCTAssertEqual(summary.mailboxId, "b1")
        XCTAssertEqual(summary.latest.count, 1)
    }

    func testTheCacheRoundTrips() throws {
        let page = try HVCoding.decoder().decode(MailMessagePage.self, from: Data(#"{"box":"inbox","messages":[\#(message("m1", unread: true, text: "Body"))],"next_cursor":"c"}"#.utf8))
        let data = try HVCoding.encoder(.verbatim).encode(page)
        let back = try HVCoding.decoder(.verbatim).decode(MailMessagePage.self, from: data)
        XCTAssertEqual(back, page)
        let list = OwnerMailboxList(mailboxes: [OwnerMailbox(id: "a", claimId: "c", address: "a@vault.cool", isPrimary: true, unreadCount: 2)])
        let listBack = try HVCoding.decoder(.verbatim).decode(OwnerMailboxList.self, from: try HVCoding.encoder(.verbatim).encode(list))
        XCTAssertEqual(listBack, list)
    }

    // MARK: Words and threads

    func testThreadSubject() {
        XCTAssertEqual(MailText.threadSubject("Re: Weekly plan"), "Weekly plan")
        XCTAssertEqual(MailText.threadSubject("Re: Re: RE: Weekly plan"), "Weekly plan")
        XCTAssertEqual(MailText.threadSubject("  re:   "), "(no subject)")
        XCTAssertEqual(MailText.threadSubject(""), "(no subject)")
        XCTAssertEqual(MailText.threadSubject("Reply from Ana"), "Reply from Ana")
    }

    func testPlainSentenceDropsTheLeadingCode() {
        XCTAssertEqual(
            MailText.plainSentence(#"missing_scope: This key can read mail but not send it."#, code: "missing_scope"),
            "This key can read mail but not send it."
        )
        XCTAssertEqual(MailText.plainSentence("Not found.", code: "not_found"), "Not found.")
        XCTAssertEqual(MailText.plainSentence("not_found: ", code: "not_found"), "not_found:")
    }

    func testGroupingKeepsTheOrderOfNewestMessages() throws {
        func m(_ id: String, _ thread: String, unread: Bool = false) -> MailMessage {
            MailMessage(id: id, threadId: thread, unread: unread, author: MailAuthor(type: .key, name: "A"))
        }
        let threads = MailThreads.group([m("1", "t1"), m("2", "t2", unread: true), m("3", "t1"), m("4", "t3")])
        XCTAssertEqual(threads.map(\.id), ["t1", "t2", "t3"])
        XCTAssertEqual(threads[0].messages.map(\.id), ["1", "3"])
        XCTAssertEqual(threads[0].newest.id, "1")
        XCTAssertFalse(threads[0].unread)
        XCTAssertTrue(threads[1].unread)
    }

    func testAppendUniqueAndMergeNewest() {
        func m(_ id: String, unread: Bool = false) -> MailMessage {
            MailMessage(id: id, threadId: "t", unread: unread, author: MailAuthor(type: .key))
        }
        XCTAssertEqual(MailThreads.appendUnique([m("1"), m("2")], [m("2"), m("3")]).map(\.id), ["1", "2", "3"])
        let merged = MailThreads.mergeNewest([m("1", unread: true), m("2")], [m("1", unread: false), m("5")])
        XCTAssertEqual(merged.map(\.id), ["1", "2", "5"])
        XCTAssertFalse(merged[0].unread)
    }

    func testReplyHiddenFollowsTheSwitchAndTheParent() {
        let visible = MailMessage(id: "1", threadId: "t", author: MailAuthor(type: .key), agentVisible: true)
        let hidden = MailMessage(id: "2", threadId: "t", author: MailAuthor(type: .owner), agentVisible: false)
        XCTAssertFalse(MailText.replyIsHidden(newest: visible, agentsSeeOwnerMail: true))
        XCTAssertTrue(MailText.replyIsHidden(newest: visible, agentsSeeOwnerMail: false))
        XCTAssertTrue(MailText.replyIsHidden(newest: hidden, agentsSeeOwnerMail: true))
        XCTAssertTrue(MailText.replyIsHidden(newest: nil, agentsSeeOwnerMail: false))
    }

    func testExportFilename() {
        XCTAssertEqual(MailText.exportFilename(address: "ana@vault.cool"), "mail-ana-vault.cool.json")
        XCTAssertEqual(MailText.exportFilename(address: nil), "mail-mailbox.json")
    }

    func testAttachmentLinksAreOnlyTheAppsOwn() {
        func slug(_ href: String?) -> String? { MailAttachment(id: "a", filename: "f", href: href).slug }
        XCTAssertEqual(slug("/a/notes-x7k2p9"), "notes-x7k2p9")
        XCTAssertNil(slug("https://evil.example/a/notes"))
        XCTAssertNil(slug("/a/"))
        XCTAssertNil(slug("/a//x"))
        XCTAssertNil(slug("/a/x y"))
        XCTAssertNil(slug("/a/x?y=1"))
        XCTAssertNil(slug(nil))
    }

    func testFilters() {
        XCTAssertEqual(MailFilter.unread.box, .inbox)
        XCTAssertTrue(MailFilter.unread.unreadOnly)
        XCTAssertFalse(MailFilter.inbox.unreadOnly)
        XCTAssertEqual(MailFilter.allCases.map(\.title), ["Inbox", "Unread", "Sent", "Archive", "Trash"])
    }

    // MARK: Moving a thread

    func testMovePlan() {
        func m(_ id: String, _ folder: MailFolder) -> MailMessage {
            MailMessage(id: id, threadId: "t", folder: folder, author: MailAuthor(type: .key))
        }
        XCTAssertEqual(MailMovePlan.make(messages: [m("1", .inbox), m("2", .archive)], to: .archive), .move(["1"]))
        XCTAssertEqual(MailMovePlan.make(messages: [m("1", .archive)], to: .archive), .nothing)
        XCTAssertEqual(MailMovePlan.make(messages: [m("1", .inbox), m("2", .inbox)], to: .trash, cap: 1), .tooMany(cap: 1))
        XCTAssertNotNil(MailMovePlan.tooMany(cap: 500).tooManySentence)
    }

    // MARK: Endpoints

    func testListEndpointsAskForTheRightBox() async throws {
        let transport = MockTransport(routes: [.json(.get, "/api/mail/messages", #"{"box":"inbox","messages":[],"next_cursor":null}"#)])
        let api = client(transport)
        _ = try await api.send(.mailMessages(box: .inbox, unreadOnly: true, mailbox: boxA, limit: 50, cursor: "c|u"))
        _ = try await api.send(.mailThread(threadId: thread, mailbox: boxA))
        let sent = await transport.requests
        let first = try XCTUnwrap(sent[0].url?.query)
        XCTAssertTrue(first.contains("box=inbox"))
        XCTAssertTrue(first.contains("unread=1"))
        XCTAssertTrue(first.contains("limit=50"))
        XCTAssertTrue(first.contains("mailbox=\(boxA)"))
        XCTAssertTrue(first.contains("cursor=c%7Cu") || first.contains("cursor=c|u"))
        let second = try XCTUnwrap(sent[1].url?.query)
        XCTAssertTrue(second.contains("thread_id=\(thread)"))
        XCTAssertTrue(second.contains("limit=20"))
        let names = URLComponents(string: "https://x/?\(second)")?.queryItems?.map(\.name) ?? []
        XCTAssertFalse(names.contains("box"))
    }

    func testReadingWithoutMarkingAsRead() async throws {
        let transport = MockTransport(routes: [.json(.get, "/api/mail/messages/m1", #"{"message":\#(message("m1", text: "Hi"))}"#)])
        let api = client(transport)
        let read = try await api.send(.mailMessage(id: "m1", markRead: false))
        XCTAssertEqual(read.message.text, "Hi")
        let requests = await transport.requests
        XCTAssertEqual(requests[0].url?.query, "mark_read=false")
    }

    func testTheOwnersNoteGoesToSelf() async throws {
        let transport = MockTransport(routes: [.json(.post, "/api/mail/messages", #"{"message":\#(message("n1")),"thread_id":"\#(thread)"}"#, status: 201)])
        let api = client(transport)
        let sent = try await api.send(.mailSend(subject: "  Lunch  ", text: "Pick up the keys", mailbox: boxA))
        XCTAssertEqual(sent.threadId, thread)
        let request = await transport.requests[0]
        let body = try XCTUnwrap(request.httpBody)
        let json = try HVCoding.decoder(.verbatim).decode(JSONValue.self, from: body)
        XCTAssertEqual(json["to"], ["self"])
        XCTAssertEqual(json["subject"], "Lunch")
        XCTAssertEqual(json["text"], "Pick up the keys")
        XCTAssertNil(json["attachments"])
        XCTAssertEqual(request.httpMethod, "POST")
    }

    func testReplyAndUpdateBodies() async throws {
        let transport = MockTransport(routes: [
            .json(.post, "/api/mail/messages/m1/reply", #"{"message":\#(message("r1")),"thread_id":"\#(thread)"}"#, status: 201),
            .json(.patch, "/api/mail/messages/m1", #"{"message":\#(message("m1", folder: "trash"))}"#),
        ])
        let api = client(transport)
        _ = try await api.send(.mailReply(id: "m1", text: "On my way"))
        let moved = try await api.send(.mailUpdate(id: "m1", folder: .trash, unread: false))
        XCTAssertEqual(moved.message.folder, .trash)
        let requests = await transport.requests
        let reply = try HVCoding.decoder(.verbatim).decode(JSONValue.self, from: try XCTUnwrap(requests[0].httpBody))
        XCTAssertEqual(reply["text"], "On my way")
        XCTAssertNil(reply["to"])
        let patch = try HVCoding.decoder(.verbatim).decode(JSONValue.self, from: try XCTUnwrap(requests[1].httpBody))
        XCTAssertEqual(patch["folder"], "trash")
        XCTAssertEqual(patch["unread"], false)
    }

    func testTheSwitchBody() async throws {
        let box = #"{"mailbox":{"id":"b1","claim_id":"c1","address":"ana@vault.cool","is_primary":true,"unread_count":0,"held_count":0,"agents_see_owner_mail":false}}"#
        let transport = MockTransport(routes: [.json(.patch, "/api/mail/owner", box)])
        let updated = try await client(transport).send(.mailAgentsSeeReplies(false, mailbox: "b1"))
        XCTAssertFalse(updated.mailbox.agentsSeeOwnerMail)
        let requests = await transport.requests
        let body = try HVCoding.decoder(.verbatim).decode(JSONValue.self, from: try XCTUnwrap(requests[0].httpBody))
        XCTAssertEqual(body["agents_see_owner_mail"], false)
        XCTAssertEqual(body["mailbox"], "b1")
    }

    func testEmptyingTrashAndReleasingHeld() async throws {
        let transport = MockTransport(routes: [
            .json(.delete, "/api/mail/owner/trash", #"{"deleted":4}"#),
            .json(.post, "/api/mail/owner/held/h1/release", #"{"message":\#(message("h1"))}"#),
        ])
        let api = client(transport)
        let emptied = try await api.send(.mailEmptyTrash(mailbox: boxA))
        let released = try await api.send(.mailRelease(id: "h1"))
        XCTAssertEqual(emptied.deleted, 4)
        XCTAssertEqual(released.message.id, "h1")
    }

    func testSearchAsksForAPhrase() async throws {
        let transport = MockTransport(routes: [.json(.get, "/api/mail/search", #"{"query":"road trip","messages":[]}"#)])
        _ = try await client(transport).send(.mailSearch(query: "road trip", box: .archive, mailbox: boxA))
        let requests = await transport.requests
        let query = try XCTUnwrap(requests[0].url?.query)
        XCTAssertTrue(query.contains("q=road%20trip") || query.contains("q=road+trip"))
        XCTAssertTrue(query.contains("box=archive"))
    }

    // MARK: Failures

    func testUnavailableMailKeepsTheServersSentence() async {
        let sentence = "Agent Mail is not set up on this server yet: run supabase/migrations/20261009000000_0047_agent_mail.sql."
        let transport = MockTransport(routes: [.json(.get, "/api/mail/owner/mailboxes", #"{"error":"mail_unavailable: \#(sentence)","code":"mail_unavailable"}"#, status: 503)])
        do {
            _ = try await client(transport).send(.mailMailboxes)
            XCTFail("expected a failure")
        } catch let error as HVError {
            XCTAssertTrue(error.isMailUnavailable)
            XCTAssertEqual(error.mailSentence, sentence)
        } catch {
            XCTFail("\(error)")
        }
    }

    func testAnOwnerOnlyRouteSaysNotFoundKindly() async {
        let transport = MockTransport(routes: [.json(.get, "/api/mail/owner/held", #"{"error":"not_found: Not found.","code":"not_found"}"#, status: 404)])
        do {
            _ = try await client(transport).send(.mailHeld())
            XCTFail("expected a failure")
        } catch let error as HVError {
            XCTAssertTrue(error.isNotFound)
            XCTAssertEqual(error.mailSentence, "Not found.")
        } catch {
            XCTFail("\(error)")
        }
    }

    // MARK: Whole-thread actions

    func testMovingAThreadReadsOlderPagesThenMovesWhatIsElsewhere() async throws {
        let older = #"{"messages":[\#(message("a", folder: "archive")),\#(message("b", folder: "inbox"))],"next_cursor":null}"#
        let transport = MockTransport(routes: [
            MockRoute(.get, "/api/mail/messages") { request in
                let ok = request.url?.query?.contains("cursor=older") == true
                return HTTPResponse(status: ok ? 200 : 400, data: Data(older.utf8))
            },
            .json(.patch, "/api/mail/messages/*", #"{"message":\#(message("x", folder: "archive"))}"#),
        ])
        let service = MailService(client: client(transport))
        let loaded = [MailMessage(id: "c", threadId: thread, folder: .inbox, author: MailAuthor(type: .key))]
        let result = try await service.moveThread(id: thread, mailbox: boxA, loaded: loaded, olderCursor: "older", to: .archive)
        XCTAssertEqual(result, .moved(2))
        let patched = await transport.requests.filter { $0.httpMethod == "PATCH" }.compactMap { $0.url?.path }
        XCTAssertEqual(Set(patched), ["/api/mail/messages/b", "/api/mail/messages/c"])
    }

    func testMovingAThreadThatIsAlreadyThereDoesNothing() async throws {
        let transport = MockTransport()
        let service = MailService(client: client(transport))
        let loaded = [MailMessage(id: "c", threadId: thread, folder: .archive, author: MailAuthor(type: .key))]
        let result = try await service.moveThread(id: thread, mailbox: nil, loaded: loaded, olderCursor: nil, to: .archive)
        XCTAssertEqual(result, .nothing)
        let count = await transport.requests.count
        XCTAssertEqual(count, 0)
    }

    func testAMoveThatFailsThrowsTheServersSentence() async {
        let transport = MockTransport(routes: [.json(.patch, "/api/mail/messages/*", #"{"error":"claim_released: Pick an address first.","code":"claim_released"}"#, status: 409)])
        let service = MailService(client: client(transport))
        let loaded = [MailMessage(id: "c", threadId: thread, folder: .inbox, author: MailAuthor(type: .key))]
        do {
            _ = try await service.moveThread(id: thread, mailbox: nil, loaded: loaded, olderCursor: nil, to: .trash)
            XCTFail("expected a failure")
        } catch let error as HVError {
            XCTAssertEqual(error.mailSentence, "Pick an address first.")
        } catch {
            XCTFail("\(error)")
        }
    }

    func testMarkReadReturnsOnlyWhatTheServerAccepted() async {
        let transport = MockTransport(routes: [
            MockRoute(.patch, "/api/mail/messages/*") { request in
                let path = request.url?.path ?? ""
                return path.hasSuffix("/bad")
                    ? HTTPResponse(status: 404, data: Data(#"{"error":"No such message."}"#.utf8))
                    : HTTPResponse(status: 200, data: Data(#"{"message":{"id":"x"}}"#.utf8))
            },
        ])
        let cleared = await MailService(client: client(transport)).markRead(["a", "bad", "c"], mailbox: nil)
        XCTAssertEqual(cleared, ["a", "c"])
    }
}
