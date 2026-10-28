import HyperVaultKit
import SwiftUI

/// Which model answers: one of the person's connected models, or this phone.
enum ChatModelChoice: Hashable {
    case server(String)
    case onDevice
    /// A model on the person's own network, called by this phone.
    case local(String)
}

/// What "Keep" made of a reply, shown under it.
struct ChatKeptNote: Equatable {
    let slug: String?
    let url: URL?
    let duplicate: Bool
    let isPrivate: Bool

    var line: String { duplicate ? HVCopy.alreadyKeptLine : HVCopy.keptLine }
}

/// The settings sheet's switches.
enum ChatSetting {
    case smartContext, deepMemory, truth
}

/// A conversation on screen: its thread, the model that answers, and the
/// turn in flight. The server holds the history, so changing the model between
/// turns loses nothing; a new conversation exists only on the server after its
/// first turn.
@MainActor
@Observable
final class ChatConversationModel {
    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    // What it needs.
    private let client: HVClient
    private let cache: DiskCache
    private let namespace: String
    private let limits: Capabilities.Limits
    private let features: Capabilities.Features
    private let onDevice: ChatOnDeviceSupport
    private let outbox: ChatTurnOutbox
    private let defaults: UserDefaults
    private let initialID: String?
    /// Names this thread while it has no id, so on-device turns waiting to be
    /// saved land in one conversation.
    private let threadKey = UUID().uuidString

    // What the screen shows.
    private(set) var phase: Phase = .loading
    private(set) var conversation: ChatConversation?
    private(set) var rows: [ChatThreadRow] = []
    private(set) var isStale = false
    private(set) var backends: [ChatBackend] = []
    private(set) var backendsLoaded = false
    private(set) var localModels: [ChatLocalModel] = []
    var choice: ChatModelChoice?
    private(set) var settings = ChatSettings()
    private(set) var hasToolkit = false
    var useRecall = true
    /// The memory branches recall can draw from. Recall is a plain switch until there is more than one.
    private(set) var recallBranches: [MindBranch] = []
    /// The branch recall draws from: main, unless the person chose another. Lasts as long as this chat is open,
    /// like the switches beside it.
    private(set) var recallBranch = MindBranchName.defaultName
    var useTools = true
    var draft = ""
    private(set) var isWorking = false
    private(set) var workStarted: Date?
    /// A calm line under the thread: what stopped, or what to know.
    private(set) var notice: String?
    private(set) var toolNotice: String?
    private(set) var keptNotes: [String: ChatKeptNote] = [:]

    @ObservationIgnored private let grace = ChatBackgroundGrace()
    @ObservationIgnored private var turnTask: Task<Void, Never>?
    @ObservationIgnored private var knownServerMessages = 0
    @ObservationIgnored private var didSend = false

    init(
        conversationID: String?,
        client: HVClient,
        cache: DiskCache,
        namespace: String,
        limits: Capabilities.Limits,
        features: Capabilities.Features,
        onDevice: ChatOnDeviceSupport,
        outbox: ChatTurnOutbox,
        defaults: UserDefaults = .standard
    ) {
        self.initialID = conversationID
        self.client = client
        self.cache = cache
        self.namespace = namespace
        self.limits = limits
        self.features = features
        self.onDevice = onDevice
        self.outbox = outbox
        self.defaults = defaults
    }

    // MARK: Derived

    var conversationID: String? { conversation?.id ?? initialID }

    var title: String {
        let name = conversation?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "New chat" : name
    }

    var onDeviceStatus: ChatOnDeviceStatus { onDevice.status() }

    var onDeviceUsable: Bool { features.onDeviceInference && onDevice.status().isAvailable }

    var canChat: Bool { choice != nil }

    var maxCharacters: Int { limits.chatMessageChars }

    /// Whether Recall is a picker of branches (and Off) instead of a switch.
    var showsRecallBranches: Bool { recallBranches.count > 1 }

    /// What the Recall picker shows: the branch the reply is grounded in, or nil when recall is off.
    var recallChoice: String? { useRecall ? recallBranch : nil }

