import Foundation

// Agent Mail: the person's side of a mailbox shared with their agents.
// Wire shapes are lib/mail/types.ts and the routes under app/api/mail. In v1
// nothing leaves HyperVault: a message goes to the person (`owner`) or to the
// sender's own later runs (`self`), so the person's notes go to `self`.

private extension KeyedDecodingContainer {
    /// A field that may be missing or the wrong type: nil rather than a failed list.
    func soft<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

// MARK: Boxes, filters, folders

/// A box as the API names it. `inbox` and `sent` are relative to who asks;
/// `archive` and `trash` are the stored folder.
public enum MailBox: String, Sendable, Codable, CaseIterable, Hashable {
    case inbox, sent, archive, trash
}

/// The stored folder of a message, and what `PATCH` moves it between.
public enum MailFolder: String, Sendable, Codable, CaseIterable, Hashable {
    case inbox, archive, trash

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MailFolder(rawValue: raw) ?? .inbox
    }
}

/// The five filters over the list (the web's `MAIL_FILTERS`). Unread is the
/// inbox with `unread=1`, which lists exactly the rows the unread count counts.
public enum MailFilter: String, Sendable, CaseIterable, Identifiable, Hashable {
    case inbox, unread, sent, archive, trash

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .inbox: return "Inbox"
        case .unread: return "Unread"
        case .sent: return "Sent"
        case .archive: return "Archive"
        case .trash: return "Trash"
        }
    }

    public var box: MailBox {
        switch self {
        case .inbox, .unread: return .inbox
        case .sent: return .sent
        case .archive: return .archive
        case .trash: return .trash
        }
    }

    public var unreadOnly: Bool { self == .unread }
}

// MARK: Who wrote it

public struct MailAuthor: Sendable, Codable, Hashable {
    public enum Kind: String, Sendable, Codable, Hashable {
        case owner, key, system

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            // An author nobody recognises reads as an agent: the careful label.
            self = Kind(rawValue: raw) ?? .key
        }
    }

    public let type: Kind
    /// A snapshot of the key name or `agent_name` at send time; empty for the owner.
    public let name: String
    public let keyId: String?

    public init(type: Kind, name: String = "", keyId: String? = nil) {
        self.type = type
        self.name = name
        self.keyId = keyId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        type = c.soft(Kind.self, .type) ?? .key
        name = c.soft(String.self, .name) ?? ""
        keyId = c.soft(String.self, .keyId)
    }

    enum Keys: String, CodingKey { case type, name, keyId }

    /// Who wrote it, as a person reads it: "You" for the owner and nobody else,
    /// one fixed word for the system, and for a key the name it signed with. An
    /// agent picks that name, so it can be any text ("You" included): the agent
    /// tag beside it (`isAgent`) is what says whose mail it is.
    public var label: String {
        switch type {
        case .owner: return "You"
        case .system: return "System"
        case .key:
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "An agent" : trimmed
        }
    }

    /// Whether a key wrote it. The owner's and the system's mail never carries
    /// the tag, so a key named "System" cannot read as the system.
    public var isAgent: Bool { type == .key }
}

// MARK: Attachments

/// A kept file attached to a message. It links to a page of the person's own.
public struct MailAttachment: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let filename: String
    public let contentType: String
    public let bytes: Int
    /// `/a/<slug>` of the kept file, or nil when the artifact has since been deleted.
    public let href: String?

    public init(id: String, filename: String, contentType: String = "", bytes: Int = 0, href: String? = nil) {
        self.id = id
        self.filename = filename
        self.contentType = contentType
        self.bytes = bytes
        self.href = href
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = c.soft(String.self, .id) ?? UUID().uuidString
        filename = c.soft(String.self, .filename) ?? "Attachment"
        contentType = c.soft(String.self, .contentType) ?? ""
        bytes = c.soft(Int.self, .bytes) ?? 0
        href = c.soft(String.self, .href)
    }

    enum Keys: String, CodingKey { case id, filename, contentType, bytes, href }

    /// The slug of the page this links to, only when `href` is one of the app's
    /// own file routes (`/a/<slug>`). Anything else is shown as text, never opened.
    public var slug: String? {
        guard let href, href.hasPrefix("/a/") else { return nil }
        let rest = href.dropFirst(3)
        guard let first = rest.first, first != "/", first != "?", first != "#", !first.isWhitespace else { return nil }
        for character in rest where character.isWhitespace || character == "?" || character == "#" { return nil }
        return String(rest)
    }
}

