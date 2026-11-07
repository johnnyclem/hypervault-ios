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

    // An account with several addresses shows one mailbox at a time. Mail (or held mail) in another one used to be
    // invisible from the one on screen: the picker named unread counts only, and the "N held" row was the active
    // mailbox's alone.

    func testThePickerNamesWhatIsWaitingInEachMailbox() {
        XCTAssertEqual(OwnerMailbox(id: "a", address: "a@vault.cool").pickerTitle, "a@vault.cool")
        XCTAssertEqual(OwnerMailbox(id: "a", address: "a@vault.cool", unreadCount: 2).pickerTitle, "a@vault.cool (2 unread)")
        XCTAssertEqual(OwnerMailbox(id: "a", address: "a@vault.cool", heldCount: 1).pickerTitle, "a@vault.cool (1 held)")
        XCTAssertEqual(OwnerMailbox(id: "a", address: "a@vault.cool", unreadCount: 2, heldCount: 1).pickerTitle, "a@vault.cool (2 unread, 1 held)")
        XCTAssertEqual(OwnerMailbox(id: "a", address: nil, unreadCount: 1).pickerTitle, "No address yet (1 unread)")
    }

    func testNothingElsewhereWhenTheOtherMailboxesAreQuiet() {
        let a = OwnerMailbox(id: "a", address: "a@vault.cool", unreadCount: 5, heldCount: 2)
        let b = OwnerMailbox(id: "b", address: "b@vault.cool")
        XCTAssertNil(MailElsewhere(mailboxes: [a, b], active: a), "what waits in the mailbox on screen is not 'elsewhere'")
        XCTAssertNil(MailElsewhere(mailboxes: [a], active: a))
        XCTAssertNil(MailElsewhere(mailboxes: [], active: nil))
    }

    func testMailWaitingInOneOtherAddressIsNamed() throws {
        let a = OwnerMailbox(id: "a", address: "a@vault.cool")
        let b = OwnerMailbox(id: "b", address: "b@vault.cool", unreadCount: 2, heldCount: 1)
        let elsewhere = try XCTUnwrap(MailElsewhere(mailboxes: [a, b], active: a))
        XCTAssertEqual(elsewhere.target.id, "b")
        XCTAssertEqual(elsewhere.unread, 2)
        XCTAssertEqual(elsewhere.held, 1)
        XCTAssertEqual(elsewhere.title, "Mail in another address")
        XCTAssertEqual(elsewhere.subtitle, "b@vault.cool: 2 unread, 1 held")
    }

    func testMailWaitingInSeveralOtherAddressesIsTotalledAndOpensTheOneWithHeldMail() throws {
        let a = OwnerMailbox(id: "a", address: "a@vault.cool", unreadCount: 9)
        let b = OwnerMailbox(id: "b", address: "b@vault.cool", unreadCount: 3)
        let c = OwnerMailbox(id: "c", address: "c@vault.cool", unreadCount: 1, heldCount: 4)
        let quiet = OwnerMailbox(id: "d", address: "d@vault.cool")
        let elsewhere = try XCTUnwrap(MailElsewhere(mailboxes: [a, b, quiet, c], active: a))
        XCTAssertEqual(elsewhere.boxes.map(\.id), ["b", "c"], "quiet mailboxes are left out, the server's order is kept")
        XCTAssertEqual(elsewhere.title, "Mail in 2 other addresses")
        XCTAssertEqual(elsewhere.subtitle, "4 unread, 4 held")
        XCTAssertEqual(elsewhere.target.id, "c", "held mail is what needs the person, so that is where a tap goes")
        let onlyUnread = try XCTUnwrap(MailElsewhere(mailboxes: [a, b, OwnerMailbox(id: "e", address: "e@vault.cool", unreadCount: 1)], active: a))
        XCTAssertEqual(onlyUnread.target.id, "b")
        XCTAssertEqual(onlyUnread.subtitle, "4 unread")
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

    // A list used to decode all or nothing: one row without a usable id threw, the page's `try?` swallowed it and the
    // whole box read as empty, so the screen said "No mail yet" about a mailbox that held mail. A row the app cannot
    // read now costs that row, and is counted so the screen can say so.

    private let unreadable = [
        #"{"thread_id":"t","subject":"no id at all"}"#,
        #"{"id":42,"thread_id":"t","subject":"an id that is a number"}"#,
        #"{"id":null,"subject":"an id that is null"}"#,
        "null",
        #""not even an object""#,
    ]

    func testOneUnreadableRowDoesNotEmptyTheList() throws {
        let rows = ([message("m1")] + unreadable + [message("m2")]).joined(separator: ",")
        let page = try HVCoding.decoder().decode(MailMessagePage.self, from: Data(#"{"box":"inbox","messages":[\#(rows)],"next_cursor":"c"}"#.utf8))
        XCTAssertEqual(page.messages.map(\.id), ["m1", "m2"], "the rows that can be read are all kept, in order")
        XCTAssertEqual(page.skipped, unreadable.count)
        XCTAssertEqual(page.nextCursor, "c", "and paging carries on past them")
    }

    func testAListOfOnlyUnreadableRowsIsCountedNotPassedOffAsEmpty() throws {
        let page = try HVCoding.decoder().decode(MailMessagePage.self, from: Data(#"{"box":"inbox","messages":[\#(unreadable[0]),\#(unreadable[1])]}"#.utf8))
        XCTAssertTrue(page.messages.isEmpty)
        XCTAssertEqual(page.skipped, 2, "an empty list that dropped rows is not the same answer as an empty list")
        let empty = try HVCoding.decoder().decode(MailMessagePage.self, from: Data(#"{"box":"inbox","messages":[]}"#.utf8))
        XCTAssertEqual(empty.skipped, 0)
    }

    func testHeldMailKeepsWhatCanBeReadAndTheServersOwnCount() throws {
        let rows = [unreadable[0], message("h1"), message("h2")].joined(separator: ",")
        let held = try HVCoding.decoder().decode(MailHeldPage.self, from: Data(#"{"count":3,"messages":[\#(rows)],"next_cursor":null}"#.utf8))
        XCTAssertEqual(held.messages.map(\.id), ["h1", "h2"])
        XCTAssertEqual(held.count, 3, "the server's count is what the screen holds the rows up against")
        XCTAssertEqual(held.skipped, 1)
    }

    func testSearchAndTheSummaryAndTheMailboxListKeepWhatCanBeRead() throws {
        let hits = try HVCoding.decoder().decode(MailSearchResult.self, from: Data(#"{"query":"plan","messages":[\#(unreadable[0]),\#(message("m1"))]}"#.utf8))
        XCTAssertEqual(hits.messages.map(\.id), ["m1"])
        let summary = try HVCoding.decoder().decode(MailboxSummary.self, from: Data(#"{"unread_count":1,"held_count":0,"latest":[\#(unreadable[1]),\#(message("m2"))]}"#.utf8))
        XCTAssertEqual(summary.latest.map(\.id), ["m2"])
        let list = try HVCoding.decoder().decode(OwnerMailboxList.self, from: Data(#"{"mailboxes":[{"address":"no-id@vault.cool"},{"id":"b1","address":"ana@vault.cool","is_primary":true}]}"#.utf8))
        XCTAssertEqual(list.mailboxes.map(\.id), ["b1"], "a mailbox without an id cannot be asked for, and does not take the others with it")
    }

    // The Held screen read the first page (20) and stopped, and said "Nothing is held." about any empty answer,
    // including one whose rows it could not read.

    func heldPage(_ ids: [String], count: Int? = nil, cursor: String? = nil, extra: [String] = []) throws -> MailHeldPage {
        let rows = (extra + ids.map { message($0) }).joined(separator: ",")
        let next = cursor.map { #""\#($0)""# } ?? "null"
        return try HVCoding.decoder().decode(MailHeldPage.self, from: Data(#"{"count":\#(count ?? ids.count),"messages":[\#(rows)],"next_cursor":\#(next)}"#.utf8))
    }

    func testTheWordsForRowsThatCouldNotBeRead() {
        XCTAssertNil(MailText.unreadableSentence(0))
        XCTAssertNil(MailText.unreadableSentence(-1))
        XCTAssertEqual(MailText.unreadableSentence(1), "1 message could not be shown.")
        XCTAssertEqual(MailText.unreadableSentence(3), "3 messages could not be shown.")
        XCTAssertEqual(MailText.unreadableSentence(1, noun: "held message"), "1 held message could not be shown.")
    }

    func testTheHeldListPagesOnPastTheFirstTwenty() throws {
        var list = MailHeldList(page: try heldPage(["h1", "h2"], count: 5, cursor: "c1"))
        XCTAssertTrue(list.hasMore)
        XCTAssertEqual(list.messages.map(\.id), ["h1", "h2"])
        list.append(try heldPage(["h2", "h3", "h4"], count: 5, cursor: "c2"))
        XCTAssertEqual(list.messages.map(\.id), ["h1", "h2", "h3", "h4"], "a row the first page already had is not shown twice")
        XCTAssertEqual(list.nextCursor, "c2")
        list.append(try heldPage(["h5"], count: 5))
        XCTAssertEqual(list.messages.count, 5)
        XCTAssertFalse(list.hasMore, "the last page has no cursor")
    }

    func testTheHeldListSaysNothingIsHeldOnlyWhenNothingIs() throws {
        XCTAssertTrue(MailHeldList(page: try heldPage([])).isNothing)
        XCTAssertNil(MailHeldList(page: try heldPage([])).unreadableSentence)
        let dropped = MailHeldList(page: try heldPage([], count: 2, extra: [unreadable[0], unreadable[1]]))
        XCTAssertFalse(dropped.isNothing, "rows that could not be read are not 'nothing held'")
        XCTAssertEqual(dropped.unreadableSentence, "2 held messages could not be shown.")
        var one = MailHeldList(page: try heldPage(["h1"], count: 2, extra: [unreadable[0]]))
        XCTAssertFalse(one.isNothing)
        XCTAssertEqual(one.unreadableSentence, "1 held message could not be shown.")
        one.append(try heldPage([], extra: [unreadable[0]]))
        XCTAssertEqual(one.unreadableSentence, "2 held messages could not be shown.", "what each page dropped adds up")
    }

    func testReleasingTheLastVisibleMessageWhileMoreAreHeldIsNotNothing() throws {
        var list = MailHeldList(page: try heldPage(["h1", "h2"], count: 30, cursor: "c1"))
        list.remove("h1")
        list.remove("h2")
        XCTAssertTrue(list.messages.isEmpty)
        XCTAssertTrue(list.hasMore)
        XCTAssertFalse(list.isNothing, "the rest are still held, on the next page: the screen offers them, it does not say 'Nothing is held.'")
        // The next page is the last one, and the server's count has come down with the two released.
        list.append(try heldPage(["h3"], count: 1))
        XCTAssertEqual(list.messages.map(\.id), ["h3"])
        XCTAssertFalse(list.isNothing)
        XCTAssertNil(list.disagreementSentence)
    }

    // The server counts held mail twice: `held_count` on the mailbox row and `count` on the held page. When the page's
    // own count says there is more than the page sent, and there is no next page, the screen must not say "Nothing is
    // held." (or show the rows as if they were all of it).

    func testTheServersCountIsHeldUpAgainstTheRows() throws {
        let none = MailHeldList(page: try heldPage([], count: 3))
        XCTAssertFalse(none.isNothing, "the server counts 3 and sent none")
        XCTAssertEqual(none.unaccounted, 3)
        XCTAssertEqual(none.disagreementSentence, "3 held messages did not come through. Pull down to try again.")

        let some = MailHeldList(page: try heldPage(["h1"], count: 3))
        XCTAssertEqual(some.unaccounted, 2)
        XCTAssertEqual(some.disagreementSentence, "2 held messages did not come through. Pull down to try again.")
        XCTAssertEqual(MailHeldList(page: try heldPage(["h1"], count: 2)).disagreementSentence, "1 held message did not come through. Pull down to try again.")

        let agrees = MailHeldList(page: try heldPage(["h1", "h2"], count: 2))
        XCTAssertEqual(agrees.unaccounted, 0)
        XCTAssertNil(agrees.disagreementSentence)

        let paging = MailHeldList(page: try heldPage(["h1", "h2"], count: 30, cursor: "c"))
        XCTAssertEqual(paging.unaccounted, 0, "more pages are coming: the rows so far are not all of it, and that is fine")
        XCTAssertNil(paging.disagreementSentence)

        let dropped = MailHeldList(page: try heldPage(["h1", "h2"], count: 3, extra: [unreadable[0]]))
        XCTAssertEqual(dropped.unaccounted, 0, "a row that could not be read is accounted for by `skipped`")
        XCTAssertEqual(dropped.unreadableSentence, "1 held message could not be shown.")

        let pageSizeCount = MailHeldList(page: try heldPage(["h1", "h2"], count: 1))
        XCTAssertEqual(pageSizeCount.unaccounted, 0, "a count below the rows is never a disagreement")
    }

    func testReleasingBringsTheCountDownWithTheRows() throws {
        var list = MailHeldList(page: try heldPage(["h1", "h2"], count: 2))
        list.remove("h1")
        XCTAssertEqual(list.count, 1)
        list.remove("not there")
        XCTAssertEqual(list.count, 1, "an id that was not on the list changes nothing")
        list.remove("h2")
        XCTAssertEqual(list.count, 0)
        XCTAssertTrue(list.isNothing, "everything on the list was let through, and the server's count came down with it")
        XCTAssertNil(list.disagreementSentence)
    }

    func testReleasingTakesTheMessageOffTheHeldList() throws {
        var list = MailHeldList(page: try heldPage(["h1", "h2"]))
        list.remove("h1")
        XCTAssertEqual(list.messages.map(\.id), ["h2"])
        list.remove("not there")
        XCTAssertEqual(list.messages.map(\.id), ["h2"])
        list.remove("h2")
        XCTAssertTrue(list.isNothing)
    }

    func testWhatWasDroppedSurvivesTheSavedCopy() throws {
        // The saved copy is shown first and the fresh answer after: the count must not read zero in between.
        let rows = [unreadable[0], message("m1")].joined(separator: ",")
        let page = try HVCoding.decoder().decode(MailMessagePage.self, from: Data(#"{"box":"inbox","messages":[\#(rows)]}"#.utf8))
        let back = try HVCoding.decoder(.verbatim).decode(MailMessagePage.self, from: try HVCoding.encoder(.verbatim).encode(page))
        XCTAssertEqual(back, page)
        XCTAssertEqual(back.skipped, 1)
        let held = try HVCoding.decoder().decode(MailHeldPage.self, from: Data(#"{"count":2,"messages":[\#(rows)]}"#.utf8))
        let heldBack = try HVCoding.decoder(.verbatim).decode(MailHeldPage.self, from: try HVCoding.encoder(.verbatim).encode(held))
        XCTAssertEqual(heldBack, held)
        XCTAssertEqual(heldBack.skipped, 1)
    }

    func testAnAnswerWithoutItsListIsAnErrorNotAnEmptyBox() throws {
        // The list is not there, is null, or is not an array: the server said something this app does not understand
        // (a 200 that carries an error, a renamed or wrapped key). Saying "no mail" would be a guess; failing the load
        // says so, and the screen shows the error with Try again. The server's own fixtures always send the key, an
        // empty box included, and its errors arrive as non-2xx.
        for body in [#"{"messages":{"items":[]}}"#, #"{"messages":"none"}"#, #"{"messages":7}"#,
                     #"{"box":"inbox"}"#, #"{"messages":null}"#, "{}", #"{"error":"Something broke."}"#, #"{"count":2}"#] {
            XCTAssertThrowsError(try HVCoding.decoder().decode(MailMessagePage.self, from: Data(body.utf8)), body)
            XCTAssertThrowsError(try HVCoding.decoder().decode(MailHeldPage.self, from: Data(body.utf8)), body)
            XCTAssertThrowsError(try HVCoding.decoder().decode(MailSearchResult.self, from: Data(body.utf8)), body)
        }
        XCTAssertThrowsError(try HVCoding.decoder().decode(OwnerMailboxList.self, from: Data(#"{"error":"nope"}"#.utf8)), "no mailboxes key")
        XCTAssertThrowsError(try HVCoding.decoder().decode(OwnerMailboxList.self, from: Data(#"{"mailboxes":null}"#.utf8)))
        XCTAssertThrowsError(try HVCoding.decoder().decode(MailboxSummary.self, from: Data(#"{"unread_count":1,"held_count":0}"#.utf8)), "no latest key")
        // A list that is there and empty is an empty box.
        XCTAssertEqual(try HVCoding.decoder().decode(MailMessagePage.self, from: Data(#"{"box":"inbox","messages":[]}"#.utf8)).messages.count, 0)
        XCTAssertEqual(try HVCoding.decoder().decode(MailHeldPage.self, from: Data(#"{"count":0,"messages":[]}"#.utf8)).messages.count, 0)
        XCTAssertEqual(try HVCoding.decoder().decode(OwnerMailboxList.self, from: Data(#"{"mailboxes":[]}"#.utf8)).mailboxes.count, 0)
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

    func testTimeBuckets() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 15)))
        func at(_ day: Int, hour: Int = 9, month: Int = 10, year: Int = 2026) throws -> Date {
            try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)))
        }
        XCTAssertEqual(MailTimeBucket.bucket(for: try at(26), now: now, calendar: calendar), .today(try at(26)))
        XCTAssertEqual(MailTimeBucket.bucket(for: try at(25, hour: 23), now: now, calendar: calendar), .yesterday)
        XCTAssertEqual(MailTimeBucket.bucket(for: try at(22), now: now, calendar: calendar), .thisWeek(try at(22)))
        XCTAssertEqual(MailTimeBucket.bucket(for: try at(9), now: now, calendar: calendar), .earlier(try at(9), sameYear: true))
        XCTAssertEqual(MailTimeBucket.bucket(for: try at(9, month: 3, year: 2025), now: now, calendar: calendar), .earlier(try at(9, month: 3, year: 2025), sameYear: false))
        XCTAssertEqual(MailTimeBucket.bucket(for: nil, now: now, calendar: calendar), .unknown)
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

    func testMovingFromTheListReadsTheWholeThreadFirst() async throws {
        let page = #"{"messages":[\#(message("a", folder: "inbox")),\#(message("b", folder: "inbox"))],"next_cursor":null}"#
        let transport = MockTransport(routes: [
            .json(.get, "/api/mail/messages", page),
            .json(.patch, "/api/mail/messages/*", #"{"message":\#(message("x", folder: "trash"))}"#),
        ])
        let result = try await MailService(client: client(transport)).moveThread(id: thread, mailbox: nil, loaded: nil, olderCursor: nil, to: .trash)
        XCTAssertEqual(result, .moved(2))
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
