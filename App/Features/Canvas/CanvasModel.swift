import HyperVaultKit
import SwiftUI

/// One line in the canvas thread.
struct ThreadMessage: Identifiable, Equatable {
    enum Role { case user, assistant }

    let id: String
    let role: Role
    var content: String
    /// Only ever set on a reply the model cut off.
    var truncated = false
    /// The names of the pulled things the model was given for this reply.
    var using: [String] = []
    /// A line the page wrote itself, as the other side. It is not a reply: nothing was asked of a model.
    var isLocal = false
    /// Under a local question: the things to choose between.
    var choices: ThreadChoices?
}

struct ThreadChoices: Equatable {
    var items: [KeptItem]
    var more: Bool
}

/// One line under the cards: why a keep did not happen, or why there was nothing to keep.
struct KeepNotice: Equatable {
    enum Kind { case error, note }
    let kind: Kind
    let text: String
    /// The line is about a permission only Settings can change, so it offers the way there.
    var opensSettings = false
}

/// What a change to the field turned out to be.
enum FieldChange: Equatable {
    /// Typing, deleting, or a write the page made itself.
    case edited
    /// A block of text arrived at once. It is held above the field instead.
    case pasted
    /// Return was pressed. The line break is taken back out, and the page is to send.
    case returned
}

/// The canvas: a field, a short stack of cards and a thread. It follows the web
/// app's canvas closely (components/canvas/*) so the same words do the same
/// things on either: commands run without a model, pulling never guesses,
/// a long paste waits above the field to be kept or asked about.
@MainActor
@Observable
final class CanvasModel: CanvasCommandHost {
    // What the screen shows.
    private(set) var cards: [CanvasCard] = []
    private(set) var messages: [ThreadMessage] = []
    var draft = ""
    private(set) var staged: String?
    private(set) var isBusy = false
    private(set) var isKeeping = false
    private(set) var notice: KeepNotice?
    private(set) var chatError: String?
    private(set) var backends: [CanvasBackend] = []
    /// A read of the list of models has been answered, so an empty list means none is connected.
    private(set) var backendsLoaded = false
    private(set) var triedWithoutModel = false
    private(set) var isAsking = false

    /// Set when a command wants the Yours panel; the view presents it and clears this.
    var wantsYours = false

    // Wiring.
    @ObservationIgnored private let client: HVClient
    @ObservationIgnored let origin: URL?

    // Turn bookkeeping, as the web's use-canvas-chat keeps it.
    @ObservationIgnored private var conversationId: String?
    @ObservationIgnored private var thread = 0
    @ObservationIgnored private var sending = false
    @ObservationIgnored private var localKeys = 0
    @ObservationIgnored private var question = 0
    @ObservationIgnored private var keepInFlight = false
    /// Why the last read of the models failed, until one succeeds.
    @ObservationIgnored private var backendsFailure: Error?
    /// The last text the page wrote into the field itself, so the change it makes is not taken for a paste.
    @ObservationIgnored private var written: String?

    init(client: HVClient, origin: URL?) {
        self.client = client
        self.origin = origin
    }

    // MARK: Derived

