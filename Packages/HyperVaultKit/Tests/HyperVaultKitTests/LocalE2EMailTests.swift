import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

// Agent Mail as the owner sees it: the mailbox, notes to the agents' side, what agents send back, threads,
// search, folders, held mail and the export.

final class LocalE2EMailTests: LocalE2ECase {

    /// A person with a mailbox, an agent key that may send, and that key as a client.
    private func setUp(_ index: Int) async throws -> (api: HVClient, token: String, mailbox: OwnerMailbox, agent: HVClient, agentKeyID: String) {
        let (api, token) = member(index)
        // The account's own mailbox is made by the first read of its mail (the list of mailboxes never creates it).
        _ = try await send(.mailSummary(), api)
        let mailboxes = try await send(.mailMailboxes, api)
        let mailbox = try XCTUnwrap(mailboxes.mailboxes.first, "no mailbox was provisioned")
        let key = try await send(.createAgentKey(name: unique("mail agent"), canSendMail: true), api)
        return (api, token, mailbox, client(key.key), key.prefix)
    }

    /// What the app's first visit to Mail does on an account that has never had any mail: it asks for the
    /// mailboxes, then for the messages. The first answers with none; asking for the messages makes the box.
    func testAFirstVisitFindsNoMailboxUntilTheMessagesAreAsked() async throws {
        let fresh = try await freshMember("mailnew")
        let before = try await send(.mailMailboxes, fresh.client)
        XCTAssertTrue(before.mailboxes.isEmpty, "the list of mailboxes is not meant to create the account's own box")
        let page = try await send(.mailMessages(box: .inbox), fresh.client)
        XCTAssertTrue(page.messages.isEmpty)
        let after = try await send(.mailMailboxes, fresh.client)
        XCTAssertEqual(after.mailboxes.count, 1, "reading the messages should have made the account's box")
        XCTAssertTrue(after.mailboxes[0].isPrimary)
    }

    func testTheMailboxIsProvisionedAndSummarised() async throws {
        let (api, _) = member(20)
        _ = try await send(.mailSummary(), api)
        let (list, raw) = try await fetch(.mailMailboxes, api)
        XCTAssertEqual(list.mailboxes.count, rawCount(raw, "mailboxes"))
        let box = try XCTUnwrap(list.mailboxes.first)
        XCTAssertTrue(box.isPrimary)
        XCTAssertNil(box.claimId, "the account's own mailbox has no claimed address behind it")
        XCTAssertFalse(box.id.isEmpty)
        XCTAssertTrue(box.agentsSeeOwnerMail)
        XCTAssertEqual(box.displayAddress.isEmpty, false)

        let (summary, summaryRaw) = try await fetch(.mailSummary(), api)
        XCTAssertEqual(summary.unreadCount, summaryRaw["unread_count"]?.int)
        XCTAssertEqual(summary.heldCount, summaryRaw["held_count"]?.int)
        XCTAssertEqual(summary.latest.count, rawCount(summaryRaw, "latest"))
        XCTAssertEqual(summary.mailboxId, box.id)
        let named = try await send(.mailSummary(mailbox: box.id), api)
        XCTAssertEqual(named.mailboxId, box.id)
        await expectFailure(404, .mailSummary(mailbox: "00000000-0000-4000-8000-000000000000"), api)
    }

