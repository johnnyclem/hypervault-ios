import HyperVaultKit
import SwiftUI

/// Mail: notes between the person and the agents they connect, in a mailbox
/// they share. The inbox rhythm is the familiar one: who, when, what about,
/// swipe to file it away.
struct MailRootView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        MailInboxScreen(client: env.client, cache: env.cache, namespace: env.user.id)
    }
}

struct MailInboxScreen: View {
    @Environment(AppModel.self) private var app
    @State private var model: MailModel
    private let client: HVClient
    @State private var searchText = ""
    @State private var showCompose = false
    @State private var showSettings = false
    @State private var showHeld = false
    @State private var confirmEmptyTrash = false

    init(client: HVClient, cache: DiskCache, namespace: String) {
        self.client = client
        _model = State(initialValue: MailModel(client: client, cache: cache, namespace: namespace))
    }

    var body: some View {
        content
            .hvScreenBackground()
            .navigationTitle("Mail")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search mail")
            .toolbar { toolbarContent }
            .task { await model.start() }
            .task(id: searchText) { await model.search(searchText) }
            .onAppear { Task { await model.refreshIfStarted() } }
            .navigationDestination(for: MailThreadRef.self) { ref in
                MailThreadScreen(
                    client: client, threadID: ref.threadID, mailbox: ref.mailbox, agentsSeeOwnerMail: ref.agentsSeeOwnerMail
                )
            }
            .navigationDestination(isPresented: $showHeld) {
                MailHeldScreen(client: client, mailbox: model.mailboxParam) {
                    Task { await model.refreshCounts() }
                }
            }
            .sheet(isPresented: $showCompose) {
                MailComposeView(
                    address: model.active?.address,
                    agentsSeeReplies: model.agentsSeeOwnerMail
                ) { subject, text in
                    try await model.send(subject: subject, text: text)
                }
            }
            .sheet(isPresented: $showSettings) {
                MailSettingsView(
                    address: model.active?.address,
                    agentsSeeReplies: model.agentsSeeOwnerMail,
                    onToggle: { try await model.setAgentsSeeReplies($0) },
                    onExport: { try await model.export() }
                )
                .presentationDetents([.medium, .large])
            }
            .confirmationDialog("Delete everything in Trash for good?", isPresented: $confirmEmptyTrash, titleVisibility: .visible) {
                Button("Empty Trash", role: .destructive) { emptyTrash() }
                Button("Cancel", role: .cancel) {}
            }
    }

    // MARK: States

