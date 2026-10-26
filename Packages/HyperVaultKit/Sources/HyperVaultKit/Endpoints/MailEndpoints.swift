import Foundation

// Agent Mail routes (app/api/mail/**), called as the owner. A mailbox is named
// with `?mailbox=<id>`; leave it nil for the account's default.

extension Endpoint where Response == OwnerMailboxList {
    /// Every mailbox on the account, primary first, with unread and held counts.
    /// Also what provisions each claim's mailbox.
    public static var mailMailboxes: Endpoint<OwnerMailboxList> {
        Endpoint(.get, "/api/mail/owner/mailboxes")
    }
}

extension Endpoint where Response == MailboxSummary {
    public static func mailSummary(mailbox: String? = nil) -> Endpoint<MailboxSummary> {
        Endpoint(.get, "/api/mail", query: .make([("mailbox", mailbox)]))
    }
}

extension Endpoint where Response == MailMessagePage {
    /// One page of a box, newest first (50 is the most a page of metadata may hold).
    public static func mailMessages(
        box: MailBox = .inbox,
        unreadOnly: Bool = false,
        mailbox: String? = nil,
        limit: Int = 50,
        cursor: String? = nil
    ) -> Endpoint<MailMessagePage> {
        Endpoint(.get, "/api/mail/messages", query: .make([
            ("mailbox", mailbox),
            ("box", box.rawValue),
            ("unread", unreadOnly ? "1" : nil),
            ("limit", String(limit)),
            ("cursor", cursor),
        ]))
    }

    /// A thread's full messages (20 is the most a page with bodies may hold).
    /// Marks nothing read: that is a `PATCH` per message.
    public static func mailThread(
        threadId: String,
        mailbox: String? = nil,
        limit: Int = 20,
        cursor: String? = nil
    ) -> Endpoint<MailMessagePage> {
        Endpoint(.get, "/api/mail/messages", query: .make([
            ("mailbox", mailbox),
            ("thread_id", threadId),
            ("limit", String(limit)),
            ("cursor", cursor),
        ]))
    }
}

extension Endpoint where Response == MailMessageEnvelope {
    /// One message in full. Reading clears the unread bit unless `markRead` is false.
    public static func mailMessage(id: String, mailbox: String? = nil, markRead: Bool = true) -> Endpoint<MailMessageEnvelope> {
        Endpoint(.get, "/api/mail/messages/\(id)", query: .make([
            ("mailbox", mailbox),
            ("mark_read", markRead ? nil : "false"),
        ]))
    }

    /// Move a message between folders and/or change its unread bit (at least one).
    public static func mailUpdate(id: String, folder: MailFolder? = nil, unread: Bool? = nil, mailbox: String? = nil) -> Endpoint<MailMessageEnvelope> {
        var body: [String: JSONValue] = [:]
        if let folder { body["folder"] = .string(folder.rawValue) }
        if let unread { body["unread"] = .bool(unread) }
        return Endpoint(.patch, "/api/mail/messages/\(id)", query: .make([("mailbox", mailbox)]), body: .jsonValue(.object(body)))
    }

    /// Let agents see one held message.
    public static func mailRelease(id: String, mailbox: String? = nil) -> Endpoint<MailMessageEnvelope> {
        Endpoint(.post, "/api/mail/owner/held/\(id)/release", query: .make([("mailbox", mailbox)]))
    }
}

extension Endpoint where Response == MailSearchResult {
    /// Websearch over subject, sender and body. With no box: inbox and archive, not trash.
    public static func mailSearch(query: String, box: MailBox? = nil, mailbox: String? = nil, limit: Int = 30) -> Endpoint<MailSearchResult> {
        Endpoint(.get, "/api/mail/search", query: .make([
            ("mailbox", mailbox),
            ("q", query),
            ("box", box?.rawValue),
            ("limit", String(limit)),
        ]))
    }
}

extension Endpoint where Response == MailSent {
    /// Send a note. The person's notes go to `self`, the agents' side of the mailbox.
    public static func mailSend(
        to: MailRecipient = .selfNote,
        subject: String = "",
        text: String,
        attachments: [String] = [],
        mailbox: String? = nil
    ) -> Endpoint<MailSent> {
        var body: [String: JSONValue] = ["to": .array([.string(to.rawValue)]), "text": .string(text)]
        let title = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { body["subject"] = .string(title) }
        if !attachments.isEmpty { body["attachments"] = .array(attachments.map { .object(["artifact": .string($0)]) }) }
        return Endpoint(.post, "/api/mail/messages", query: .make([("mailbox", mailbox)]), body: .jsonValue(.object(body)))
    }

    /// Answer a message. The thread is inherited and the subject gets "Re: ".
    public static func mailReply(id: String, text: String, attachments: [String] = [], mailbox: String? = nil) -> Endpoint<MailSent> {
        var body: [String: JSONValue] = ["text": .string(text)]
        if !attachments.isEmpty { body["attachments"] = .array(attachments.map { .object(["artifact": .string($0)]) }) }
        return Endpoint(.post, "/api/mail/messages/\(id)/reply", query: .make([("mailbox", mailbox)]), body: .jsonValue(.object(body)))
    }
}

extension Endpoint where Response == MailHeldPage {
    public static func mailHeld(mailbox: String? = nil, limit: Int = 20, cursor: String? = nil) -> Endpoint<MailHeldPage> {
        Endpoint(.get, "/api/mail/owner/held", query: .make([
            ("mailbox", mailbox),
            ("limit", String(limit)),
            ("cursor", cursor),
        ]))
    }
}

extension Endpoint where Response == MailTrashEmptied {
    /// Delete everything in the mailbox's trash for good.
    public static func mailEmptyTrash(mailbox: String? = nil) -> Endpoint<MailTrashEmptied> {
        Endpoint(.delete, "/api/mail/owner/trash", query: .make([("mailbox", mailbox)]))
    }
}

extension Endpoint where Response == OwnerMailboxEnvelope {
    /// "Agents can see my replies": decides what the person's next notes are;
    /// it never rewrites one that exists.
    public static func mailAgentsSeeReplies(_ on: Bool, mailbox: String? = nil) -> Endpoint<OwnerMailboxEnvelope> {
        var body: [String: JSONValue] = ["agents_see_owner_mail": .bool(on)]
        if let mailbox { body["mailbox"] = .string(mailbox) }
        return Endpoint(.patch, "/api/mail/owner", body: .jsonValue(.object(body)))
    }
}

extension Endpoint where Response == Data {
    /// One mailbox as JSON, every row, to keep before releasing the name.
    public static func mailExport(mailbox: String? = nil) -> Endpoint<Data> {
        Endpoint(data: .get, "/api/mail/export", query: .make([("mailbox", mailbox)]))
    }
}
