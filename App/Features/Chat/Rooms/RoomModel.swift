import HyperVaultKit
import SwiftUI

/// One room: its roster, its transcript, and the round in flight. A round is the person's message plus every turn it
/// sets off. Two things work on it, and neither waits for the other:
///
/// - the follower (`follow()`, tied to the screen) reads the room from the server while the screen is up, and quickly
///   while a round moves, so the person's message, each answer and who is thinking appear when they happen, whatever
///   became of the request that set them off;
/// - the driver (`send()`, `resume()`) pushes the queue along, one turn per request.
///
/// What is on screen is what the server's reads say. The answer to a post or a run is shown at once but is only a hint
/// (it never moves the place the next read starts from), and a request that ends badly is followed by a read of the room
/// before anything is said about the person's message.
@MainActor
@Observable
final class ChatRoomModel {
    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    /// What the person said, on its way to the server. It is in the thread at once and leaves it when the room reports
    /// the message (from the answer to the post or from a read, whichever comes first), or when the message is given back.
    struct Outgoing: Identifiable, Equatable {
        let id = UUID().uuidString
        let text: String
    }

    private(set) var phase: Phase = .loading
    private(set) var header: ChatRoomHeader?
    private(set) var members: [ChatRoomMember] = []
    private(set) var transcript = ChatRoomTranscript()
    private(set) var outgoing: [Outgoing] = []
    var draft = ""
    /// Counts the times code, not the person's typing, replaced `draft` (a message was sent, or words were put back).
    /// The text field takes a new identity with each one (`hvFieldReset`), so it starts again from what `draft` says.
    private(set) var composerEpoch = 0
    /// This phone is driving a round right now.
    private(set) var isDriving = false
    private(set) var notice: String?

    let roomID: String
    private let client: HVClient
    private let pace: ChatRoomPace
    @ObservationIgnored private let announcer: SpeechAnnouncer
    /// iOS lends a little time to finish a turn when the person leaves the app, as it does for the 1:1 chat.
    @ObservationIgnored private let grace = ChatBackgroundGrace()
    @ObservationIgnored private var driveTask: Task<Void, Never>?
    /// The Continue card is on screen and VoiceOver has been told about it.
    @ObservationIgnored private var continueAnnounced = false
    /// What the server last said the room is called and who is in it. A read that only repeats it is not news, and must
    /// not undo what the person has since done here (a rename, or a member taken out, is shown before the server has it).
    @ObservationIgnored private var serverTitle: String?
    @ObservationIgnored private var serverMembers: [ChatRoomMember]?
    /// Reads in a row that found the room gone. A server in the middle of a deploy answers one too, so it takes a few.
    @ObservationIgnored private var notFoundReads = 0

    init(roomID: String, client: HVClient, announcer: SpeechAnnouncer = VoiceOverAnnouncer.shared, pace: ChatRoomPace = .live) {
        self.roomID = roomID
        self.client = client
        self.announcer = announcer
        self.pace = pace
    }

    // MARK: Derived

    var title: String { header?.title ?? "Room" }
    var messages: [ChatRoomMessage] { transcript.messages }
    var pending: [ChatRoomTurn] { header?.pending ?? [] }
    var budget: Int { header?.budget ?? 0 }

    /// What the line under the thread says: only what the server and this phone know to be so.
    var activity: ChatRoomActivity {
        ChatRoomActivity.resolve(header: header, sending: !outgoing.isEmpty, driving: isDriving)
    }

    /// A round was left half done (here or elsewhere), or a turn was lost, and nobody is running it.
    var canContinue: Bool { !isDriving && (header?.canBeContinued ?? false) }

    /// Something is moving: the follower asks quickly while it is, and rarely when it is not.
    private var isMoving: Bool { isDriving || !outgoing.isEmpty || header?.running == true }

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

    // MARK: Loading and following

    /// Opens the room: its roster and the newest of its transcript.
    func load() async {
        do {
            applyRead(try await client.send(.room(id: roomID)))
        } catch let error as HVError {
            if transcript.messages.isEmpty { phase = .failed(error.userMessage) }
        } catch {
            if transcript.messages.isEmpty { phase = .failed(error.localizedDescription) }
        }
    }

    /// Reads what is new, once, and says whether the room could be reached. The follower does this on a schedule; a
    /// request that ends does it at once.
    @discardableResult
    func refresh() async -> Bool {
        guard phase == .ready else { return false }
        guard let detail = try? await client.send(.room(id: roomID, after: transcript.cursor)) else { return false }
        applyRead(detail)
        return true
    }

    /// Keeps the thread true to the server for as long as the screen is up (`.task { await model.follow() }`): quick
    /// while a round moves, slow when the room is quiet, nothing once the task is cancelled. A room that could not be
    /// opened opens itself on the follower's first read.
    func follow() async {
        let follower = ChatRoomFollower(client: client, roomID: roomID, pace: pace)
        await follower.follow(
            state: { [weak self] in ChatRoomFollowState(cursor: self?.transcript.cursor, isActive: self?.isMoving ?? false) },
            onSnapshot: { [weak self] detail in self?.applyRead(detail) },
            onFailure: { [weak self] error in self?.followFailed(error) }
        )
    }

    /// A read of the room. The first one is the opening of the screen; later ones add what is new and say where the
    /// round stands. A room that was said to be gone, and answers again, is open again.
    private func applyRead(_ detail: ChatRoomDetail) {
        notFoundReads = 0
        let opening = transcript.cursor == nil
        var room = detail.room
        // The server repeating the name it had before says nothing new, and must not undo a rename still on its way.
        if !opening, let shown = header?.title, room.title == serverTitle { room.title = shown }
        serverTitle = detail.room.title
        header = room
        if !detail.members.isEmpty {
            if opening || detail.members != serverMembers { members = detail.members }
            serverMembers = detail.members
        }
        let fresh = transcript.apply(detail)
        phase = .ready
        // What the opening holds was said before the person came; only what arrives after it is news.
        if !opening { adopt(fresh) }
        announceContinueCard()
    }

