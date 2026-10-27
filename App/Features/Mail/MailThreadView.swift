import HyperVaultKit
import SwiftUI

/// Where a conversation is opened from inside Mail. It carries the mailbox, so a
/// thread in the second address opens in the right one.
struct MailThreadRef: Hashable {
    let threadID: String
    let mailbox: String?
    let agentsSeeOwnerMail: Bool
}

/// One conversation. This is the destination of `Route.mailThread`, so a link
/// may name a thread (or a message) and no mailbox: it is looked for in each.
struct MailThreadView: View {
    @Environment(AppEnvironment.self) private var env
    let id: String
    let mailbox: String?
    let agentsSeeOwnerMail: Bool

    init(id: String, mailbox: String? = nil, agentsSeeOwnerMail: Bool = true) {
        self.id = id
        self.mailbox = mailbox
        self.agentsSeeOwnerMail = agentsSeeOwnerMail
    }

    var body: some View {
        MailThreadScreen(client: env.client, threadID: id, mailbox: mailbox, agentsSeeOwnerMail: agentsSeeOwnerMail)
            .id(id)
    }
}

struct MailThreadScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var model: MailThreadModel
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    init(client: HVClient, threadID: String, mailbox: String?, agentsSeeOwnerMail: Bool) {
        _model = State(initialValue: MailThreadModel(
            client: client, threadID: threadID, mailbox: mailbox, agentsSeeOwnerMail: agentsSeeOwnerMail
        ))
    }

    var body: some View {
        content
            .hvScreenBackground()
            .navigationTitle(model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { moveMenu }
            .task { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            VStack {
                HVListSkeleton(rows: 3).padding(.top, HV.Space.m)
                Spacer()
            }
        case .failed(let message):
            HVErrorState(message: message) {
                Task { await model.load() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            loaded
        }
    }

    // MARK: The thread

    private var loaded: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: HV.Space.s) {
                        if model.olderCursor != nil {
                            Button("Load older") { loadOlder() }
                                .buttonStyle(.hvGhost)
                                .frame(minHeight: 44)
                                .disabled(model.isLoadingOlder)
                        }
                        ForEach(model.messages) { message in
                            MailMessageCard(message: message, onOpenAttachment: openAttachment)
                                .id(message.id)
                        }
                    }
                    .padding(.horizontal, HV.Space.m)
                    .padding(.vertical, HV.Space.s)
                    .hvReadableWidth()
                }
                .scrollDismissesKeyboard(.interactively)
                .onAppear { scrollToNewest(proxy) }
                .onChange(of: model.newest?.id) { _, _ in scrollToNewest(proxy) }
            }
            if model.newest != nil { composer }
        }
    }

    private func scrollToNewest(_ proxy: ScrollViewProxy) {
        guard let id = model.newest?.id, model.messages.count > 1 else { return }
        HV.Motion.animate(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .top) }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            if model.replyIsHidden {
                MailNotSharedTag()
                    .padding(.leading, HV.Space.xxs)
            }
            HStack(alignment: .bottom, spacing: HV.Space.s) {
                TextField("Write a reply", text: $draft, axis: .vertical)
                    .accessibilityIdentifier("mail.reply")
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    .hvFieldChrome(isFocused: composerFocused)
                Button {
                    send()
                } label: {
                    if model.isSending {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "arrow.up")
                    }
                }
                .buttonStyle(.hvIconProminent)
                .disabled(trimmedDraft.isEmpty || model.isSending)
                .accessibilityLabel("Send reply")
            }
        }
        .padding(HV.Space.s)
        .hvGlass(radius: 26)
        .padding(.horizontal, HV.Space.m)
        .padding(.vertical, HV.Space.xs)
    }

    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var moveMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if model.phase == .loaded {
                Menu {
                    if model.isAnywhereElse(than: .inbox) {
                        Button { move(to: .inbox) } label: { Label("Move to Inbox", systemImage: "tray") }
                    }
                    if model.isAnywhereElse(than: .archive) {
                        Button { move(to: .archive) } label: { Label("Archive", systemImage: "archivebox") }
                    }
                    if model.isAnywhereElse(than: .trash) {
                        Button(role: .destructive) { move(to: .trash) } label: { Label("Move to Trash", systemImage: "trash") }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .disabled(model.isMoving)
                .accessibilityLabel("Move this conversation")
            }
        }
    }

    // MARK: Actions

    private func openAttachment(_ slug: String) {
        app.router.open(.route(.artifact(slug: slug)))
    }

    private func loadOlder() {
        Task {
            do { try await model.loadOlder() } catch { app.toasts.show(mailError: error) }
        }
    }

    private func send() {
        let text = trimmedDraft
        guard !text.isEmpty else { return }
        Task {
            do {
                try await model.reply(text)
                draft = ""
                Haptics.success()
            } catch {
                app.toasts.show(mailError: error)
            }
        }
    }

    private func move(to folder: MailFolder) {
        Task {
            do {
                let result = try await model.move(to: folder)
                if let sentence = result.tooManySentence {
                    app.toasts.show(sentence, style: .error)
                    return
                }
                app.toasts.success(Self.movedSentence(folder))
                dismiss()
            } catch {
                app.toasts.show(mailError: error)
            }
        }
    }

    static func movedSentence(_ folder: MailFolder) -> String {
        switch folder {
        case .inbox: return "Moved to Inbox"
        case .archive: return "Archived"
        case .trash: return "Moved to Trash"
        }
    }
}

extension ToastCenter {
    /// Mail's failures come with a leading machine code; a person reads the sentence after it.
    func show(mailError error: Error) {
        if let hv = error as? HVError, case .cancelled = hv { return }
        if error is CancellationError { return }
        show(MailModel.sentence(error), style: .error)
    }
}

#if DEBUG
#Preview("Thread") {
    PreviewHost(routes: MailPreviewData.threadRoutes) {
        MailThreadView(id: MailPreviewData.threadID, mailbox: MailPreviewData.boxA)
    }
}
#endif