// MARK: Messages

/// One message, as a list shows it (metadata) or a thread does (with `text`).
public struct MailMessage: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let threadId: String
    public let folder: MailFolder
    /// The bare claim address, or "" for the internal box. Never a display name.
    public let from: String
    public let to: [String]
    public let cc: [String]
    public let subject: String
    /// Relative to the viewer: the stored bit and the row is addressed to the owner's side.
    public let unread: Bool
    public let labels: [String]
    public let createdAt: Date?
    public let attachmentCount: Int
    public let author: MailAuthor
    /// Search hits only: plain text around the match.
    public let snippet: String?
    /// The owner's shape only: false on a note of the owner's that agents cannot read.
    public let agentVisible: Bool?
    public let messageId: String?
    public let inReplyTo: String?
    /// A thread's full messages and `GET /messages/{id}` only.
    public let text: String?
    public let attachments: [MailAttachment]

    public init(
        id: String,
        threadId: String,
        folder: MailFolder = .inbox,
        from: String = "",
        to: [String] = ["owner"],
        cc: [String] = [],
        subject: String = "",
        unread: Bool = false,
        labels: [String] = [],
        createdAt: Date? = nil,
        attachmentCount: Int = 0,
        author: MailAuthor,
        snippet: String? = nil,
        agentVisible: Bool? = nil,
        messageId: String? = nil,
        inReplyTo: String? = nil,
        text: String? = nil,
        attachments: [MailAttachment] = []
    ) {
        self.id = id
        self.threadId = threadId
        self.folder = folder
        self.from = from
        self.to = to
        self.cc = cc
        self.subject = subject
        self.unread = unread
        self.labels = labels
        self.createdAt = createdAt
        self.attachmentCount = attachmentCount
        self.author = author
        self.snippet = snippet
        self.agentVisible = agentVisible
        self.messageId = messageId
        self.inReplyTo = inReplyTo
        self.text = text
        self.attachments = attachments
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        threadId = c.soft(String.self, .threadId) ?? id
        folder = c.soft(MailFolder.self, .folder) ?? .inbox
        from = c.soft(String.self, .from) ?? ""
        to = c.soft([String].self, .to) ?? []
        cc = c.soft([String].self, .cc) ?? []
        subject = c.soft(String.self, .subject) ?? ""
        unread = c.soft(Bool.self, .unread) ?? false
        labels = c.soft([String].self, .labels) ?? []
        createdAt = c.soft(Date.self, .createdAt)
        attachmentCount = c.soft(Int.self, .attachmentCount) ?? 0
        author = c.soft(MailAuthor.self, .author) ?? MailAuthor(type: .key)
        snippet = c.soft(String.self, .snippet)
        agentVisible = c.soft(Bool.self, .agentVisible)
        messageId = c.soft(String.self, .messageId)
        inReplyTo = c.soft(String.self, .inReplyTo)
        text = c.soft(String.self, .text)
        attachments = c.soft([MailAttachment].self, .attachments) ?? []
    }

    enum Keys: String, CodingKey {
        case id, threadId, folder, from, to, cc, subject, unread, labels, createdAt, attachmentCount
        case author, snippet, agentVisible, messageId, inReplyTo, text, attachments
    }

    /// The subject a person reads: no stacked "Re: ", and a placeholder when nothing is left.
    public var displaySubject: String { MailText.threadSubject(subject) }

    /// A note of the person's own that agents cannot read ("Not shared with agents").
    public var isHiddenFromAgents: Bool { author.type == .owner && agentVisible == false }

    /// A copy with the unread bit changed (the list mirrors what the server accepted).
    public func withUnread(_ value: Bool) -> MailMessage {
        MailMessage(
            id: id, threadId: threadId, folder: folder, from: from, to: to, cc: cc, subject: subject,
            unread: value, labels: labels, createdAt: createdAt, attachmentCount: attachmentCount,
            author: author, snippet: snippet, agentVisible: agentVisible, messageId: messageId,
            inReplyTo: inReplyTo, text: text, attachments: attachments
        )
    }

    /// A copy in another folder.
    public func withFolder(_ value: MailFolder) -> MailMessage {
        MailMessage(
            id: id, threadId: threadId, folder: value, from: from, to: to, cc: cc, subject: subject,
            unread: unread, labels: labels, createdAt: createdAt, attachmentCount: attachmentCount,
            author: author, snippet: snippet, agentVisible: agentVisible, messageId: messageId,
            inReplyTo: inReplyTo, text: text, attachments: attachments
        )
    }
}

