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
    @ObservationIgnored private let announcer: SpeechAnnouncer
    @ObservationIgnored private var driveTask: Task<Void, Never>?
    /// The Continue card is on screen and VoiceOver has been told about it.
    @ObservationIgnored private var continueAnnounced = false

    init(roomID: String, client: HVClient, announcer: SpeechAnnouncer = VoiceOverAnnouncer.shared) {
        self.roomID = roomID
        self.client = client
        self.announcer = announcer
    }

    // MARK: Derived

    var title: String { header?.title ?? "Room" }
    var pending: [ChatRoomTurn] { header?.pending ?? [] }
    var budget: Int { header?.budget ?? 0 }

    /// A round was left half done (here or elsewhere) and nobody is running it.
    var canContinue: Bool { !pending.isEmpty && !isDriving && header?.running != true }

    /// What the empty message box suggests: a way of addressing the members this room has, in the form
    /// the server reads as an address ("grok, ..." at the start of a clause).
    var composerPrompt: String {
        let handles = members.map(\.handle)
        switch handles.count {
        case 0: return "Say something to the room"
        case 1: return "\(handles[0]), what do you think?"
        default: return "\(handles[0]), draft it. \(handles[1]), review it."
        }
    }

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
            announceContinueCard()
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
        announceContinueCard()
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
                if outcome == .stalled { self.tell("The room stopped answering. Continue to try again.") }
            } catch let error as HVError {
                self.failed(error, restoring: delivered.value ? nil : text)
            } catch {
                self.tell(error.localizedDescription)
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
                if outcome == .stalled { self.tell("The room stopped answering. Continue to try again.") }
            } catch let error as HVError {
                self.failed(error, restoring: nil)
            } catch {
                self.tell(error.localizedDescription)
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
        // Whatever stopped the round has just told the person so, and what to do about it.
        continueAnnounced = canContinue
        Task { await refresh() }
    }

    private func failed(_ error: HVError, restoring text: String?) {
        if case .cancelled = error {
            tell("Stopped. Turns still waiting will stay queued.")
            if let text, draft.isEmpty { draft = text }
            return
        }
        if let text, draft.isEmpty { draft = text }
        tell(error.sentence(offline: "Network hiccup. Your message may not have been sent. Check the room, then try again."))
    }

    /// A line under the thread, said as well as shown: it appears where VoiceOver is not looking.
    private func tell(_ text: String) {
        notice = text
        announcer.announce(text)
    }

    /// Turns left waiting with nobody running them put a Continue card at the end of the thread.
    private func announceContinueCard() {
        guard canContinue else {
            continueAnnounced = false
            return
        }
        guard !continueAnnounced else { return }
        continueAnnounced = true
        announcer.announce("\(pending.count) turn\(pending.count == 1 ? "" : "s") still waiting. Nobody is running this round. Continue is under the messages.")
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
        if let spoken = Self.spokenAnswers(in: fresh) { announcer.announce(spoken) }
    }

    /// Who answered, in one sentence, for what a request brought: a round hands back several at once, and the
    /// person's own message and the room's notes are not answers.
    static func spokenAnswers(in messages: [ChatRoomMessage]) -> String? {
        func names(_ list: [ChatRoomMessage]) -> String {
            var handles: [String] = []
            for message in list {
                let name = message.senderHandle.map { "@\($0)" } ?? "A member"
                if !handles.contains(name) { handles.append(name) }
            }
            if handles.count > 3 { return "\(handles.count) members" }
            if handles.count == 1 { return handles[0] }
            return handles.dropLast().joined(separator: ", ") + " and " + handles[handles.count - 1]
        }
        let agents = messages.filter { $0.senderKind == .agent }
        let answered = agents.filter { !$0.failed }
        let failed = agents.filter(\.failed)
        var sentences: [String] = []
        if !answered.isEmpty { sentences.append("\(names(answered)) replied.") }
        if !failed.isEmpty { sentences.append("\(names(failed)) could not answer.") }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
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