    func testNotesToTheAgentsAndWhatAgentsSendBack() async throws {
        let s = try await setUp(20)
        let word = uniqueWord()

        // A note to the agents' side: in Sent, hidden from agents unless the person lets them see.
        let note = try await send(.mailSend(to: .selfNote, subject: "Note \(word)", text: "Remember \(word) for the trip."), s.api)
        XCTAssertEqual(note.message.subject, "Note \(word)")
        XCTAssertEqual(note.message.author.type, .owner)
        XCTAssertEqual(note.message.author.label, "You")
        XCTAssertEqual(note.message.threadId, note.threadId)
        XCTAssertNotNil(note.message.createdAt)
        let sent = try await send(.mailMessages(box: .sent), s.api)
        XCTAssertTrue(sent.messages.contains { $0.id == note.message.id }, "the note is not in Sent")

        // An agent with the send scope writes to the person.
        let reply = try await send(Endpoint<MailSent>(.post, "/api/mail/messages", body: .jsonValue([
            "to": ["owner"], "subject": .string("Found \(word)"), "text": .string("I found \(word) at the market."), "agent_name": "Scout",
        ])), s.agent)
        XCTAssertEqual(reply.message.author.type, .key)
        XCTAssertEqual(reply.message.author.name, "Scout")
        XCTAssertTrue(reply.message.author.isAgent)

        // The inbox shows it unread; the summary counts it.
        let (inbox, inboxRaw) = try await fetch(.mailMessages(box: .inbox), s.api)
        XCTAssertEqual(inbox.messages.count, rawCount(inboxRaw, "messages"))
        let row = try XCTUnwrap(inbox.messages.first { $0.id == reply.message.id }, "the agent's message is not in the inbox")
        XCTAssertTrue(row.unread)
        XCTAssertEqual(row.subject, "Found \(word)")
        XCTAssertEqual(row.folder, .inbox)
        let unreadOnly = try await send(.mailMessages(box: .inbox, unreadOnly: true), s.api)
        XCTAssertTrue(unreadOnly.messages.allSatisfy(\.unread))
        XCTAssertTrue(unreadOnly.messages.contains { $0.id == reply.message.id })
        let summary = try await send(.mailSummary(mailbox: s.mailbox.id), s.api)
        XCTAssertGreaterThanOrEqual(summary.unreadCount, 1)

        // Reading one clears the unread bit unless asked not to.
        let peek = try await send(.mailMessage(id: reply.message.id, markRead: false), s.api)
        XCTAssertTrue(peek.message.unread)
        XCTAssertTrue(peek.message.text?.contains("market") ?? false, "a message read in full carries its body")
        let opened = try await send(.mailMessage(id: reply.message.id), s.api)
        XCTAssertEqual(opened.message.id, reply.message.id)
        let afterRead = try await send(.mailMessage(id: reply.message.id, markRead: false), s.api)
        XCTAssertFalse(afterRead.message.unread, "reading did not clear the unread bit")
        let flipped = try await send(.mailUpdate(id: reply.message.id, unread: true), s.api)
        XCTAssertTrue(flipped.message.unread)

        // Search finds it by a word in the body, in the inbox and not in the trash.
        let found = try await send(.mailSearch(query: word), s.api)
        XCTAssertTrue(found.messages.contains { $0.id == reply.message.id }, "search missed the message")
        XCTAssertEqual(found.query, word)
        let none = try await send(.mailSearch(query: uniqueWord()), s.api)
        XCTAssertTrue(none.messages.isEmpty)

        // The person answers in the thread; the thread has both, oldest first.
        let answer = try await send(.mailReply(id: reply.message.id, text: "Thanks, \(word) is perfect."), s.api)
        XCTAssertEqual(answer.threadId, reply.message.threadId)
        XCTAssertTrue(answer.message.subject.hasPrefix("Re: "), answer.message.subject)
        XCTAssertEqual(answer.message.author.type, .owner)
        let (thread, threadRaw) = try await fetch(.mailThread(threadId: reply.message.threadId), s.api)
        XCTAssertEqual(thread.messages.count, rawCount(threadRaw, "messages"))
        XCTAssertEqual(thread.messages.map(\.id), [reply.message.id, answer.message.id])
        XCTAssertTrue(thread.messages.allSatisfy { $0.text != nil }, "a thread read carries bodies")
        XCTAssertEqual(MailThreads.group(thread.messages).count, 1)

        // Folders: archive, back, then the trash and emptying it for good.
        let archived = try await send(.mailUpdate(id: reply.message.id, folder: .archive), s.api)
        XCTAssertEqual(archived.message.folder, .archive)
        let archiveBox = try await send(.mailMessages(box: .archive), s.api)
        XCTAssertTrue(archiveBox.messages.contains { $0.id == reply.message.id })
        let inboxAfter = try await send(.mailMessages(box: .inbox), s.api)
        XCTAssertFalse(inboxAfter.messages.contains { $0.id == reply.message.id })
        let trashed = try await send(.mailUpdate(id: reply.message.id, folder: .trash), s.api)
        XCTAssertEqual(trashed.message.folder, .trash)
        let notFoundNow = try await send(.mailSearch(query: word), s.api)
        XCTAssertFalse(notFoundNow.messages.contains { $0.id == reply.message.id }, "search found something in the trash")
        let inTrash = try await send(.mailSearch(query: word, box: .trash), s.api)
        XCTAssertTrue(inTrash.messages.contains { $0.id == reply.message.id })
        let emptied = try await send(.mailEmptyTrash(), s.api)
        XCTAssertGreaterThanOrEqual(emptied.deleted, 1)
        await expectFailure(404, .mailMessage(id: reply.message.id), s.api)

        // Refusals: a send with no text, an unknown address, a missing message.
        await expectFailure(400, .mailSend(to: .selfNote, subject: "empty", text: ""), s.api)
        let outside = Endpoint<MailSent>(.post, "/api/mail/messages", body: .jsonValue(["to": ["someone@example.com"], "text": "hi"]))
        let refusal = await expectFailure(422, outside, s.api)
        XCTAssertEqual(refusal?.code, "recipient_not_internal")
        XCTAssertFalse(HVError.api(try XCTUnwrap(refusal)).mailSentence.isEmpty)
        await expectFailure(404, .mailMessage(id: "00000000-0000-4000-8000-000000000000"), s.api)
        await expectFailure(400, .mailUpdate(id: note.message.id), s.api)
    }

    func testAnAgentWithoutTheSendScopeIsRefused() async throws {
        let (api, _) = member(20)
        let key = try await send(.createAgentKey(name: unique("reader")), api)
        let reader = client(key.key)
        let failure = await expectFailure(403, .mailSend(to: .owner, subject: "x", text: "hello"), reader)
        XCTAssertEqual(failure?.code, "missing_scope")
        if let failure { XCTAssertTrue(HVError.api(failure).isMailMissingScope); XCTAssertFalse(HVError.api(failure).mailSentence.isEmpty) }
        let summary = try await send(.mailSummary(), reader)
        XCTAssertGreaterThanOrEqual(summary.unreadCount, 0, "a key may read its mailbox")
    }