/// A page of messages: a box (`box` set) or a thread (`box` nil, full bodies,
/// oldest to newest within the page, `nextCursor` pointing at older ones).
public struct MailMessagePage: Sendable, Codable, Equatable {
    public let box: MailBox?
    public let messages: [MailMessage]
    public let nextCursor: String?

    public init(box: MailBox? = nil, messages: [MailMessage] = [], nextCursor: String? = nil) {
        self.box = box
        self.messages = messages
        self.nextCursor = nextCursor
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        box = c.soft(MailBox.self, .box)
        messages = c.soft([MailMessage].self, .messages) ?? []
        nextCursor = c.soft(String.self, .nextCursor)
    }

    enum Keys: String, CodingKey { case box, messages, nextCursor }
}

/// `GET /api/mail/search`.
public struct MailSearchResult: Sendable, Codable, Equatable {
    public let query: String
    public let messages: [MailMessage]

    public init(query: String = "", messages: [MailMessage] = []) {
        self.query = query
        self.messages = messages
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        query = c.soft(String.self, .query) ?? ""
        messages = c.soft([MailMessage].self, .messages) ?? []
    }

    enum Keys: String, CodingKey { case query, messages }
}

/// `{ "message": ... }`: one message read, changed or released.
public struct MailMessageEnvelope: Sendable, Codable, Equatable {
    public let message: MailMessage
}

/// What a send or a reply answers (201): the sender's own stored row and its thread.
public struct MailSent: Sendable, Codable, Equatable {
    public let message: MailMessage
    public let threadId: String
}

/// `DELETE /api/mail/owner/trash`.
public struct MailTrashEmptied: Sendable, Codable, Equatable {
    public let deleted: Int

    public init(deleted: Int) { self.deleted = deleted }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        deleted = c.soft(Int.self, .deleted) ?? 0
    }

    enum Keys: String, CodingKey { case deleted }
}

/// Mail waiting for the person: from someone other than them, unreadable to agents.
public struct MailHeldPage: Sendable, Codable, Equatable {
    public let count: Int
    public let messages: [MailMessage]
    public let nextCursor: String?

    public init(count: Int = 0, messages: [MailMessage] = [], nextCursor: String? = nil) {
        self.count = count
        self.messages = messages
        self.nextCursor = nextCursor
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        messages = c.soft([MailMessage].self, .messages) ?? []
        count = c.soft(Int.self, .count) ?? messages.count
        nextCursor = c.soft(String.self, .nextCursor)
    }

    enum Keys: String, CodingKey { case count, messages, nextCursor }
}

// MARK: Mailboxes

/// One mailbox on the account (`GET /api/mail/owner/mailboxes`).
public struct OwnerMailbox: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    /// What a key is pinned to; nil for the internal box of an account with no claim.
    public let claimId: String?
    /// The claim address, or nil for the internal box.
    public let address: String?
    public let isPrimary: Bool
    public let unreadCount: Int
    public let heldCount: Int
    public let agentsSeeOwnerMail: Bool

    public init(
        id: String, claimId: String? = nil, address: String? = nil, isPrimary: Bool = false,
        unreadCount: Int = 0, heldCount: Int = 0, agentsSeeOwnerMail: Bool = true
    ) {
        self.id = id
        self.claimId = claimId
        self.address = address
        self.isPrimary = isPrimary
        self.unreadCount = unreadCount
        self.heldCount = heldCount
        self.agentsSeeOwnerMail = agentsSeeOwnerMail
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        claimId = c.soft(String.self, .claimId)
        address = c.soft(String.self, .address)
        isPrimary = c.soft(Bool.self, .isPrimary) ?? false
        unreadCount = c.soft(Int.self, .unreadCount) ?? 0
        heldCount = c.soft(Int.self, .heldCount) ?? 0
        agentsSeeOwnerMail = c.soft(Bool.self, .agentsSeeOwnerMail) ?? true
    }

    enum Keys: String, CodingKey { case id, claimId, address, isPrimary, unreadCount, heldCount, agentsSeeOwnerMail }

    /// The address, or the words for a box that has none.
    public var displayAddress: String { address ?? "No address yet" }

    /// The mailbox to show: the one asked for, else the first with an address,
    /// else the first there is (an account with no claimed name has one box
    /// with no address).
    public static func choose(from mailboxes: [OwnerMailbox], preferring id: String?) -> OwnerMailbox? {
        if let id, let match = mailboxes.first(where: { $0.id == id }) { return match }
        return mailboxes.first(where: { $0.address != nil }) ?? mailboxes.first
    }
}