    @ViewBuilder
    private var content: some View {
        switch model.mailboxState {
        case .loading, .idle:
            VStack {
                HVListSkeleton(rows: 6).padding(.top, HV.Space.m)
                Spacer()
            }
        case .failed(let message):
            if model.mailboxes.isEmpty && model.messages.isEmpty {
                failure(message)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        case .loaded:
            list
        }
    }

    /// A server without mail is not a fault to retry: say so once and leave it. A dropped connection
    /// and anything else keep the way to try again.
    @ViewBuilder
    private func failure(_ message: String) -> some View {
        switch model.mailboxProblem {
        case .unavailable:
            HVEmptyState(symbol: "tray", title: "Mail is not available yet.", message: message)
        case .offline:
            HVErrorState(message: message, symbol: "wifi.exclamationmark") { Task { await model.refresh() } }
        case .other:
            HVErrorState(message: message) { Task { await model.refresh() } }
        }
    }

    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var list: some View {
        List {
            if model.isShowingSavedCopy {
                Section {
                    HVStaleBanner()
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
            }
            if isSearching {
                Section { searchRows }
            } else {
                Section {
                    mailboxLine
                    MailFilterBar(selected: model.filter, unreadCount: model.active?.unreadCount ?? 0) { filter in
                        Task { await model.select(filter: filter) }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                if model.heldCount > 0 { Section { heldRow } }
                Section { threadRows }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(HV.Space.m)
        .scrollContentBackground(.hidden)
        .refreshable { await model.refresh() }
    }

    /// The address under the large title; with several addresses it is a menu to pick one.
    @ViewBuilder
    private var mailboxLine: some View {
        if let address = model.active?.address {
            Group {
                if model.mailboxes.filter({ $0.address != nil }).count > 1 {
                    Menu {
                        ForEach(model.mailboxes.filter { $0.address != nil }) { box in
                            Button {
                                Haptics.select()
                                Task { await model.select(mailbox: box.id) }
                            } label: {
                                if box.id == model.active?.id {
                                    Label(boxTitle(box), systemImage: "checkmark")
                                } else {
                                    Text(boxTitle(box))
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(address).lineLimit(1)
                            HVIcon(HVSymbol.fold).font(.system(.caption2, weight: .semibold))
                        }
                        .frame(minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Mailbox: \(address)")
                    .accessibilityHint("Choose another address")
                } else {
                    Text(address).lineLimit(1).frame(minHeight: 44, alignment: .leading)
                }
            }
            .font(.hvSubheadline)
            .foregroundStyle(Palette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: HV.Space.m, bottom: 0, trailing: HV.Space.m))
        }
    }

    // MARK: Rows

    @ViewBuilder
    private var threadRows: some View {
        switch model.listState {
        case .idle, .loading:
            HVListSkeleton(rows: 5)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
        case .failed(let message):
            HVErrorState(message: message) { Task { await model.refresh() } }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        case .loaded:
            if model.threads.isEmpty {
                emptyState
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(model.threads) { thread in
                    NavigationLink(value: ref(for: thread.id)) {
                        MailThreadRow(thread: thread)
                    }
                    .accessibilityIdentifier("mail.thread.\(thread.id)")
                    .hvListRow()
                    .swipeActions(edge: .leading, allowsFullSwipe: true) { leadingActions(thread) }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) { trailingActions(thread) }
                    .contextMenu { menuActions(thread) }
                }
                footerRows
            }
        }
    }

    @ViewBuilder
    private var footerRows: some View {
        if model.nextCursor != nil {
            Button("Load older") { loadMore() }
                .buttonStyle(.hvGhost)
                .frame(maxWidth: .infinity, minHeight: 44)
                .disabled(model.isLoadingMore)
                .hvListRow()
        }
        if model.filter == .trash {
            Button("Empty Trash", role: .destructive) { confirmEmptyTrash = true }
                .buttonStyle(.hvGhost)
                .frame(maxWidth: .infinity, minHeight: 44)
                .hvListRow()
        }
    }

    private var heldRow: some View {
        Button {
            showHeld = true
        } label: {
            HVRow(symbol: "hand.raised", title: "\(model.heldCount) held", subtitle: "Mail your agents cannot see") {
                HVIcon(HVSymbol.open).font(.footnote.weight(.semibold)).foregroundStyle(Palette.textTertiary)
            }
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .hvListRow()
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.filter == .inbox {
            HVEmptyState(
                symbol: "tray",
                title: "No mail yet.",
                message: emptyInboxMessage
            )
        } else {
            HVEmptyState(symbol: emptySymbol, title: "Nothing here.")
        }
    }

    /// Where mail arrives, with the address when there is one: the one thing an empty inbox can usefully say.
    private var emptyInboxMessage: String {
        let place = model.active?.address.map { "at \($0)" } ?? "here"
        return "Agents you connect can send you mail \(place). Mail from anyone else waits for you, and they cannot see it."
    }

    private var emptySymbol: String {
        switch model.filter {
        case .trash: return "trash"
        case .archive: return "archivebox"
        case .sent: return "paperplane"
        default: return "tray"
        }
    }

    @ViewBuilder
    private var searchRows: some View {
        switch model.searchState {
        case .idle, .loading:
            HVLoadingState(message: "Searching")
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        case .failed(let message):
            HVErrorState(message: message) { Task { await model.search(searchText) } }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        case .loaded:
            if model.hits.isEmpty {
                HVEmptyState(symbol: "magnifyingglass", title: "Nothing found.", message: "Try another word from the subject or the note.")
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(model.hits) { hit in
                    NavigationLink(value: ref(for: hit.threadId)) {
                        MailHitRow(message: hit)
                    }
                    .hvListRow()
                }
            }
        }
    }

    private func ref(for threadID: String) -> MailThreadRef {
        MailThreadRef(threadID: threadID, mailbox: model.mailboxParam, agentsSeeOwnerMail: model.agentsSeeOwnerMail)
    }

    // MARK: Swipe and menu actions

    @ViewBuilder
    private func leadingActions(_ thread: MailThread) -> some View {
        if model.filter == .inbox || model.filter == .unread {
            if thread.unread {
                Button {
                    Haptics.tap()
                    Task { await model.markRead(thread) }
                } label: {
                    Label("Read", systemImage: "envelope.open")
                }
                .tint(Palette.blue)
            } else {
                Button {
                    Haptics.tap()
                    markUnread(thread)
                } label: {
                    Label("Unread", systemImage: "envelope.badge")
                }
                .tint(Palette.blue)
            }
        }
    }

    @ViewBuilder
    private func trailingActions(_ thread: MailThread) -> some View {
        switch model.filter {
        case .trash:
            Button { move(thread, to: .inbox) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
                .tint(Palette.mint)
        case .archive:
            Button(role: .destructive) { move(thread, to: .trash) } label: { Label("Trash", systemImage: "trash") }
            Button { move(thread, to: .inbox) } label: { Label("Inbox", systemImage: "tray") }
                .tint(Palette.sky)
        default:
            Button(role: .destructive) { move(thread, to: .trash) } label: { Label("Trash", systemImage: "trash") }
            Button { move(thread, to: .archive) } label: { Label("Archive", systemImage: "archivebox") }
                .tint(Palette.sky)
        }
    }

    @ViewBuilder
    private func menuActions(_ thread: MailThread) -> some View {
        if model.filter != .inbox && model.filter != .unread {
            Button { move(thread, to: .inbox) } label: { Label("Move to Inbox", systemImage: "tray") }
        }
        if model.filter != .archive {
            Button { move(thread, to: .archive) } label: { Label("Archive", systemImage: "archivebox") }
        }
        if model.filter != .trash {
            Button(role: .destructive) { move(thread, to: .trash) } label: { Label("Move to Trash", systemImage: "trash") }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Button { showHeld = true } label: { Label("Held mail", systemImage: "hand.raised") }
                Button { showSettings = true } label: { Label("Mailbox settings", systemImage: "gearshape") }
                    .disabled(model.active == nil)
            } label: {
                Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44)
            }
            .disabled(model.isMailUnavailable)
            .accessibilityLabel("More")
            Button {
                showCompose = true
            } label: {
                Image(systemName: "square.and.pencil").frame(minWidth: 44, minHeight: 44)
            }
            .disabled(model.isMailUnavailable)
            .accessibilityLabel("New note")
        }
    }

    private func boxTitle(_ box: OwnerMailbox) -> String {
        box.unreadCount > 0 ? "\(box.displayAddress) (\(box.unreadCount) unread)" : box.displayAddress
    }

    // MARK: Actions

    private func loadMore() {
        Task {
            do { try await model.loadMore() } catch { app.toasts.show(mailError: error) }
        }
    }

    private func move(_ thread: MailThread, to folder: MailFolder) {
        Haptics.tap()
        Task {
            do {
                let result = try await model.move(thread, to: folder)
                if let sentence = result.tooManySentence {
                    app.toasts.show(sentence, style: .error)
                } else {
                    app.toasts.success(MailThreadScreen.movedSentence(folder))
                }
            } catch {
                app.toasts.show(mailError: error)
            }
        }
    }

    private func markUnread(_ thread: MailThread) {
        Task {
            do { try await model.markUnread(thread) } catch { app.toasts.show(mailError: error) }
        }
    }

    private func emptyTrash() {
        Task {
            do {
                let count = try await model.emptyTrash()
                Haptics.success()
                app.toasts.success(count == 1 ? "Deleted 1 message." : "Deleted \(count) messages.")
            } catch {
                app.toasts.show(mailError: error)
            }
        }
    }
}

#if DEBUG
#Preview("Inbox") {
    PreviewHost(routes: MailPreviewData.routes) { MailRootView() }
}

#Preview("Empty") {
    PreviewHost(routes: MailPreviewData.emptyRoutes) { MailRootView() }
}
#endif