    var showsDeepMemory: Bool { features.deepMemory }

    var showsTruth: Bool { features.truthLedger }

    var draftTooLong: Bool { draft.count > limits.chatMessageChars }

    var canSend: Bool {
        !isWorking && canChat && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !draftTooLong
    }

    var isOnDevice: Bool { choice == .onDevice }

    /// The phone writes this reply (itself, or from a model on its network): no
    /// server-side tools, and the reply streams.
    var runsLocally: Bool {
        switch choice {
        case .onDevice, .local: return true
        default: return false
        }
    }

    /// The one calm line under the thread while a local model is chosen.
    var toolFreeLine: String? {
        switch choice {
        case .onDevice: return ChatOnDeviceModels.toolFreeLine
        case .local: return "Answering from your model on your network. Tools need a connected model."
        default: return nil
        }
    }

    var selectedBackend: ChatBackend? {
        if case .server(let id) = choice { return backends.first { $0.id == id } }
        return nil
    }

    var selectedLocal: ChatLocalModel? {
        if case .local(let id) = choice { return localModels.first { $0.id == id } }
        return nil
    }

    /// Short name for the model chip.
    var modelName: String {
        switch choice {
        case .onDevice: return ChatOnDeviceModels.title
        case .server: return selectedBackend?.name ?? "Model"
        case .local: return selectedLocal?.displayName ?? "Model"
        case nil: return backendsLoaded ? "Connect a model" : "Model"
        }
    }

    /// The assistant row being written by a local model right now.
    var isStreaming: Bool {
        rows.last.map { $0.kind == .assistant && $0.state == .streaming && !$0.text.isEmpty } ?? false
    }

    var shareURL: URL? {
        guard let path = conversation?.sharePath else { return nil }
        return URL(string: path, relativeTo: client.baseURL)?.absoluteURL
    }

    /// The thread as a model on this phone reads it.
    private var localHistory: [ChatWireMessage] {
        rows.compactMap { row -> ChatWireMessage? in
            guard !row.text.isEmpty else { return nil }
            if case .failed = row.state { return nil }
            switch row.kind {
            case .user:
                return ChatWireMessage(role: .user, content: row.text)
            case .assistant:
                if case .streaming = row.state { return nil }
                return ChatWireMessage(role: .assistant, content: row.text)
            case .tool:
                return nil
            }
        }
    }

    // MARK: Loading

    func load() async {
        async let sidecars: Void = loadSidecars()
        await loadConversation()
        await sidecars
    }

    func retryLoad() async {
        phase = .loading
        await load()
    }

    private func loadConversation() async {
        guard let id = initialID else {
            phase = .ready
            return
        }
        let client = self.client
        do {
            let stream = cachedLoad(cache: cache, namespace: namespace, key: "chat.conversation.\(id)") {
                try await client.send(.conversation(id: id))
            }
            for try await loaded in stream {
                // Never replace a thread the person has already added to.
                if didSend { continue }
                apply(loaded.value)
                isStale = loaded.isStale
                phase = .ready
            }
            if case .loading = phase { phase = .ready }
        } catch {
            if rows.isEmpty { phase = .failed(Self.sentence(error)) } else { phase = .ready }
        }
    }

    private func apply(_ detail: ChatConversationDetail) {
        conversation = detail.conversation
        rows = ChatThreadRow.hydrate(detail.messages)
        knownServerMessages = detail.messages.count
    }

    private func loadSidecars() async {
        localModels = onDevice.localModels()
        let client = self.client
        async let fetchedSettings = try? await client.send(.chatSettings)
        async let fetchedToolkit = try? await client.send(.toolkitStatus)
        async let fetchedBranches = try? await client.send(.mindBranches)
        do {
            let stream = cachedLoad(cache: cache, namespace: namespace, key: "chat.backends") {
                try await client.send(.backends)
            }
            for try await loaded in stream {
                backends = loaded.value
                backendsLoaded = true
                chooseDefaultIfNeeded()
            }
        } catch {
            backendsLoaded = true
            chooseDefaultIfNeeded()
        }
        if let value = await fetchedSettings { settings = value }
        if let value = await fetchedToolkit { hasToolkit = value.hasToolkit }
        if let value = await fetchedBranches { setRecallBranches(value.ordered) }
    }