public struct OwnerMailboxList: Sendable, Codable, Equatable {
    public let mailboxes: [OwnerMailbox]

    public init(mailboxes: [OwnerMailbox] = []) { self.mailboxes = mailboxes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let all = c.soft([OwnerMailbox].self, .mailboxes) ?? []
        // The route lists the primary first; keep that whatever else changes.
        mailboxes = all.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.isPrimary != rhs.element.isPrimary { return lhs.element.isPrimary }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    enum Keys: String, CodingKey { case mailboxes }

    public var totalUnread: Int { mailboxes.reduce(0) { $0 + $1.unreadCount } }
}

/// `PATCH /api/mail/owner`: the mailbox with its switch changed.
public struct OwnerMailboxEnvelope: Sendable, Codable, Equatable {
    public let mailbox: OwnerMailbox
}

/// `GET /api/mail`: the caller's mailbox at a glance.
public struct MailboxSummary: Sendable, Codable, Equatable {
    public let address: String?
    public let unreadCount: Int
    public let heldCount: Int
    public let latest: [MailMessage]
    public let mailboxId: String?
    public let agentsSeeOwnerMail: Bool?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        address = c.soft(String.self, .address)
        unreadCount = c.soft(Int.self, .unreadCount) ?? 0
        heldCount = c.soft(Int.self, .heldCount) ?? 0
        latest = c.soft([MailMessage].self, .latest) ?? []
        mailboxId = c.soft(String.self, .mailboxId)
        agentsSeeOwnerMail = c.soft(Bool.self, .agentsSeeOwnerMail)
    }

    enum Keys: String, CodingKey { case address, unreadCount, heldCount, latest, mailboxId, agentsSeeOwnerMail }
}

/// Where a note from the person goes. The web's compose box has no recipient
/// control: a note always goes to `self`, the agents' side of the mailbox.
public enum MailRecipient: String, Sendable, Codable, Hashable {
    case owner
    case selfNote = "self"
}

// MARK: Threads, made on the phone

/// A thread for the list: the API lists messages newest first and has no
/// thread route, so a thread here is only the messages of it that are loaded.
public struct MailThread: Sendable, Hashable, Identifiable {
    public let id: String
    /// The loaded messages of the thread, newest first.
    public let messages: [MailMessage]

    public init(id: String, messages: [MailMessage]) {
        self.id = id
        self.messages = messages
    }

    /// The newest loaded message: what the row shows.
    public var newest: MailMessage { messages[0] }

    /// Any loaded message is unread, as the owner sees it.
    public var unread: Bool { messages.contains(where: \.unread) }

    public var unreadCount: Int { messages.filter(\.unread).count }
}

public enum MailThreads {
    /// Group a newest-first list by `threadId`, in the order of each thread's newest message.
    public static func group(_ messages: [MailMessage]) -> [MailThread] {
        var order: [String] = []
        var groups: [String: [MailMessage]] = [:]
        for message in messages {
            if groups[message.threadId] == nil { order.append(message.threadId) }
            groups[message.threadId, default: []].append(message)
        }
        return order.compactMap { id in groups[id].map { MailThread(id: id, messages: $0) } }
    }

    /// Add a page to a list, leaving out any message the list already has.
    public static func appendUnique(_ rows: [MailMessage], _ page: [MailMessage]) -> [MailMessage] {
        var seen = Set(rows.map(\.id))
        var out = rows
        for message in page where seen.insert(message.id).inserted { out.append(message) }
        return out
    }

