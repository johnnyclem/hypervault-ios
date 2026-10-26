import HyperVaultKit
import SwiftUI

/// The first tab: a quiet page with a field. Everything a person has is behind the avatar or
/// the Yours icon and appears only when asked for.
struct CanvasRootView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        CanvasScreen(client: env.client, origin: env.server.baseURL, userName: env.user.firstName, avatarName: env.user.displayName ?? env.user.email ?? "?", avatarURL: env.user.avatarUrl.flatMap(URL.init(string:)))
    }
}

struct CanvasScreen: View {
    let userName: String?
    let avatarName: String
    let avatarURL: URL?
    let origin: URL

    @Environment(AppModel.self) private var app
    @State private var model: CanvasModel
    @State private var showYours = false
    @State private var starterCopied = false
    @State private var dictation = DictationController()
    @State private var dictationBase = ""
    @State private var showScanner = false
    @State private var celebrating = false
    @AppStorage("hv.firstKeepCelebrated") private var celebrated = false

    init(client: HVClient, origin: URL, userName: String?, avatarName: String, avatarURL: URL?) {
        self.init(model: CanvasModel(client: client, origin: origin), origin: origin, userName: userName, avatarName: avatarName, avatarURL: avatarURL)
    }

    /// For previews and tests, which stand the page up with things already on it.
    init(model: CanvasModel, origin: URL, userName: String?, avatarName: String, avatarURL: URL?) {
        _model = State(initialValue: model)
        self.origin = origin
        self.userName = userName
        self.avatarName = avatarName
        self.avatarURL = avatarURL
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
        .toolbar { toolbarContent }
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showYours) {
            YoursSheet(onPull: { item in
                model.addCard(for: item)
                showYours = false
            }, onNew: {
                showYours = false
                model.ask()
            })
        }
        .task {
            await model.loadBackends()
            takeRouterDraft()
        }
        .onChange(of: app.router.canvasDraft) { _, _ in takeRouterDraft() }
        .onChange(of: app.router.canvasPull) { _, item in
            guard let item else { return }
            app.router.canvasPull = nil
            model.addCard(for: item)
        }
        .onChange(of: app.router.sheet) { _, sheet in
            // Connecting a model happens in a sheet over the page: on its way out, look again for one.
            if sheet == nil, !model.hasModel { Task { await model.loadBackends() } }
        }
        .onChange(of: app.router.canvasAsk) { _, asks in
            guard asks else { return }
            app.router.canvasAsk = false
            model.ask()
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
                withAnimation { celebrating = false }
            }
        }
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
                CanvasHints(model: model, userName: userName, onCopyStarter: copyStarter, starterCopied: starterCopied)
                    .padding(.top, HV.Space.xxl)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: HV.Space.m) {
                        ForEach(model.cards) { card in
                            CanvasCardView(card: card, onOpen: { open(card) }, onHide: { withAnimation(.snappy) { model.dispatch(.hide(key: card.key)) } })
                                .transition(.asymmetric(insertion: .scale(scale: 0.96).combined(with: .opacity), removal: .opacity))
                        }
                        CanvasThreadView(model: model)
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, HV.Space.m)
                    .padding(.top, HV.Space.s)
                    .hvReadableWidth()
                    .animation(.snappy, value: model.cards)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.messages.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: model.cards.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                app.router.tab = .you
            } label: {
                HVAvatar(name: avatarName, imageURL: avatarURL, size: 32)
            }
            .accessibilityLabel("Account")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showYours = true
            } label: {
                Image(systemName: "square.stack.3d.up")
            }
            .accessibilityLabel("Open Yours")
        }
    }

    // MARK: Actions

    private func open(_ card: CanvasCard) {
        model.markOpened(card)
        switch card.kind {
        case .page, .file, .group:
            if let slug = card.slug { app.router.open(.route(.artifact(slug: slug))) }
        case .memory:
            if let id = card.ref?.id { app.router.open(.route(.memory(id: id))) }
        case .key:
            app.router.open(.route(.vaultItems))
        }
    }

    private func toggleDictation() {
        if !dictation.isListening { dictationBase = model.draft }
        Task { await dictation.toggle() }
    }

    private func copyStarter() {
        UIPasteboard.general.string = HVCopy.starterPrompt(origin: origin.absoluteString)
        starterCopied = true
        Haptics.success()
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
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