    var hasModel: Bool { !backends.isEmpty }
    var needsModel: Bool { triedWithoutModel && backendsLoaded && backends.isEmpty }
    /// The opening page: nothing on it and nothing said, as the web's `quiet`. A reply on its way, a
    /// turn that failed and the word that nothing is connected are all things to show, so they end it.
    var isQuiet: Bool { cards.isEmpty && messages.isEmpty && !isBusy && chatError == nil && !needsModel }
    var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isBusy }
    /// Whether a paste can be asked about instead of kept: not once the list of models has been read and is empty.
    var canAsk: Bool { hasModel || !backendsLoaded }

    private func localKey() -> String {
        localKeys += 1
        return "local-\(localKeys)"
    }

    // MARK: Models

    func loadBackends() async {
        do {
            backends = try await client.send(.canvasBackends)
            backendsFailure = nil
            backendsLoaded = true
            if hasModel { triedWithoutModel = false }
        } catch is CancellationError {
            return
        } catch HVError.cancelled {
            // The screen went away or came back mid-read; the list there was is still the best there is.
            return
        } catch {
            // A failed read does not say that nothing is connected. The canvas still keeps and shows;
            // asking reads the list again and says what went wrong.
            backendsFailure = error
        }
    }

    // MARK: Sending

    /// The field's one verb: a command runs locally, an answer to "What do you want to keep?" is
    /// kept as it stands, and anything else goes to the model.
    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending, !keepInFlight else { return }

        if CanvasCommandRunner.run(text, host: self) {
            endAsking()
            draft = ""
            return
        }
        if isAsking {
            keepAsked(text)
            return
        }
        await chat(text)
    }

    /// The Return key, as the web's field takes it: with a paste waiting and nothing typed it keeps
    /// the paste, otherwise it sends.
    func submit() async {
        if staged != nil, draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            keepStaged()
        } else {
            await send()
        }
    }

    private func chat(_ text: String) async {
        let sentFrom = thread
        sending = true
        chatError = nil
        defer {
            if thread == sentFrom {
                sending = false
                isBusy = false
            }
        }
        // The list may be old: a model may have been connected since it was read, or the read may
        // have failed. Only a list that is read and still empty says that nothing can answer.
        if backends.isEmpty { await loadBackends() }
        guard thread == sentFrom else { return }
        guard let backend = backends.first else {
            if let failure = backendsFailure {
                chatError = Self.chatLine(for: failure)
            } else {
                triedWithoutModel = true
            }
            return
        }
        let userKey = localKey()
        isBusy = true
        messages.append(ThreadMessage(id: userKey, role: .user, content: text))
        draft = ""
        do {
            let turn = try await client.send(.canvasChat(
                backendId: backend.id,
                message: text,
                conversationId: conversationId,
                pulled: CanvasState.pulledRefs(cards)
            ))
            guard thread == sentFrom else { return }
            conversationId = turn.conversationId
            messages.append(ThreadMessage(
                id: turn.replyId ?? localKey(),
                role: .assistant,
                content: turn.content,
                truncated: turn.truncated,
                using: turn.pulledTitles
            ))
        } catch {
            guard thread == sentFrom else { return }
            fail(error, text: text, userKey: userKey)
        }
    }

    /// The turn did not get an answer: the text goes back to the field and its bubble comes off the
    /// page, unless the person has started on something else meanwhile.
    private func fail(_ error: Error, text: String, userKey: String) {
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.removeAll { $0.id == userKey }
            setDraft(text)
        }
        chatError = Self.chatLine(for: error)
        if chatError != nil { Haptics.failure() }
    }

    /// What a turn that did not get through says: the network in its own line, the server in its own
    /// words, anything else in the page's. A cancelled request says nothing; nothing went wrong.
    private static func chatLine(for error: Error) -> String? {
        if error is CancellationError { return nil }
        guard let hv = error as? HVError else { return HVCopy.chatFailedLine }
        if hv.isOffline { return HVCopy.chatOfflineLine }
        if case .cancelled = hv { return nil }
        return hv.userMessage
    }

    // MARK: Thread

    /// Writes a line into the thread as the other side without asking a model.
    @discardableResult
    func say(_ content: String, choices: ThreadChoices? = nil) -> String {
        let key = localKey()
        messages.append(ThreadMessage(id: key, role: .assistant, content: content, isLocal: true, choices: choices))
        return key
    }

    func dropLine(_ key: String) {
        messages.removeAll { $0.id == key }
    }

    /// Starts over with an empty thread. A turn still in flight is abandoned.
    func startNewThread() {
        thread += 1
        conversationId = nil
        sending = false
        messages = []
        isBusy = false
        chatError = nil
        triedWithoutModel = false
        endAsking()
    }

    func dismissChatError() { chatError = nil }

    // MARK: CanvasCommandHost

    func dispatch(_ action: CanvasAction) {
        cards = CanvasState.reduce(cards, action)
    }

    func clearThread() {
        startNewThread()
    }

    func help() {
        say(HVCopy.helpLine)
        if backendsLoaded, backends.isEmpty { triedWithoutModel = true }
    }

    func keepThis() {
        guard !keepInFlight else { return }
        if staged != nil {
            keepStaged()
            return
        }
        if let index = messages.lastIndex(where: { $0.role == .assistant && !$0.isLocal }) {
            keepReply(at: index)
            return
        }
        notice = KeepNotice(kind: .note, text: HVCopy.nothingToKeepLine)
    }

    func show(_ target: ShowTarget) {
        if target == .stuff {
            wantsYours = true
            return
        }
        let filter: YoursFilter = target == .memories ? .memory : target == .files ? .file : .key
        Task {
            do {
                let list = try await client.send(.yours(filter: filter, limit: canvasMaxCards))
                guard !list.results.isEmpty else {
                    say(HVCopy.showNoneLine(target))
                    return
                }
                for item in list.results.prefix(canvasMaxCards).reversed() { addCard(for: item) }
            } catch {
                say((error as? HVError)?.userMessage ?? HVCopy.yoursFailedLine)
            }
        }
    }

    func showAgentKeys() {
        show(.keys)
    }

    func pull(_ query: String) {
        Task {
            do {
                let list = try await client.send(.yours(filter: .all, query: query, limit: PullResolver.searchLimit))
                switch PullResolver.resolve(query: query, results: list.results) {
                case .one(let item):
                    pullItem(item)
                case .choose(let items, let more):
                    say(HVCopy.pullWhichLine, choices: ThreadChoices(items: items, more: more))
                case .none:
                    say(HVCopy.pullNoneLine)
                }
            } catch {
                say((error as? HVError)?.userMessage ?? HVCopy.yoursFailedLine)
            }
        }
    }

    func pullLink(_ link: VaultLink) {
        Task {
            do {
                let detail: KeptCard
                switch link {
                case .artifact(let slug): detail = try await client.send(.card(slug: slug))
                case .memory(let id): detail = try await client.send(.card(kind: .memory, id: id))
                }
                let card = CanvasState.payloadCard(detail)
                dispatch(.add(card))
                markOpened(card)
            } catch let error as HVError where error.isNotFound {
                say(HVCopy.pullNoneLine)
            } catch {
                say((error as? HVError)?.userMessage ?? HVCopy.yoursFailedLine)
            }
        }
    }

    /// A choice from "Which one?": pulls it and takes the question off the page.
    func choose(_ item: KeptItem, answering key: String) {
        dropLine(key)
        pullItem(item)
    }

    /// Puts something a person chose on the page, and notes the open as a tap in Yours does, so it is
    /// first in Yours next time. "Show my ..." is not this: nothing was opened, only shown.
    func pullItem(_ item: KeptItem) {
        addCard(for: item)
        markOpened(kind: item.kind, id: item.id)
    }

    /// Puts something from Yours on the page, then asks the server what to say about it.
    private func addCard(for item: KeptItem) {
        let card = CanvasState.itemCard(item)
        dispatch(.add(card))
        Haptics.tap()
        Task { await fill(card) }
    }

    private func fill(_ card: CanvasCard) async {
        guard let ref = card.ref else { return }
        do {
            let detail = try await client.send(.card(kind: ref.kind, id: ref.id))
            dispatch(.fill(key: card.key, detail: detail, subtitle: CanvasState.detailLine(detail), title: detail.name))
        } catch {
            // The card is already useful without its detail line.
        }
    }

    /// Records that a card was opened, so Recent follows what was gone back to. Best effort.
    func markOpened(_ card: CanvasCard) {
        guard let ref = card.ref else { return }
        markOpened(kind: ref.kind, id: ref.id)
    }

    private func markOpened(kind: KeptKind, id: String) {
        Task { _ = try? await client.send(.markOpened(kind: kind, id: id)) }
    }

    // MARK: The field

    /// Every write to the field that is not the person typing or pasting: a restored question, the
    /// paste taken back out of its chip, words from dictation. The change it makes is the page's own,
    /// so it is never taken for a paste.
    func setDraft(_ text: String) {
        // No change means no `draftChanged`, which would be the only thing to clear the mark.
        guard text != draft else { return }
        written = text
        draft = text
    }

    /// The field changed, and this reads what the person did from the change itself, since the field
    /// gives no paste event and no Return. A block of text arriving in one step is a paste: it is held
    /// above the field instead, to be kept or asked about. A lone line break is Return: a field that
    /// grows with its text breaks the line on it instead of submitting, whatever its Send key says.
    @discardableResult
    func draftChanged(from old: String, to new: String) -> FieldChange {
        if let mine = written {
            written = nil
            if mine == new { return .edited }
        }
        guard let inserted = PasteDiff.insertion(old: old, new: new) else { return .edited }
        if inserted == "\n" {
            draft = old
            return .returned
        }
        guard PasteStaging.shouldStage(inserted) else { return .edited }
        draft = old
        stagePaste(inserted)
        return .pasted
    }

    // MARK: Keeping

    /// A paste the person made, held above the field. A second one joins the first.
    func stagePaste(_ text: String) {
        notice = nil
        endAsking()
        staged = staged.map { "\($0)\n\n\(text)" } ?? text
    }

    /// Handles a paste into the field: long things wait above it, a sentence goes in.
    func handlePaste(_ text: String) {
        if PasteStaging.shouldStage(text) {
            stagePaste(text)
        } else {
            setDraft(draft + text)
        }
    }

    func keepStaged() {
        guard let text = staged, !keepInFlight else { return }
        staged = nil
        endAsking()
        run(text, sourcePrompt: nil) { [weak self] failed in self?.restage(failed) }
    }

    /// Takes the waiting paste back out of the chip, to ask about it instead.
    func askInstead() {
        guard let text = staged else { return }
        staged = nil
        endAsking()
        setDraft(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : "\(draft)\n\n\(text)")
    }

    private func restage(_ content: String) {
        staged = staged.map { "\(content)\n\n\($0)" } ?? content
    }

    /// "New" has asked what to keep; the next thing sent is it.
    func ask() {
        notice = nil
        question += 1
        isAsking = true
        say(HVCopy.newAskLine)
    }

    private func endAsking() {
        question += 1
        isAsking = false
    }

    private func keepAsked(_ text: String) {
        let asked = question
        isAsking = false
        draft = ""
        run(text, sourcePrompt: nil) { [weak self] failed in
            guard let self else { return }
            if question == asked { isAsking = true }
            if draft.trimmingCharacters(in: .whitespaces).isEmpty { setDraft(failed) }
        }
    }

    /// Keeps the reply at this place in the thread.
    func keepReply(at index: Int) {
        guard messages.indices.contains(index), messages[index].role == .assistant, !keepInFlight,
              let content = KeepReply.content(of: messages[index].content)
        else { return }
        let asked = index > 0 && messages[index - 1].role == .user ? messages[index - 1].content : nil
        run(content, sourcePrompt: asked, onFailed: nil)
    }

    /// Keeps text that arrived from outside (the share sheet, a Shortcut, a link).
    func keepExternal(_ text: String) {
        run(text, sourcePrompt: nil) { [weak self] failed in self?.restage(failed) }
    }

    private func run(_ content: String, sourcePrompt: String?, onFailed: ((String) -> Void)?) {
        keepInFlight = true
        isKeeping = true
        notice = nil
        Task {
            defer {
                keepInFlight = false
                isKeeping = false
            }
            do {
                let kept = try await client.send(.keep(content: content, sourcePrompt: sourcePrompt.flatMap { SourcePrompt.clipped($0) }))
                dispatch(.add(CanvasState.keptCard(kept, origin: origin ?? client.baseURL)))
                Haptics.success()
                WidgetRefresh.reload()
            } catch {
                let message: String
                if let hv = error as? HVError {
                    message = hv.isOffline ? HVCopy.keepOfflineLine : hv.userMessage
                } else {
                    message = HVCopy.keepFailedLine
                }
                notice = KeepNotice(kind: .error, text: message)
                Haptics.failure()
                onFailed?(content)
            }
        }
    }

    func dismissNotice() { notice = nil }

    /// Dictation did not start: say why under the cards, and for a permission that is refused, where to change it.
    func dictationFailed(_ problem: DictationProblem) {
        notice = KeepNotice(kind: .note, text: problem.line, opensSettings: problem == .denied)
    }
}