    /// A branch that is gone (deleted elsewhere) is replaced by main, as the web's composer does.
    private func setRecallBranches(_ branches: [MindBranch]) {
        recallBranches = branches
        if !branches.contains(where: { $0.name == recallBranch }) { recallBranch = MindBranchName.defaultName }
    }

    /// Pull to refresh: the thread as the server has it now (it may have been
    /// continued elsewhere). Left alone while something on this phone is unsaved.
    func refresh() async {
        guard !isWorking, let id = conversationID else { return }
        let unsaved = rows.contains { row in
            switch row.state {
            case .waitingToSync, .notSaved, .failed, .sending, .streaming: return true
            case .saved: return false
            }
        }
        guard !unsaved, let detail = try? await client.send(.conversation(id: id)) else { return }
        apply(detail)
        isStale = false
    }

    /// Replays on-device turns that could not be saved while offline, and settles the rows that waited for
    /// them, in a chat that already existed as much as in one that is new: a turn that is saved gives its
    /// reply the server's id (so it can be rated), and one the server refused for good says so. Turns the
    /// outbox could not reach yet keep waiting.
    func syncOutbox() async {
        let report = await outbox.flush(client: client)
        let saved = report.saved.filter { $0.threadKey == threadKey }
        let refused = report.rejected.filter { $0.threadKey == threadKey }
        guard !saved.isEmpty || !refused.isEmpty else { return }
        if conversation == nil, let adopted = saved.first {
            let first = rows.first { $0.kind == .user }?.text ?? "New chat"
            conversation = ChatConversation(id: adopted.conversationID, title: String(first.prefix(80)), updatedAt: Date())
        }
        for turn in saved where settleWaitingRows(for: turn.userMessage, as: .saved, serverID: turn.messageID) {
            knownServerMessages += 2
        }
        for turn in refused {
            settleWaitingRows(for: turn.userMessage, as: .notSaved(turn.message), serverID: nil)
        }
        if let id = saved.last?.conversationID {
            Task { [cache, namespace] in
                await cache.remove(key: "chat.conversation.\(id)", namespace: namespace)
            }
        }
    }

    /// The oldest message still waiting with these words, and the reply that follows it.
    @discardableResult
    private func settleWaitingRows(for userMessage: String, as state: ChatThreadRow.State, serverID: String?) -> Bool {
        let words = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let user = rows.firstIndex(where: {
            $0.kind == .user && $0.state == .waitingToSync && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == words
        }) else { return false }
        rows[user].state = state
        if let reply = rows.indices.first(where: { $0 > user && rows[$0].kind == .assistant && rows[$0].state == .waitingToSync }) {
            rows[reply].state = state
            rows[reply].serverID = serverID
        }
        return true
    }

    // MARK: Choosing a model

    private enum DefaultsKey {
        static func lastBackend(_ namespace: String) -> String { "pref.chat.backend.\(namespace)" }
        static let lastLocal = "pref.chat.local"
    }

    private func chooseDefaultIfNeeded() {
        if let current = choice {
            switch current {
            case .onDevice:
                if onDeviceUsable { return }
            case .server(let id):
                if backends.contains(where: { $0.id == id }) { return }
            case .local(let id):
                if localModels.contains(where: { $0.id == id }) { return }
            }
            choice = nil
        }
        let remembered = defaults.string(forKey: DefaultsKey.lastBackend(namespace))
        let rememberedLocal = defaults.string(forKey: DefaultsKey.lastLocal)
        if defaults.bool(forKey: PrefKey.onDeviceChat), onDeviceUsable {
            choice = .onDevice
        } else if let rememberedLocal, localModels.contains(where: { $0.id == rememberedLocal }) {
            choice = .local(rememberedLocal)
        } else if let remembered, backends.contains(where: { $0.id == remembered }) {
            choice = .server(remembered)
        } else if let recent = backends.max(by: { ($0.lastUsedAt ?? .distantPast) < ($1.lastUsedAt ?? .distantPast) }) {
            choice = .server(recent.id)
        } else if onDeviceUsable {
            choice = .onDevice
        } else if let first = localModels.first {
            choice = .local(first.id)
        }
    }

