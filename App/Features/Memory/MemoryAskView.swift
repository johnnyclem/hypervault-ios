import HyperVaultKit
import SwiftUI

/// Ask mode: a question in plain words, an answer from the person's own model
/// when one is connected, and always the memories it drew from.
struct MemoryAskView: View {
    let list: MemoryListModel

    @Environment(AppModel.self) private var app
    @State private var model: MemoryAskModel
    @State private var speech = ChatSpeechController()
    @State private var draft = ""
    @FocusState private var focused: Bool

    init(list: MemoryListModel) {
        self.list = list
        _model = State(initialValue: MemoryAskModel(env: list.env))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: HV.Space.l) {
                        if model.turns.isEmpty {
                            intro
                        }
                        ForEach(model.turns) { turn in
                            MemoryAskTurnView(turn: turn, hasModel: model.selectedBackend != nil, conversationID: model.conversationID, model: model, speech: speech)
                                .id(turn.id)
                        }
                    }
                    .padding(.horizontal, HV.Space.m)
                    .padding(.vertical, HV.Space.s)
                    .hvReadableWidth()
                }
                .scrollDismissesKeyboard(.interactively)
                // New content at the bottom is followed; a thumb or a Keep on the answer is not, which would take the page
                // away from the buttons that were just used.
                .onChange(of: scrollKey) { _, key in
                    guard let key else { return }
                    HV.Motion.animate(.easeOut(duration: 0.25)) { proxy.scrollTo(key.id, anchor: .bottom) }
                }
            }
            composer
        }
        .task { await model.loadBackends() }
        .onDisappear { speech.stop() }
    }

    /// What of the last turn calls for a scroll to it: it arrives, its sources arrive, it is answered or it fails.
    private struct ScrollKey: Equatable {
        let id: UUID
        let phase: MemoryAskModel.Turn.Phase
        let hits: Int
        let answered: Bool
        let failed: Bool
    }

    private var scrollKey: ScrollKey? {
        model.turns.last.map { ScrollKey(id: $0.id, phase: $0.phase, hits: $0.hits.count, answered: $0.answer != nil, failed: $0.failure != nil) }
    }

    private var intro: some View {
        VStack(spacing: HV.Space.m) {
            HVEmptyState(
                symbol: "text.bubble",
                title: "Ask your memory",
                message: "Ask anything it might know: what did I decide about auth, what was in that paper I imported. It finds memories by meaning, not only by words."
            )
            if model.backendsLoaded, model.backends.isEmpty {
                VStack(spacing: HV.Space.xs) {
                    Text("No model is connected yet, so you will get the memories themselves. Connect one in Chat to have them written up as an answer.")
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.textSecondary)
                        .multilineTextAlignment(.center)
                    Button("Open Chat") { app.router.open(.tab(.chat)) }
                        .buttonStyle(.hvGhost)
                }
                .padding(.horizontal, HV.Space.l)
            }
        }
    }

    private var composer: some View {
        VStack(spacing: HV.Space.xs) {
            if model.backends.count > 1 || model.offersTools {
                HStack(spacing: HV.Space.m) {
                    if model.backends.count > 1 {
                        Menu {
                            Picker("Model", selection: Binding(get: { model.selectedBackend?.id ?? "" }, set: { model.selectedBackendID = $0 })) {
                                ForEach(model.backends) { backend in
                                    Text(backend.name).tag(backend.id)
                                }
                            }
                        } label: {
                            Label(model.selectedBackend?.name ?? "Model", systemImage: "cpu")
                                .font(.hvCaption)
                        }
                    }
                    if model.offersTools {
                        // The model may act through the person's tools, as in a chat, unless this is off.
                        Menu {
                            Toggle("Use my tools", isOn: Binding(get: { model.useTools }, set: { model.useTools = $0 }))
                        } label: {
                            Label(model.useTools ? "Tools on" : "Tools off", systemImage: "wrench.and.screwdriver")
                                .hvRowLabel()
                                .font(.hvCaption)
                                .frame(minHeight: 44)
                        }
                        .accessibilityIdentifier("ask.tools")
                    }
                    Spacer()
                }
            }
            HStack(alignment: .bottom, spacing: HV.Space.xs) {
                TextField("Ask your memory", text: $draft, prompt: Text.hvPrompt("Ask your memory"), axis: .vertical)
                    .accessibilityIdentifier("ask.field")
                    .lineLimit(1...4)
                    .focused($focused)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .padding(.horizontal, HV.Space.m)
                    .padding(.vertical, HV.Space.s)
                Button(action: send) {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(.hvIconProminent)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy)
                .accessibilityLabel("Ask")
            }
            .padding(.leading, HV.Space.xxs)
            .padding(.trailing, HV.Space.xs)
            .padding(.vertical, HV.Space.xxs)
            .hvGlass(radius: HV.Radius.floating)
        }
        .padding(.horizontal, HV.Space.m)
        .padding(.vertical, HV.Space.xs)
        .hvReadableWidth()
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !model.isBusy else { return }
        draft = ""
        Haptics.tap()
        let branch = list.branch
        Task { await model.ask(text, branch: branch) }
    }
}

