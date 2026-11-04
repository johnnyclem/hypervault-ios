import HyperVaultKit
import SwiftUI

/// The canvas: a quiet page with a field, where a person keeps something or asks about what they have kept. It is a screen
/// pushed on Home (`Route.keep`), reached from the Keep button in Home's bar, from Home's starter page, and by the `keep`,
/// `canvas` and `yours` links. Its page lives in the environment (`AppEnvironment.canvas`), so a paste that is waiting there
/// is still waiting after Back.
struct CanvasRootView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        CanvasScreen(model: env.canvas, origin: env.server.baseURL)
            .jobNotices()
    }
}

struct CanvasScreen: View {
    let origin: URL

    @Environment(AppModel.self) private var app
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: CanvasModel
    @State private var showYours = false
    /// A link the Yours panel asked for that presents a sheet (a key's entry, in Settings): it opens once the panel is gone.
    @State private var afterYours: DeepLink?
    /// The page whose people-and-role share sheet is up over the canvas.
    @State private var sharing: CanvasShareTarget?
    /// The key whose entry's page is up over the canvas (allow, revoke and rename an agent's use of it).
    @State private var keyEntry: CanvasKeyTarget?
    /// The sheet closed because the key is not in the vault any more: the Vault's list opens once it has gone.
    @State private var keyEntryIsGone = false
    @State private var starterCopied = false
    /// The first-run card's own state, held here so the hints know when the card is the one asking for an agent.
    @State private var connectCard: ConnectCardModel?
    @State private var dictation = DictationController()
    @State private var dictationBase = ""
    @State private var showScanner = false
    @State private var celebrating = false
    @AppStorage("hv.firstKeepCelebrated") private var celebrated = false

    /// The page it shows is the one the environment keeps (`AppEnvironment.canvas`); previews and tests stand it up with
    /// things already on it.
    init(model: CanvasModel, origin: URL) {
        _model = State(initialValue: model)
        self.origin = origin
    }

