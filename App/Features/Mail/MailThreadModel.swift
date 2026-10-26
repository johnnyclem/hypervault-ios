import HyperVaultKit
import SwiftUI

/// One conversation, oldest to newest. It reads the thread, clears what was
/// unread in it, answers it, and moves all of it.
@MainActor
@Observable
final class MailThreadModel {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    /// Oldest first.
    private(set) var messages: [MailMessage] = []
    private(set) var olderCursor: String?
    private(set) var isLoadingOlder = false
    private(set) var isSending = false
    private(set) var isMoving = false
    private(set) var threadID: String
    private(set) var mailbox: String?
    private(set) var agentsSeeOwnerMail: Bool

    @ObservationIgnored private let client: HVClient
    @ObservationIgnored private var marked = Set<String>()

    init(client: HVClient, threadID: String, mailbox: String?, agentsSeeOwnerMail: Bool = true) {
        self.client = client
        self.threadID = threadID
        self.mailbox = mailbox
        self.agentsSeeOwnerMail = agentsSeeOwnerMail
    }

    private var service: MailService { MailService(client: client) }

    var newest: MailMessage? { messages.last }

    /// The subject a person reads: the newest message's, without stacked "Re:".
    var title: String {
        guard let newest else { return "Message" }
        return newest.displaySubject
    }

    /// A reply from the person that agents would not see.
    var replyIsHidden: Bool { MailText.replyIsHidden(newest: newest, agentsSeeOwnerMail: agentsSeeOwnerMail) }

    func isAnywhereElse(than folder: MailFolder) -> Bool { messages.contains { $0.folder != folder } }

    // MARK: Loading

    func load() async {
        do {
            if let mailbox {
                let page = try await client.send(.mailThread(threadId: threadID, mailbox: mailbox))
                guard !page.messages.isEmpty else { throw HVError.api(APIFailure(status: 404, message: "That conversation is not here any more.")) }
                apply(page)
            } else {
                try await findAcrossMailboxes()
            }
            phase = .loaded
            await markUnreadMessagesRead(messages)
        } catch {
            phase = .failed(MailModel.sentence(error))
        }
    }

    /// A link carries a thread id (or a message id) and no mailbox: look in each
    /// mailbox, the primary first, until it is found.
    private func findAcrossMailboxes() async throws {
        let list = try await client.send(.mailMailboxes)
        let candidates: [String?] = list.mailboxes.isEmpty ? [nil] : list.mailboxes.map { Optional($0.id) }
        for candidate in candidates {
            if let page = try? await client.send(.mailThread(threadId: threadID, mailbox: candidate)), !page.messages.isEmpty {
                adopt(mailbox: candidate, from: list.mailboxes)
                apply(page)
                return
            }
            if let found = try? await client.send(.mailMessage(id: threadID, mailbox: candidate, markRead: false)),
               let page = try? await client.send(.mailThread(threadId: found.message.threadId, mailbox: candidate)),
               !page.messages.isEmpty {
                threadID = found.message.threadId
                adopt(mailbox: candidate, from: list.mailboxes)
                apply(page)
                return
            }
        }
        throw HVError.api(APIFailure(status: 404, message: "That conversation is not here any more."))
    }

    private func adopt(mailbox id: String?, from mailboxes: [OwnerMailbox]) {
        mailbox = id
        if let id, let match = mailboxes.first(where: { $0.id == id }) { agentsSeeOwnerMail = match.agentsSeeOwnerMail }
    }

    private func apply(_ page: MailMessagePage) {
        messages = page.messages
        olderCursor = page.nextCursor
    }

    func loadOlder() async throws {
        guard let cursor = olderCursor, !isLoadingOlder else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        let page = try await client.send(.mailThread(threadId: threadID, mailbox: mailbox, cursor: cursor))
        messages = MailThreads.appendUnique(page.messages, messages)
        olderCursor = page.nextCursor
        await markUnreadMessagesRead(page.messages)
    }

    /// Clears the unread bit on what the person has now seen, a few at a time,
    /// and mirrors what the server accepted.
    private func markUnreadMessagesRead(_ page: [MailMessage]) async {
        let ids = page.filter { $0.unread && !marked.contains($0.id) }.map(\.id)
        guard !ids.isEmpty else { return }
        ids.forEach { marked.insert($0) }
        let cleared = Set(await service.markRead(ids, mailbox: mailbox))
        for id in ids where !cleared.contains(id) { marked.remove(id) }
        guard !cleared.isEmpty else { return }
        messages = messages.map { cleared.contains($0.id) ? $0.withUnread(false) : $0 }
    }

    // MARK: Acting

    /// Answers the newest message. The reply goes to `self`, the agents' side.
    func reply(_ text: String) async throws {
        guard let newest, !isSending else { return }
        isSending = true
        defer { isSending = false }
        _ = try await client.send(.mailReply(id: newest.id, text: text, mailbox: mailbox))
        let page = try await client.send(.mailThread(threadId: threadID, mailbox: mailbox))
        messages = MailThreads.mergeNewest(messages, page.messages)
    }

    func move(to folder: MailFolder) async throws -> MailMoveResult {
        guard !isMoving else { return .nothing }
        isMoving = true
        defer { isMoving = false }
        let result = try await service.moveThread(id: threadID, mailbox: mailbox, loaded: messages, olderCursor: olderCursor, to: folder)
        if case .moved = result { messages = messages.map { $0.withFolder(folder) } }
        return result
    }
}