    /// What a post or a run answered: the messages it carries, and where the queue stands.
    private func applyRun(_ run: ChatRoomRun) {
        adopt(transcript.merge(run.messages))
        header = header?.applying(run)
    }

    /// New messages: the person's own replace what was shown while it travelled, and answers are said aloud.
    private func adopt(_ fresh: [ChatRoomMessage]) {
        guard !fresh.isEmpty else { return }
        for message in fresh where message.senderKind == .human {
            let said = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if let index = outgoing.firstIndex(where: { $0.text == said }) { outgoing.remove(at: index) }
        }
        if let spoken = Self.spokenAnswers(in: fresh) { announcer.announce(spoken) }
    }

    /// The follower could not read the room. Not finding it again and again means it was deleted somewhere else.
    private func followFailed(_ error: HVError) {
        guard error.isNotFound else {
            notFoundReads = 0
            return
        }
        notFoundReads += 1
        if notFoundReads >= 3 { phase = .failed(error.userMessage) }
    }

    // MARK: Talking

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isDriving else { return }
        replaceDraft("")
        notice = nil
        isDriving = true
        let echo = Outgoing(text: text)
        outgoing.append(echo)
        grace.begin("HyperVault room turn")
        let driver = ChatRoomDriver(client: client, roomID: roomID, pace: pace)
        driveTask = Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await driver.send(text) { run in self.applyRun(run) }
                // The post was answered, so the room has the message: whatever copy of it is still travelling is done.
                self.outgoing.removeAll { $0.id == echo.id }
                if outcome == .stalled { self.tell("The room stopped answering. Continue to try again.") }
            } catch let error as HVError {
                await self.failed(error, echo: echo)
            } catch {
                await self.failed(.transport(error.localizedDescription), echo: echo)
            }
            self.finishDriving()
        }
    }

    /// Picks up a round that was left half done.
    func resume() {
        guard !isDriving else { return }
        notice = nil
        isDriving = true
        grace.begin("HyperVault room turn")
        let driver = ChatRoomDriver(client: client, roomID: roomID, pace: pace)
        driveTask = Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await driver.resume { run in self.applyRun(run) }
                if outcome == .stalled { self.tell("The room stopped answering. Continue to try again.") }
            } catch let error as HVError {
                await self.failed(error, echo: nil)
            } catch {
                await self.failed(.transport(error.localizedDescription), echo: nil)
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
        grace.end()
        // Whatever stopped the round has just told the person so, and what to do about it.
        continueAnnounced = canContinue
        Task { await refresh() }
    }

    /// A request ended badly. The server may have the message, and may be at work on it: look before saying anything.
    private func failed(_ error: HVError, echo: Outgoing?) async {
        let read = await readRoom()
        // Gone from `outgoing` means a read or an answer reported it. Still there after a read of the room: not sent.
        // Still there and the room could not be read: not known, and the words go back all the same, with a notice that
        // says so, rather than being lost.
        var delivered = true
        if let echo {
            delivered = !outgoing.contains { $0.id == echo.id }
            if !delivered {
                outgoing.removeAll { $0.id == echo.id }
                if draft.isEmpty { replaceDraft(echo.text) }
            }
        }
        if case .cancelled = error {
            tell("Stopped. Turns still waiting will stay queued.")
            return
        }
        // The message arrived and the room is at work on it (only the answer to this request was lost): the thread
        // shows what happens as it does, and an error would be wrong.
        if delivered, header?.running == true { return }
        let offline: String
        if delivered {
            offline = "Network hiccup. Check the room for what it has said."
        } else if read {
            offline = "Network hiccup. Your message was not sent. Try again."
        } else {
            offline = "Network hiccup. Your message may not have been sent. Check the room, then try again."
        }
        tell(error.sentence(offline: offline))
    }

    /// One read of the room, in a task of its own: the task that asks may be cancelled (Stop), and a cancelled task
    /// cannot make a request.
    private func readRoom() async -> Bool {
        await Task { await self.refresh() }.value
    }

    /// A line under the thread, said as well as shown: it appears where VoiceOver is not looking.
    private func tell(_ text: String) {
        notice = text
        announcer.announce(text)
    }

    /// Turns left waiting with nobody running them (or a turn that was lost) put a Continue card at the end of the thread.
    private func announceContinueCard() {
        guard canContinue else {
            continueAnnounced = false
            return
        }
        guard !continueAnnounced else { return }
        continueAnnounced = true
        let count = pending.count
        if count == 0 {
            announcer.announce("A turn was cut off and nobody is running this round. Continue is under the messages.")
        } else {
            announcer.announce("\(count) turn\(count == 1 ? "" : "s") still waiting. Nobody is running this round. Continue is under the messages.")
        }
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

    /// What the text field writes when the person types. A field that `replaceDraft` has since replaced could still write
    /// the words it held as it goes; those are not typing, and are dropped.
    func fieldWrote(_ text: String, epoch: Int) {
        guard epoch == composerEpoch else { return }
        draft = text
    }

    /// Every write to `draft` that is not the person typing (or adding a mention) goes through here.
    private func replaceDraft(_ text: String) {
        draft = text
        composerEpoch &+= 1
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
        guard !clean.isEmpty, let previous = header?.title else { return }
        header?.title = clean
        do {
            _ = try await client.send(.renameRoom(id: roomID, title: clean))
        } catch let error as HVError {
            // Only the name goes back: the rest of the header has moved on while the request was out.
            header?.title = previous
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