    var body: some View {
        ZStack {
            AuroraBackground(intensity: model.isQuiet ? 1 : 0.55)
            content
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            CanvasComposer(
                model: model,
                onNewThread: { model.startNewThread() },
                onCopyStarter: copyStarter,
                isDictating: dictation.isListening,
                onDictate: dictation.isAvailable ? toggleDictation : nil,
                onScan: DocumentScanner.isSupported ? { showScanner = true } : nil
            )
        }
        .fullScreenCover(isPresented: $showScanner) {
            DocumentScanner(
                onText: { text in
                    showScanner = false
                    if !text.isEmpty { model.stagePaste(text) }
                },
                onCancel: { showScanner = false }
            )
            .ignoresSafeArea()
        }
        .onChange(of: dictation.transcript) { _, transcript in
            guard dictation.isListening || !transcript.isEmpty else { return }
            let separator = dictationBase.isEmpty || dictationBase.hasSuffix(" ") ? "" : " "
            model.setDraft(dictationBase + separator + transcript)
        }
        // The tabs stay alive under each other, so leaving for another tab does not end the view. Dictation would go on
        // listening, with the indicator lit and other audio lowered, and rewrite the draft from wherever the person is.
        // (Going back, or opening a card's page over the canvas, ends it with `onDisappear`.)
        .onChange(of: dictationMustStop) { _, mustStop in
            if mustStop { dictation.stop() }
        }
        .onDisappear { dictation.stop() }
        .toolbar { toolbarContent }
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showYours, onDismiss: openWhatYoursAskedFor) {
            YoursSheet(onPull: { item in
                model.pullItem(item)
                showYours = false
            }, onNew: {
                showYours = false
                model.ask()
            }, onLibrary: {
                // The panel closes as the Library opens, so the Library is not pushed under it. The Library goes on the
                // stack above the canvas, so Back lands on the canvas the person came from.
                showYours = false
                app.router.push(.library, on: .home)
            }, onVault: {
                afterYours = .account(.vault)
                showYours = false
            })
        }
        .sheet(item: $sharing) { target in
            CanvasShareSheet(detail: target.detail)
        }
        .sheet(item: $keyEntry, onDismiss: openVaultIfKeyIsGone) { target in
            CanvasKeySheet(target: target, onGone: keyEntryLeftTheVault)
        }
        .onChange(of: keyEntry?.id) { closed, shown in
            // The page may have allowed or revoked an agent, or renamed the entry: the card behind it says who may use it, and by
            // what name, so it reads the key again. (An entry that is gone has nothing to read.)
            if shown == nil, let closed, !keyEntryIsGone { model.refreshCard(key: closed) }
        }
        .task { await model.loadBackends() }
        // The link that asks for the canvas pushes it in the same step that sets the text, so the text is there as the canvas
        // is first built: it is taken now, and not after the models have been read (a request that may take a while).
        .onChange(of: app.router.canvasDraft, initial: true) { _, _ in takeRouterDraft() }
        .onChange(of: app.router.yoursPanel, initial: true) { _, wanted in
            guard wanted else { return }
            app.router.yoursPanel = false
            showYours = true
        }
        .onChange(of: app.router.sheet) { _, sheet in
            // Connecting a model happens in a sheet over the page: on its way out, look again for one.
            if sheet == nil, !model.hasModel { Task { await model.loadBackends() } }
        }
        .onChange(of: model.wantsYours) { _, wants in
            if wants {
                model.wantsYours = false
                showYours = true
            }
        }
        .overlay {
            if celebrating { ConfettiBurst().transition(.opacity) }
        }
        .onChange(of: keptKey) { _, key in
            // The first thing anyone keeps is worth a moment.
            guard key != nil, !celebrated else { return }
            celebrated = true
            celebrating = true
            Task {
                try? await Task.sleep(nanoseconds: 2_200_000_000)
                HV.Motion.animate { celebrating = false }
            }
        }
    }

    private var dictationMustStop: Bool {
        DictationPolicy.mustStop(
            tab: app.router.tab,
            isCovered: showYours || showScanner || sharing != nil || keyEntry != nil || app.router.sheet != nil,
            phase: scenePhase
        )
    }

    /// The newest kept card. It changes when a keep lands, which is what the first-keep celebration waits for.
    private var keptKey: String? {
        model.cards.last(where: { $0.kept != nil })?.key
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if model.isQuiet {
            ScrollView {
                VStack(spacing: 0) {
                    CanvasHints(model: model, connectCardMayAsk: connectCard.map { $0.isVisible || !$0.hasLooked } ?? true, onCopyStarter: copyStarter, starterCopied: starterCopied)
                        .padding(.top, HV.Space.xxl)
                    // The first-run ask for an agent's key: there only for someone with no key who has not waved it off.
                    ConnectCardSlot(model: $connectCard)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: HV.Space.m) {
                        ForEach(model.cards) { card in
                            CanvasCardView(
                                card: card,
                                onOpen: { open(card) },
                                onHide: { HV.Motion.animate(HV.Motion.sheet) { model.dispatch(.hide(key: card.key)) } },
                                onShare: { share(card) }
                            )
                                .transition(.asymmetric(insertion: .scale(scale: 0.96).combined(with: .opacity), removal: .opacity))
                        }
                        CanvasThreadView(model: model)
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, HV.Space.m)
                    .padding(.top, HV.Space.s)
                    .hvReadableWidth()
                    .hvAnimation(HV.Motion.sheet, value: model.cards)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.messages.count) { _, _ in
                    HV.Motion.animate(HV.Motion.sheet) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: model.cards.count) { _, _ in
                    HV.Motion.animate(HV.Motion.sheet) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
    }

    /// (No avatar: the canvas is pushed on Home, which has it, and the bar's own back button leads there.)
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showYours = true
            } label: {
                // Not the layered square a group is drawn with (`KeptKind.group`): the panel is a stack of what was kept.
                Image(systemName: "rectangle.stack")
            }
            .accessibilityLabel("Open panel")
            .accessibilityIdentifier("canvas.yours")
        }
    }

    // MARK: Actions

    private func open(_ card: CanvasCard) {
        model.markOpened(card)
        switch card.kind {
        case .page, .file, .group:
            // Pushed over the canvas, so Back returns to it. (Memory is another tab: that one is a jump.)
            if let slug = card.slug { app.router.push(.artifact(slug: slug), on: .home) }
        case .memory:
            if let id = card.ref?.id { app.router.open(.route(.memory(id: id))) }
        case .key:
            // The entry's own page over the canvas. (A key card always has one; the Vault's list is where Open went before.)
            if let entry = CanvasKeyCard.target(for: card, env: env) {
                keyEntry = entry
            } else {
                app.router.open(CanvasKeyCard.fallback)
            }
        }
    }

    /// The Yours panel is gone: what it asked for that needed it gone can present now.
    private func openWhatYoursAskedFor() {
        guard let link = afterYours else { return }
        afterYours = nil
        app.router.open(link)
    }

    /// The sheet found no entry for its key: it closes, and the Vault's list opens once it has.
    private func keyEntryLeftTheVault() {
        guard keyEntry != nil else { return }
        keyEntryIsGone = true
        keyEntry = nil
    }

    /// The key's sheet is gone. If it went because the entry is no longer in the vault (deleted from the web or another phone), the
    /// person lands where Open used to take them, with nothing said about it.
    private func openVaultIfKeyIsGone() {
        guard keyEntryIsGone else { return }
        keyEntryIsGone = false
        app.router.open(CanvasKeyCard.fallback)
    }

    /// Share on a page, a file or a group: the sheet that has the link and the people who can open it, over the canvas.
    private func share(_ card: CanvasCard) {
        sharing = CanvasShare.target(for: card, env: env)
    }

    private func toggleDictation() {
        if !dictation.isListening {
            dictationBase = model.draft
            model.dismissNotice()
        }
        Task {
            await dictation.toggle()
            // Read once the start has finished, not watched: asking again after a refusal must say so again.
            if let problem = dictation.problem { model.dictationFailed(problem) }
        }
    }

    private func copyStarter() {
        StarterPrompt.copy(origin: origin)
        starterCopied = true
        Task {
            try? await Task.sleep(nanoseconds: StarterPrompt.copiedFor)
            starterCopied = false
        }
    }

    /// Text a link, the share sheet or a Shortcut left for the canvas.
    private func takeRouterDraft() {
        guard let draft = app.router.canvasDraft, !draft.isEmpty else { return }
        app.router.canvasDraft = nil
        model.handlePaste(draft)
    }
}