    func testHeldMailIsReleasedByTheOwner() async throws {
        let s = try await setUp(21)
        let word = uniqueWord()
        // A message from outside waits until the owner lets agents see it.
        let threadID = UUID().uuidString.lowercased()
        let rows = try await arrange("mail_messages", [
            "mailbox_id": .string(s.mailbox.id), "user_id": .string(try XCTUnwrap(jwtSubject(s.token))),
            "message_id": .string("<\(word)@outside.example>"), "thread_id": .string(threadID),
            "author_type": "system", "author_name": "Stranger", "from_address": "stranger@outside.example",
            "to_addresses": ["me@example.com"], "subject": .string("Held \(word)"), "text_body": .string("Do not trust \(word)"),
            "agent_visible": false,
        ])
        let id = try XCTUnwrap(rows.first?["id"]?.string)
        let summary = try await send(.mailSummary(mailbox: s.mailbox.id), s.api)
        XCTAssertGreaterThanOrEqual(summary.heldCount, 1)
        let (held, raw) = try await fetch(.mailHeld(mailbox: s.mailbox.id), s.api)
        XCTAssertEqual(held.messages.count, rawCount(raw, "messages"))
        XCTAssertEqual(held.count, raw["count"]?.int)
        let item = try XCTUnwrap(held.messages.first { $0.id == id })
        XCTAssertEqual(item.subject, "Held \(word)")
        XCTAssertEqual(item.from, "stranger@outside.example")
        XCTAssertEqual(item.author.type, .system)
        XCTAssertTrue(item.text?.contains("Do not trust") ?? false)

        // An agent cannot read it; releasing makes it visible.
        let agentView = try await send(Endpoint<MailMessagePage>(.get, "/api/mail/messages"), s.agent)
        XCTAssertFalse(agentView.messages.contains { $0.id == id }, "an agent saw held mail")
        let released = try await send(.mailRelease(id: id, mailbox: s.mailbox.id), s.api)
        XCTAssertEqual(released.message.id, id)
        let after = try await send(.mailHeld(mailbox: s.mailbox.id), s.api)
        XCTAssertFalse(after.messages.contains { $0.id == id })
        let agentAfter = try await send(Endpoint<MailMessagePage>(.get, "/api/mail/messages"), s.agent)
        XCTAssertTrue(agentAfter.messages.contains { $0.id == id }, "release did not let agents see it")
        await expectFailure(404, .mailRelease(id: id, mailbox: s.mailbox.id), s.api)
    }

    func testAgentsSeeRepliesSwitchAndTheExport() async throws {
        let s = try await setUp(21)
        let off = try await send(.mailAgentsSeeReplies(false, mailbox: s.mailbox.id), s.api)
        XCTAssertFalse(off.mailbox.agentsSeeOwnerMail)
        let word = uniqueWord()
        let hidden = try await send(.mailSend(to: .selfNote, subject: "Hidden \(word)", text: "private \(word)", mailbox: s.mailbox.id), s.api)
        XCTAssertTrue(hidden.message.isHiddenFromAgents, "with the switch off a new note must be hidden from agents")
        XCTAssertTrue(MailText.replyIsHidden(newest: hidden.message, agentsSeeOwnerMail: false))
        let on = try await send(.mailAgentsSeeReplies(true, mailbox: s.mailbox.id), s.api)
        XCTAssertTrue(on.mailbox.agentsSeeOwnerMail)
        let shown = try await send(.mailSend(to: .selfNote, subject: "Shown \(word)", text: "visible \(word)", mailbox: s.mailbox.id), s.api)
        XCTAssertFalse(shown.message.isHiddenFromAgents)
        // The switch decides the next notes; it never rewrites one that exists.
        let still = try await send(.mailMessage(id: hidden.message.id, mailbox: s.mailbox.id, markRead: false), s.api)
        XCTAssertTrue(still.message.isHiddenFromAgents)

        let data = try await send(.mailExport(mailbox: s.mailbox.id), s.api)
        let export = try HVCoding.decoder(.verbatim).decode(JSONValue.self, from: data)
        let text = export.jsonString()
        XCTAssertTrue(text.contains(word), "the export is missing the notes")
        XCTAssertFalse(MailText.exportFilename(address: s.mailbox.address).isEmpty)
    }

    func testAnotherPersonsMailIsNotReachable() async throws {
        let (api, _) = member(20)
        let note = try await send(.mailSend(to: .selfNote, subject: "mine", text: "only mine \(uniqueWord())"), api)
        let (bob, _) = try second()
        await expectFailure(404, .mailMessage(id: note.message.id), bob)
        await expectFailure(404, .mailUpdate(id: note.message.id, unread: true), bob)
        await expectFailure(404, .mailReply(id: note.message.id, text: "gotcha"), bob)
        let theirs = try await send(.mailMessages(box: .sent), bob)
        XCTAssertFalse(theirs.messages.contains { $0.id == note.message.id })
    }
}
