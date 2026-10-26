import HyperVaultKit
import SwiftUI

/// One room: its roster, its transcript, and the round in flight. A round is
/// the person's message plus every turn it sets off; the server runs three
/// turns per request, so the model keeps asking until the queue is empty.
@MainActor
@Observable
final class ChatRoomModel {
    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var header: ChatRoomHeader?
    private(set) var members: [ChatRoomMember] = []
    private(set) var messages: [ChatRoomMessage] = []
    var draft = ""
    /// This phone is driving a round right now.
    private(set) var isDriving = false
    private(set) var notice: String?

    let roomID: String
    private let client: HVClient
    @ObservationIgnored private var driveTask: Task<Void, Never>?

    init(roomID: String, client: HVClient) {
        self.roomID = roomID
        self.client = client
    }

    // MARK: Derived

    var title: String { header?.title ?? "Room" }
    var pending: [ChatRoomTurn] { header?.pending ?? [] }
    var budget: Int { header?.budget ?? 0 }

    /// A round was left half done (here or elsewhere) and nobody is running it.
    var canContinue: Bool { !pending.isEmpty && !isDriving && header?.running != true }

    /// Members the draft addresses, in order; empty means everyone answers.
    var addressed: [String] {
        ChatRoomHandles.mentions(in: draft, handles: members.map(\.handle))
    }

    var canSend: Bool {
        !isDriving && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.count <= 100_000
    }

    // MARK: Loading

    func load() async {
        do {
            let detail = try await client.send(.room(id: roomID))
            header = detail.room
            members = detail.members
            messages = detail.messages.sorted { $0.position < $1.position }
            phase = .ready
        } catch let error as HVError {
            if messages.isEmpty { phase = .failed(error.userMessage) }
        } catch {
            if messages.isEmpty { phase = .failed(error.localizedDescription) }
        }
    }

    /// Asks only for what is new. Used while a round runs somewhere else.
    func refresh() async {
        guard phase == .ready, !isDriving else { return }
        let last = messages.last?.position ?? -1
        guard let detail = try? await client.send(.room(id: roomID, after: last)) else { return }
        header = detail.room
        members = detail.members.isEmpty ? members : detail.members
        merge(detail.messages)
    }

    // MARK: Talking

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isDriving else { return }
        draft = ""
        notice = nil
        isDriving = true
        let driver = ChatRoomDriver(client: client, roomID: roomID)
        let delivered = DeliveryFlag()
        driveTask = Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await driver.send(text) { run in
                    delivered.value = true
                    self.apply(run)
                }
                if outcome == .stalled { self.notice = "The room stopped answering. Continue to try again." }
            } catch let error as HVError {
                self.failed(error, restoring: delivered.value ? nil : text)
            } catch {
                self.notice = error.localizedDescription
            }
            self.finishDriving()
        }
    }

    /// Picks up a round that was left half done.
    func resume() {
        guard !isDriving else { return }
        notice = nil
        isDriving = true
        let driver = ChatRoomDriver(client: client, roomID: roomID)
        driveTask = Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await driver.resume { run in self.apply(run) }
                if outcome == .stalled { self.notice = "The room stopped answering. Continue to try again." }
            } catch let error as HVError {
                self.failed(error, restoring: nil)
            } catch {
                self.notice = error.localizedDescription
            }
            self.finishDriving()
        }
    }

    func stop() {
        driveTask?.cancel()
    }

    private func finishDriving() {
        isDriving = false
        driveTask = nil
        Task { await refresh() }
    }

    private func failed(_ error: HVError, restoring text: String?) {
        if case .cancelled = error {
            notice = "Stopped. Turns still waiting will stay queued."
            if let text, draft.isEmpty { draft = text }
            return
        }
        if let text, draft.isEmpty { draft = text }
        notice = error.sentence(offline: "Network hiccup. Your message may not have been sent. Check the room, then try again.")
    }

    private func apply(_ run: ChatRoomRun) {
        merge(run.messages)
        guard var current = header else { return }
        current.pending = run.pending
        current.budget = run.budget
        current.running = run.busy
        header = current
    }

    private func merge(_ incoming: [ChatRoomMessage]) {
        guard !incoming.isEmpty else { return }
        let seen = Set(messages.map(\.id))
        let fresh = incoming.filter { !seen.contains($0.id) }
        guard !fresh.isEmpty else { return }
        messages = (messages + fresh).sorted { $0.position < $1.position }
    }

    /// Adds a mention of `handle` at the end of the draft.
    func mention(_ handle: String) {
        let token = "@\(handle) "
        if draft.isEmpty || draft.hasSuffix(" ") || draft.hasSuffix("\n") {
            draft += token
        } else {
            draft += " " + token
        }
    }

    func dismissNotice() { notice = nil }

    // MARK: The room itself

    func rename(to name: String) async throws {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ChatRoomHandles.maxTitle))
        guard !clean.isEmpty, var current = header else { return }
        let previous = current.title
        current.title = clean
        header = current
        do {
            _ = try await client.send(.renameRoom(id: roomID, title: clean))
        } catch let error as HVError {
            current.title = previous
            header = current
            throw ChatActionError(message: error.sentence(offline: "Network hiccup. The room was not renamed."))
        }
    }

    func delete() async throws {
        do {
            _ = try await client.send(.deleteRoom(id: roomID))
        } catch let error as HVError {
            throw ChatActionError(message: error.sentence(offline: "Network hiccup. The room was not deleted."))
        }
    }

    func addMembers(_ drafts: [ChatRoomMemberDraft]) async throws {
        do {
            let added = try await client.send(.addRoomMembers(roomID: roomID, members: drafts))
            members = (members + added).sorted { $0.position < $1.position }
        } catch let error as HVError {
            throw ChatActionError(message: error.sentence(offline: "Network hiccup. The member was not added."))
        }
    }

    func remove(_ member: ChatRoomMember) async throws {
        guard let index = members.firstIndex(where: { $0.id == member.id }) else { return }
        let removed = members.remove(at: index)
        do {
            _ = try await client.send(.removeRoomMember(roomID: roomID, memberID: member.id))
        } catch let error as HVError {
            members.insert(removed, at: min(index, members.count))
            throw ChatActionError(message: error.sentence(offline: "Network hiccup. The member was not removed."))
        }
    }
}

/// Whether the person's message reached the server before something went wrong.
private final class DeliveryFlag: @unchecked Sendable {
    var value = false
}