/// One question, what memory holds on it, and the answer written from that.
private struct MemoryAskTurnView: View {
    let turn: MemoryAskModel.Turn
    let hasModel: Bool
    let conversationID: String?
    let model: MemoryAskModel
    var speech: ChatSpeechController

    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: HV.Space.s) {
            HStack {
                Spacer(minLength: HV.Space.xl)
                Text(turn.question)
                    .font(.hvBody)
                    .foregroundStyle(.white)
                    .padding(.horizontal, HV.Space.m)
                    .padding(.vertical, HV.Space.s)
                    .background(Palette.softGradient, in: RoundedRectangle(cornerRadius: HV.Radius.l, style: .continuous))
                    .textSelection(.enabled)
            }
            answer
            if !turn.hits.isEmpty {
                sources
            }
        }
    }

    @ViewBuilder
    private var answer: some View {
        if let failure = turn.failure {
            Text(failure)
                .font(.hvFootnote)
                .foregroundStyle(Palette.danger)
                .padding(HV.Space.s)
        } else if turn.phase == .recalling {
            HStack(spacing: HV.Space.xs) {
                ProgressView().controlSize(.small)
                Text("Looking through your memory\u{2026}")
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.textSecondary)
            }
            .padding(HV.Space.s)
        } else if turn.phase == .answering {
            HStack(spacing: HV.Space.xs) {
                ProgressView().controlSize(.small)
                Text("Found \(turn.hits.count) \(turn.hits.count == 1 ? "memory" : "memories"). Writing it up\u{2026}")
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.textSecondary)
            }
            .padding(HV.Space.s)
        } else if let answer = turn.answer {
            VStack(alignment: .leading, spacing: HV.Space.xs) {
                if !answer.tools.turns.isEmpty {
                    ChatToolGroupView(steps: answer.tools.turns)
                }
                if let notice = answer.tools.notice {
                    MemoryMetaLine(symbol: "wrench.and.screwdriver", text: notice, tint: Palette.warning)
                }
                Text(answer.text.isEmpty ? "The model sent back nothing. Try asking again." : answer.text)
                    .font(.hvBody)
                    .foregroundStyle(Palette.textPrimary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if answer.truncated {
                    MemoryMetaLine(symbol: "exclamationmark.triangle", text: "The model stopped at its length limit, so the end is missing.", tint: Palette.warning)
                }
                // What it leaned on besides the memories listed below: the conversation graph and the truth ledger.
                ChatGroundingView(grounding: answer.grounding) { slug in app.router.push(.artifact(slug: slug)) }
                if !answer.text.isEmpty {
                    MemoryAskAnswerActions(turn: turn, text: answer.text, model: model, speech: speech)
                }
                if let note = turn.kept {
                    ChatKeptNoteView(note: note) { slug in app.router.push(.artifact(slug: slug)) }
                }
                HStack(spacing: HV.Space.s) {
                    if let model = answer.model {
                        Text(model).font(.hvCaption).foregroundStyle(Palette.textTertiary)
                    }
                    Spacer()
                    if let conversationID, !answer.conversationId.isEmpty {
                        Button("Continue in Chat") { app.router.open(.route(.conversation(id: conversationID))) }
                            .buttonStyle(.hvGhost)
                    }
                }
            }
            .hvCard()
        } else if !hasModel {
            Text(turn.hits.isEmpty ? noMatch : "Here is what your memory holds on that. Connect a model in Chat to have it written up as an answer.")
                .font(.hvFootnote)
                .foregroundStyle(Palette.textSecondary)
                .padding(.horizontal, HV.Space.xxs)
        } else if turn.hits.isEmpty {
            Text(noMatch)
                .font(.hvFootnote)
                .foregroundStyle(Palette.textSecondary)
                .padding(.horizontal, HV.Space.xxs)
        }
    }

    private var noMatch: String {
        turn.recallMessage.isEmpty ? "Nothing in memory matches that yet. Keep something first." : turn.recallMessage
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            HVSectionHeader(title: "Drew from", detail: turn.recallMode.label)
            let usedTitles = Set(turn.answer?.recalled ?? [])
            ForEach(turn.hits) { hit in
                NavigationLink(value: Route.memory(id: hit.id)) {
                    HStack(alignment: .top, spacing: HV.Space.s) {
                        Image(systemName: usedTitles.contains(hit.title) ? "checkmark.circle.fill" : "doc.text")
                            .foregroundStyle(usedTitles.contains(hit.title) ? Palette.success : Palette.textTertiary)
                            .hvIconSlot(22)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: HV.Space.xxs) {
                            Text(hit.title)
                                .font(.hvSubheadline.weight(.semibold))
                                .foregroundStyle(Palette.textPrimary)
                                .multilineTextAlignment(.leading)
                            Text(hit.excerpt(limit: 200) ?? hit.summary)
                                .font(.hvFootnote)
                                .foregroundStyle(Palette.textSecondary)
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: HVSymbol.open)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.textTertiary)
                            .accessibilityHidden(true)
                    }
                    .padding(HV.Space.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Copy, keep, thumbs, read aloud and share under an answer: what a chat reply has under it, each a 44-point target.
private struct MemoryAskAnswerActions: View {
    let turn: MemoryAskModel.Turn
    let text: String
    let model: MemoryAskModel
    var speech: ChatSpeechController

    @Environment(AppModel.self) private var app
    @State private var copied = false
    @State private var keeping = false
    @ScaledMetric(relativeTo: .body) private var glyphSize: CGFloat = 16

    private var speechID: String { turn.id.uuidString }

    var body: some View {
        HStack(spacing: 0) {
            action(copied ? HVSymbol.copied : HVSymbol.copy, label: copied ? "Copied" : "Copy answer", tint: copied ? Palette.mint : nil) {
                UIPasteboard.general.string = text
                Haptics.tap()
                copied = true
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(HV.Motion.copiedHold * 1_000_000_000))
                    copied = false
                }
            }
            action(keeping ? "hourglass" : "tray.and.arrow.down", label: "Keep this answer", tint: nil) {
                guard !keeping else { return }
                keeping = true
                let id = turn.id
                Task {
                    defer { keeping = false }
                    do {
                        try await model.keep(id)
                        Haptics.success()
                    } catch {
                        app.toasts.show(error: error)
                    }
                }
            }
            if turn.answer?.messageId != nil {
                action(turn.feedback == .up ? "hand.thumbsup.fill" : "hand.thumbsup", label: "Good answer", tint: turn.feedback == .up ? Palette.mint : nil, selected: turn.feedback == .up) {
                    rate(.up)
                }
                action(turn.feedback == .down ? "hand.thumbsdown.fill" : "hand.thumbsdown", label: "Bad answer", tint: turn.feedback == .down ? Palette.rose : nil, selected: turn.feedback == .down) {
                    rate(.down)
                }
            }
            action(
                speech.isSpeaking(speechID) ? "stop.circle.fill" : "speaker.wave.2",
                label: speech.isSpeaking(speechID) ? "Stop reading" : "Read aloud",
                tint: speech.isSpeaking(speechID) ? Color.accentColor : nil
            ) {
                speech.toggle(id: speechID, text: text)
            }
            ShareLink(item: text) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: glyphSize, weight: .regular))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Share answer")
            Spacer(minLength: 0)
        }
        .padding(.leading, -HV.Space.xs)
    }

    private func rate(_ value: ChatFeedback) {
        Haptics.select()
        let id = turn.id
        Task {
            do { try await model.rate(id, value) } catch { app.toasts.show(error: error) }
        }
    }

    private func action(_ symbol: String, label: String, tint: Color?, selected: Bool = false, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol)
                .font(.system(size: glyphSize, weight: .regular))
                .foregroundStyle(tint ?? Palette.textSecondary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