    /// Put the rows of a newer page in place of the loaded ones they repeat,
    /// and add the ones that are new at the end (a thread read again after a reply).
    public static func mergeNewest(_ rows: [MailMessage], _ page: [MailMessage]) -> [MailMessage] {
        let fresh = Dictionary(page.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let known = Set(rows.map(\.id))
        return rows.map { fresh[$0.id] ?? $0 } + page.filter { !known.contains($0.id) }
    }

    /// Older messages first in a page that arrived newest first, or the reverse.
    public static func prepend(older page: [MailMessage], to rows: [MailMessage]) -> [MailMessage] {
        appendUnique(page, rows)
    }
}

// MARK: Words

public enum MailText {
    public static let noSubject = "(no subject)"

    /// A subject without its leading "Re: " (however many a reply chain stacked
    /// up), or the placeholder when nothing is left.
    public static func threadSubject(_ subject: String) -> String {
        var rest = Substring(subject)
        while true {
            let trimmed = rest.drop(while: { $0.isWhitespace })
            guard trimmed.lowercased().hasPrefix("re:") else { rest = trimmed; break }
            rest = trimmed.dropFirst(3)
        }
        let bare = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        return bare.isEmpty ? noSubject : bare
    }

    /// The route's sentence without its leading code: the routes answer
    /// "missing_scope: This key can ...", which is written for a model; a person
    /// reads what follows the colon.
    public static func plainSentence(_ error: String, code: String?) -> String {
        let trimmed = error.trimmingCharacters(in: .whitespacesAndNewlines)
        if let code, trimmed.hasPrefix("\(code): ") {
            let rest = trimmed.dropFirst(code.count + 2).trimmingCharacters(in: .whitespacesAndNewlines)
            if !rest.isEmpty { return rest }
        }
        return trimmed
    }

    /// Whether a reply from the person would not be shared with agents: the
    /// mailbox's switch is off, or the message it answers is hidden too.
    public static func replyIsHidden(newest: MailMessage?, agentsSeeOwnerMail: Bool) -> Bool {
        guard let newest else { return !agentsSeeOwnerMail }
        return newest.agentVisible == false || !agentsSeeOwnerMail
    }

    /// The file name an exported mailbox is saved under: `mail-<address>.json`,
    /// the route's own rule (anything outside `[a-z0-9._-]` becomes a dash).
    public static func exportFilename(address: String?) -> String {
        let base = address ?? "mailbox"
        let safe = String(base.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") ? $0 : "-" })
        return "mail-\(safe).json"
    }
}

extension HVError {
    /// The sentence to show for a mail failure: the route's own, without the
    /// machine code it leads with.
    public var mailSentence: String {
        guard case .api(let failure) = self else { return userMessage }
        return MailText.plainSentence(failure.message, code: failure.code)
    }

    /// `503 mail_unavailable`: the database has not had the mail migration.
    public var isMailUnavailable: Bool {
        guard case .api(let failure) = self else { return false }
        return failure.status == 503 && failure.code == "mail_unavailable"
    }

    /// `403 missing_scope`: an agent key, not the person, lacked the scope (never the app's own call).
    public var isMailMissingScope: Bool { code == "missing_scope" }
}

// MARK: Moving a thread

/// What moving a whole thread to another folder would do, decided before anything is sent.
public enum MailMovePlan: Sendable, Equatable {
    /// These messages are elsewhere and each gets one `PATCH {folder}`.
    case move([String])
    /// Everything is already there.
    case nothing
    /// More messages than a move will take at once: nothing is moved, so it is never half moved.
    case tooMany(cap: Int)

    /// The most messages a move will take in one go.
    public static let cap = 500

    public static func make(messages: [MailMessage], to folder: MailFolder, cap: Int = MailMovePlan.cap) -> MailMovePlan {
        if messages.count > cap { return .tooMany(cap: cap) }
        let ids = messages.filter { $0.folder != folder }.map(\.id)
        return ids.isEmpty ? .nothing : .move(ids)
    }

    public var tooManySentence: String? {
        if case .tooMany(let cap) = self {
            return "This thread has more than \(cap) messages, which is too many to move from here. Nothing was moved."
        }
        return nil
    }
}
