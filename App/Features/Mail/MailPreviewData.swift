#if DEBUG
import HyperVaultKit
import SwiftUI

/// Canned answers for previews and snapshots: rows as the owner's mail routes give them.
enum MailPreviewData {
    static let boxA = "0000000a-0000-4000-8000-00000000000a"
    static let boxB = "0000000b-0000-4000-8000-00000000000b"
    static let threadID = "11111111-1111-4111-8111-111111111111"

    private static func stamp(_ minutesAgo: Double) -> String {
        HVDate.format(Date().addingTimeInterval(-minutesAgo * 60))
    }

    static func message(
        _ id: String, thread: String, subject: String, minutesAgo: Double, unread: Bool = false,
        agent: String? = "Claude Code", text: String? = nil, folder: String = "inbox", attachments: String = "[]",
        from: String = "ana@vault.cool"
    ) -> String {
        let author = agent.map { #"{"type":"key","name":"\#($0)","key_id":"22222222-2222-4222-8222-222222222222"}"# }
            ?? #"{"type":"owner","name":"","key_id":null}"#
        let body = text.map { #","in_reply_to":null,"text":\#(quoted($0)),"attachments":\#(attachments)"# } ?? ""
        return """
        {"id":"\(id)","thread_id":"\(thread)","folder":"\(folder)","from":"\(from)","to":["owner"],"cc":[],
         "subject":\(quoted(subject)),"unread":\(unread),"labels":["from-agent"],"created_at":"\(stamp(minutesAgo))",
         "attachment_count":0,"author":\(author),"agent_visible":true,"message_id":"<\(id)@vault.cool>"\(body)}
        """
    }

    private static func quoted(_ text: String) -> String {
        let data = (try? JSONEncoder().encode(text)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    static let mailboxes = """
    {"mailboxes":[
      {"id":"\(boxA)","claim_id":"c1","address":"ana@vault.cool","is_primary":true,"unread_count":2,"held_count":0,"agents_see_owner_mail":true},
      {"id":"\(boxB)","claim_id":"c2","address":"studio@vault.cool","is_primary":false,"unread_count":0,"held_count":0,"agents_see_owner_mail":true}]}
    """

    static var inbox: String {
        let rows = [
            message("m1", thread: threadID, subject: "Re: Weekly plan", minutesAgo: 12, unread: true, text: "Here is the plan."),
            message("m2", thread: "22222222-2222-4222-8222-222222222222", subject: "Found three broken links in the garden notes", minutesAgo: 190, unread: true, agent: "Gemini"),
            message("m3", thread: "33333333-3333-4333-8333-333333333333", subject: "Receipts for October", minutesAgo: 60 * 30, agent: "Claude Code"),
            message("m4", thread: "44444444-4444-4444-8444-444444444444", subject: "Ideas for the studio shelves", minutesAgo: 60 * 24 * 4, agent: "Grok"),
        ]
        return #"{"box":"inbox","messages":[\#(rows.joined(separator: ","))],"next_cursor":null}"#
    }

    static var thread: String {
        let attachment = #"[{"id":"a1","filename":"Weekly plan","content_type":"text/html","bytes":0,"href":"/a/weekly-plan-x7k2p9"}]"#
        let rows = [
            message("m0", thread: threadID, subject: "Weekly plan", minutesAgo: 60 * 5, text: "I drafted the plan for next week. Monday is the review; Thursday is the demo. I kept the open questions at the bottom.", attachments: attachment),
            message("m5", thread: threadID, subject: "Re: Weekly plan", minutesAgo: 60 * 2, agent: nil, text: "Looks good. Move the demo to Friday?"),
            message("m1", thread: threadID, subject: "Re: Weekly plan", minutesAgo: 12, unread: true, text: "Done. Friday it is, and I updated the page."),
        ]
        return #"{"messages":[\#(rows.joined(separator: ","))],"next_cursor":null}"#
    }

    static var routes: [MockRoute] {
        [
            .json(.get, "/api/mail/owner/mailboxes", mailboxes),
            .json(.get, "/api/mail/messages", inbox),
        ]
    }

    static var threadRoutes: [MockRoute] {
        [
            .json(.get, "/api/mail/owner/mailboxes", mailboxes),
            MockRoute(.get, "/api/mail/messages") { request in
                let isThread = request.url?.query?.contains("thread_id") == true
                return HTTPResponse(status: 200, data: Data((isThread ? thread : inbox).utf8))
            },
            .json(.patch, "/api/mail/messages/*", #"{"message":{"id":"m1"}}"#),
        ]
    }

    static var emptyRoutes: [MockRoute] {
        [
            .json(.get, "/api/mail/owner/mailboxes", #"{"mailboxes":[{"id":"\#(boxA)","claim_id":"c1","address":"ana@vault.cool","is_primary":true,"unread_count":0,"held_count":0,"agents_see_owner_mail":true}]}"#),
            .json(.get, "/api/mail/messages", #"{"box":"inbox","messages":[],"next_cursor":null}"#),
        ]
    }

    static var unavailableRoutes: [MockRoute] {
        [
            .json(.get, "/api/mail/owner/mailboxes", #"{"error":"mail_unavailable: Agent Mail is not set up on this server yet.","code":"mail_unavailable"}"#, status: 503),
        ]
    }

    static var heldRoutes: [MockRoute] {
        [
            .json(.get, "/api/mail/owner/held", #"{"count":1,"messages":[\#(message("h1", thread: "55555555-5555-4555-8555-555555555555", subject: "Invoice from a vendor", minutesAgo: 90, agent: "Vendor bot", text: "The invoice for October is 240 euros, due in 14 days.", from: "billing@northwind.example"))],"next_cursor":null}"#),
        ]
    }
}
#endif