    func select(_ newChoice: ChatModelChoice) {
        choice = newChoice
        switch newChoice {
        case .onDevice:
            defaults.set(true, forKey: PrefKey.onDeviceChat)
            defaults.removeObject(forKey: DefaultsKey.lastLocal)
        case .server(let id):
            defaults.set(false, forKey: PrefKey.onDeviceChat)
            defaults.set(id, forKey: DefaultsKey.lastBackend(namespace))
            defaults.removeObject(forKey: DefaultsKey.lastLocal)
        case .local(let id):
            defaults.set(false, forKey: PrefKey.onDeviceChat)
            defaults.set(id, forKey: DefaultsKey.lastLocal)
        }
    }

    /// Called when the Models screen changed the models on the person's network.
    func localModelsChanged(_ list: [ChatLocalModel]) {
        localModels = list
        chooseDefaultIfNeeded()
    }

    /// Called when the Models screen changed the list.
    func backendsChanged(_ list: [ChatBackend]) {
        backends = list
        backendsLoaded = true
        chooseDefaultIfNeeded()
    }

    // MARK: Context switches

    /// The Recall picker's choice: a branch to ground replies in, or nil to switch recall off.
    func chooseRecall(branch: String?) {
        guard let branch else {
            useRecall = false
            return
        }
        useRecall = true
        recallBranch = branch
    }

    private func sendOptions() -> ChatSendOptions {
        ChatSendOptions(
            useRecall: useRecall,
            // Main is what the route recalls from when it is not told a branch, as for the Memory tab's Ask.
            recallBranch: showsRecallBranches && recallBranch != MindBranchName.defaultName ? recallBranch : nil,
            smartContext: settings.smartContext,
            deepMemory: features.deepMemory ? settings.deepMemory : nil,
            truth: features.truthLedger ? settings.truth : nil,
            tools: hasToolkit ? useTools : nil
        )
    }

    func value(of setting: ChatSetting) -> Bool {
        switch setting {
        case .smartContext: return settings.smartContext
        case .deepMemory: return settings.deepMemory
        case .truth: return settings.truth
        }
    }

    /// Flips a switch now and saves it in the background; a failed save puts it back.
    func set(_ setting: ChatSetting, to value: Bool) async throws {
        let before = settings
        switch setting {
        case .smartContext: settings.smartContext = value
        case .deepMemory: settings.deepMemory = value
        case .truth: settings.truth = value
        }
        do {
            let endpoint: Endpoint<ChatSettings>
            switch setting {
            case .smartContext: endpoint = .updateChatSettings(smartContext: value)
            case .deepMemory: endpoint = .updateChatSettings(deepMemory: value)
            case .truth: endpoint = .updateChatSettings(truth: value)
            }
            settings = try await client.send(endpoint)
        } catch let error as HVError {
            settings = before
            throw ChatActionError(message: error.sentence(offline: "Network hiccup. That setting was not saved."))
        }
    }

    // MARK: Sending

    func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isWorking else { return }
        guard text.count <= limits.chatMessageChars else {
            notice = "Message is too long."
            return
        }
        guard choice != nil else {
            notice = HVCopy.noModelLine
            return
        }
        draft = ""
        start(text, toolChoice: nil, replacing: nil)
    }

    /// Runs the tool the person picked from the model's question.
    func choose(_ option: ChatToolSelection.Option, intent: String) {
        guard !isWorking else { return }
        start(
            "Use \u{201C}\(option.label)\u{201D}.",
            toolChoice: ChatToolChoice(option: option, intent: intent),
            replacing: nil
        )
    }

    /// Sends a message that failed again.
    func retry(_ row: ChatThreadRow) {
        guard !isWorking, row.kind == .user, case .failed = row.state else { return }
        start(row.text, toolChoice: nil, replacing: row.id)
    }

    /// Takes a failed message back into the composer to change it.
    func edit(_ row: ChatThreadRow) {
        guard row.kind == .user, case .failed = row.state else { return }
        rows.removeAll { $0.id == row.id }
        if draft.isEmpty { draft = row.text }
    }

    func stop() {
        turnTask?.cancel()
    }

    private func start(_ text: String, toolChoice: ChatToolChoice?, replacing failedID: String?) {
        guard let choice else { return }
        notice = nil
        toolNotice = nil
        if let failedID { rows.removeAll { $0.id == failedID } }
        let user = ChatThreadRow(kind: .user, text: text, state: .sending)
        rows.append(user)
        isWorking = true
        workStarted = Date()
        didSend = true
        grace.begin("HyperVault chat turn")
        turnTask = Task { [weak self] in
            guard let self else { return }
            switch choice {
            case .server(let backendID):
                await self.runServerTurn(text: text, userRowID: user.id, backendID: backendID, toolChoice: toolChoice)
            case .onDevice:
                await self.runLocalTurn(text: text, userRowID: user.id, provider: self.onDevice.makeProvider(), unavailable: self.onDevice.status().explanation)
            case .local(let id):
                let local = self.localModels.first { $0.id == id }
                await self.runLocalTurn(
                    text: text, userRowID: user.id, provider: local.flatMap { self.onDevice.makeLocalProvider($0) },
                    unavailable: "That model is no longer in your list. Choose another."
                )
            }
            self.isWorking = false
            self.workStarted = nil
            self.turnTask = nil
            self.grace.end()
        }
    }

    private func runServerTurn(text: String, userRowID: String, backendID: String, toolChoice: ChatToolChoice?) async {
        let startedAt = Date()
        var options = sendOptions()
        options.toolChoice = toolChoice
        do {
            let turn = try await client.send(
                .chat(backendID: backendID, message: text, conversationID: conversationID, options: options)
            )
            adopt(turn, text: text, userRowID: userRowID)
        } catch let error as HVError {
            await failServerTurn(error, text: text, userRowID: userRowID, startedAt: startedAt)
        } catch {
            markFailed(userRowID, error.localizedDescription)
        }
    }

    private func adopt(_ turn: ChatTurnResponse, text: String, userRowID: String) {
        setState(.saved, for: userRowID)
        rows.append(contentsOf: ChatThreadRow.rows(for: turn))
        if conversation == nil {
            conversation = ChatConversation(id: turn.conversationID, title: String(text.prefix(80)), updatedAt: Date())
        }
        knownServerMessages += 2 + 2 * turn.tools.turns.count
        toolNotice = turn.tools.notice
        AccessibilityNotification.Announcement("Reply received").post()
        Task { [cache, namespace, id = turn.conversationID] in
            await cache.remove(key: "chat.conversation.\(id)", namespace: namespace)
        }
    }

    private func failServerTurn(_ error: HVError, text: String, userRowID: String, startedAt: Date) async {
        if case .cancelled = error {
            // The person stopped it. Their words go back in the box; the server
            // may still finish the turn, and the reply will be there next time.
            rows.removeAll { $0.id == userRowID }
            if draft.isEmpty { draft = text }
            notice = "Stopped. If the model still answers, the reply will be here when you open this chat again."
            return
        }
        if error.isOffline {
            // A long request can lose its answer while the server finishes the
            // work. Look before saying the message was not sent.
            if let detail = await ChatTurnReconciler.reconcile(
                client: client, message: text, conversationID: conversationID,
                knownMessageCount: knownServerMessages, startedAt: startedAt
            ) {
                apply(detail)
                return
            }
            markFailed(userRowID, HVCopy.chatOfflineLine)
            return
        }
        markFailed(userRowID, error.userMessage)
    }

    /// A turn written by a model on this phone or on its network: context from
    /// the server, the reply streamed here, then saved.
    private func runLocalTurn(text: String, userRowID: String, provider: ChatModelProvider?, unavailable: String) async {
        guard let provider else {
            markFailed(userRowID, unavailable)
            return
        }
        let assistant = ChatThreadRow(kind: .assistant, model: provider.modelName, state: .streaming, onDevice: true)
        rows.append(assistant)
        // The thread so far, without the message being sent (the last one).
        let history = Array(localHistory.dropLast())
        let runner = OnDeviceChat(client: client, provider: provider, outbox: outbox)
        let turn = OnDeviceTurn(
            message: text, conversationID: conversationID, threadKey: threadKey,
            options: sendOptions(), history: history
        )
        do {
            let outcome = try await runner.run(turn) { [weak self] partial in
                self?.update(assistant.id, text: partial)
            }
            finishOnDevice(outcome, assistantID: assistant.id, userRowID: userRowID, text: text)
        } catch is CancellationError {
            dropAfterStop(assistantID: assistant.id, userRowID: userRowID, text: text)
        } catch let error as HVError {
            rows.removeAll { $0.id == assistant.id }
            if case .cancelled = error {
                dropAfterStop(assistantID: nil, userRowID: userRowID, text: text)
            } else {
                markFailed(userRowID, error.userMessage)
            }
        } catch {
            rows.removeAll { $0.id == assistant.id }
            markFailed(userRowID, error.localizedDescription)
        }
    }

    private func finishOnDevice(_ outcome: OnDeviceOutcome, assistantID: String, userRowID: String, text: String) {
        guard let index = rows.firstIndex(where: { $0.id == assistantID }) else { return }
        rows[index].text = outcome.reply
        rows[index].grounding = outcome.grounding
        rows[index].model = outcome.model
        switch outcome.saved {
        case .saved(let conversationID, let messageID):
            rows[index].state = .saved
            rows[index].serverID = messageID
            setState(.saved, for: userRowID)
            if conversation == nil {
                conversation = ChatConversation(id: conversationID, title: String(text.prefix(80)), updatedAt: Date())
            }
            knownServerMessages += 2
            Task { [cache, namespace] in
                await cache.remove(key: "chat.conversation.\(conversationID)", namespace: namespace)
            }
        case .queued:
            rows[index].state = .waitingToSync
            setState(.waitingToSync, for: userRowID)
        case .rejected(let message):
            rows[index].state = .notSaved(message)
            setState(.notSaved(message), for: userRowID)
        }
        AccessibilityNotification.Announcement("Reply received").post()
        if !outcome.usedMemory {
            notice = "You're offline, so this reply didn't use your memories. It will be saved when you're back."
        }
    }

    private func dropAfterStop(assistantID: String?, userRowID: String, text: String) {
        if let assistantID { rows.removeAll { $0.id == assistantID } }
        rows.removeAll { $0.id == userRowID }
        if draft.isEmpty { draft = text }
    }

    private func update(_ id: String, text: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].text = text
    }

    private func setState(_ state: ChatThreadRow.State, for id: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].state = state
    }

    private func markFailed(_ id: String, _ message: String) {
        setState(.failed(message), for: id)
    }

    // MARK: Acting on a reply

    /// Thumbs up or down; the same one again clears it. Rolls back if the server says no.
    func rate(_ row: ChatThreadRow, _ rating: ChatFeedback) async throws {
        guard let serverID = row.serverID, let index = rows.firstIndex(where: { $0.id == row.id }) else { return }
        let previous = rows[index].feedback
        let next: ChatFeedback? = previous == rating ? nil : rating
        rows[index].feedback = next
        do {
            _ = try await client.send(.rate(messageID: serverID, next))
        } catch let error as HVError {
            if let back = rows.firstIndex(where: { $0.id == row.id }) { rows[back].feedback = previous }
            throw ChatActionError(message: error.sentence(offline: "Network hiccup. Your rating was not saved."))
        }
    }

    /// Keeps a reply in Yours (the server decides whether it is a note or a page).
    func keep(_ row: ChatThreadRow) async throws {
        guard let content = KeepReply.content(of: row.text) else { throw ChatActionError(message: HVCopy.nothingToKeepLine) }
        let source = sourcePrompt(for: row)
        do {
            let kept = try await client.send(.keep(content: content, title: nil, sourcePrompt: source))
            keptNotes[row.id] = ChatKeptNote(
                slug: kept.slug, url: URL(string: kept.url), duplicate: kept.duplicate, isPrivate: kept.isPrivate
            )
        } catch let error as HVError {
            throw ChatActionError(message: error.sentence(offline: HVCopy.keepOfflineLine))
        }
    }

    /// Saves a reply as a memory tagged "chat", named the way the web names it, and answers with the server's
    /// sentence about it (or "Kept in memory." when it sent none).
    func saveAsMemory(_ row: ChatThreadRow) async throws -> String {
        guard !row.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChatActionError(message: HVCopy.nothingToKeepLine)
        }
        let draft = MemoryDraft(
            content: row.text, title: ChatShare.title(content: row.text, sourcePrompt: promptBefore(row)),
            tagsText: "chat", source: "chat"
        )
        do {
            let kept = try await client.send(.memoryCreate(draft))
            return kept.message.isEmpty ? HVCopy.keptInMemoryLine : kept.message
        } catch let error as HVError {
            throw ChatActionError(message: error.sentence(offline: HVCopy.keepOfflineLine))
        }
    }

    /// The last message the person sent before a reply: what it answers.
    private func promptBefore(_ row: ChatThreadRow) -> String? {
        guard let index = rows.firstIndex(where: { $0.id == row.id }) else { return nil }
        return rows[..<index].last { $0.kind == .user }?.text
    }

    /// The message that produced a reply, kept with it so it can be iterated on.
    private func sourcePrompt(for row: ChatThreadRow) -> String? {
        let prior = promptBefore(row)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let prior, !prior.isEmpty, prior.count <= limits.sourcePromptChars else { return nil }
        return prior
    }

    // MARK: The conversation itself

    func setVisibility(_ visibility: ChatVisibility) async throws {
        guard let id = conversationID, var updated = conversation else { return }
        let previous = updated
        updated.visibility = visibility
        conversation = updated
        do {
            let change = try await client.send(.setVisibility(conversationID: id, visibility))
            conversation = change.conversation
        } catch let error as HVError {
            conversation = previous
            throw ChatActionError(message: error.sentence(offline: "Network hiccup. Who can see this chat was not changed."))
        }
    }

    func delete() async throws {
        guard let id = conversationID else { return }
        do {
            _ = try await client.send(.deleteConversation(id: id))
            await cache.remove(key: "chat.conversation.\(id)", namespace: namespace)
            await cache.remove(key: "chat.conversations", namespace: namespace)
        } catch let error as HVError {
            throw ChatActionError(message: error.sentence(offline: "Network hiccup. The chat was not deleted."))
        }
    }

    func dismissNotice() { notice = nil }

    #if DEBUG
    /// Puts a thread on screen without a network, for previews and snapshots.
    func seed(
        rows: [ChatThreadRow], backends: [ChatBackend] = [], conversation: ChatConversation? = nil,
        choice: ChatModelChoice? = nil, working: Date? = nil, notice: String? = nil, hasToolkit: Bool = false,
        keptNotes: [String: ChatKeptNote] = [:], recallBranches: [MindBranch] = []
    ) {
        self.rows = rows
        self.backends = backends
        self.backendsLoaded = true
        self.conversation = conversation
        self.choice = choice
        self.phase = .ready
        self.isWorking = working != nil
        self.workStarted = working
        self.notice = notice
        self.hasToolkit = hasToolkit
        self.keptNotes = keptNotes
        self.recallBranches = recallBranches
        self.didSend = true
    }
    #endif

    private static func sentence(_ error: Error) -> String {
        (error as? HVError)?.userMessage ?? error.localizedDescription
    }
}
