import HyperVaultKit
import SwiftUI

/// Mail that came from someone other than the person, which their agents
/// cannot see: mail from the internet, when the server is set up to receive it
/// (docs/agent-mail.md, "Internet mail in" in the web repo). Until then this is
/// an explanation and "Nothing is held."; when something is held, the person can
/// let their agents see it. Each card says who it is from, whether it is from the
/// person's own address, and whether the sender was verified.
struct MailHeldView: View {
    @Environment(AppEnvironment.self) private var env
    let mailbox: String?
    let onChange: () -> Void

    var body: some View {
        MailHeldScreen(client: env.client, mailbox: mailbox, onChange: onChange)
    }
}

@MainActor
@Observable
final class MailHeldModel {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    /// What has been read of the held mail: every page so far, and what could not be read (`MailHeldList`).
    private(set) var list: MailHeldList?
    private(set) var releasing: String?
    private(set) var isLoadingMore = false
    @ObservationIgnored private let client: HVClient
    @ObservationIgnored private let mailbox: String?

    init(client: HVClient, mailbox: String?) {
        self.client = client
        self.mailbox = mailbox
    }

    func load() async {
        do {
            let page = try await client.send(.mailHeld(mailbox: mailbox))
            list = MailHeldList(page: page)
            phase = .loaded
        } catch {
            phase = .failed(MailModel.sentence(error))
        }
    }

    /// The next page of held mail. Held mail used to stop at the first page, so the 21st message was never shown.
    func loadMore() async throws {
        guard let cursor = list?.nextCursor, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let page = try await client.send(.mailHeld(mailbox: mailbox, cursor: cursor))
        // A refresh that landed while this was in flight has its own list and its own cursor.
        guard list?.nextCursor == cursor else { return }
        list?.append(page)
    }

    func release(_ message: MailMessage) async throws {
        releasing = message.id
        defer { releasing = nil }
        _ = try await client.send(.mailRelease(id: message.id, mailbox: mailbox))
        list?.remove(message.id)
    }
}

struct MailHeldScreen: View {
    @Environment(AppModel.self) private var app
    @State private var model: MailHeldModel
    @State private var candidate: MailMessage?
    let onChange: () -> Void

    init(client: HVClient, mailbox: String?, onChange: @escaping () -> Void) {
        _model = State(initialValue: MailHeldModel(client: client, mailbox: mailbox))
        self.onChange = onChange
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HV.Space.m) {
                Text("Held mail came from someone other than you, and your agents cannot see it.")
                    .font(.hvCallout)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                content
            }
            .padding(HV.Space.m)
            .hvReadableWidth()
        }
        .refreshable { await model.load() }
        .hvScreenBackground()
        .navigationTitle("Held")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .confirmationDialog(
            "Let your agents see this?",
            isPresented: Binding(get: { candidate != nil }, set: { if !$0 { candidate = nil } }),
            titleVisibility: .visible,
            presenting: candidate
        ) { message in
            Button("Let agents see it") { release(message) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            // A reply you wrote under it, which was waiting for this, becomes readable too (D17 in the web repo's docs).
            Text("They will be able to read it, and any reply you wrote under it. Nothing else changes.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            HVListSkeleton(rows: 2)
        case .failed(let message):
            HVErrorState(message: message) { Task { await model.load() } }
        case .loaded:
            if let list = model.list {
                if list.isNothing {
                    HVEmptyState(symbol: "tray", title: "Nothing is held.")
                } else {
                    ForEach(list.messages) { message in
                        VStack(alignment: .leading, spacing: HV.Space.s) {
                            MailMessageCard(message: message, style: .held)
                            Button("Let agents see this") {
                                Haptics.tap()
                                candidate = message
                            }
                            .buttonStyle(.hvSecondary)
                            .disabled(model.releasing == message.id)
                        }
                    }
                    // Said, not hidden: held mail the app could not read is not "Nothing is held."
                    if let sentence = list.unreadableSentence {
                        Text(sentence)
                            .font(.hvCallout)
                            .foregroundStyle(Palette.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // The server counts more held mail than it sent: the rows above are not all of it.
                    if let sentence = list.disagreementSentence {
                        Text(sentence)
                            .font(.hvCallout)
                            .foregroundStyle(Palette.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if list.hasMore {
                        Button("Load more") { loadMore() }
                            .buttonStyle(.hvGhost)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .disabled(model.isLoadingMore)
                    }
                }
            }
        }
    }

    private func loadMore() {
        Task {
            do { try await model.loadMore() } catch { app.toasts.show(mailError: error) }
        }
    }

    private func release(_ message: MailMessage) {
        Task {
            do {
                try await model.release(message)
                Haptics.success()
                app.toasts.success("Your agents can see it now")
                onChange()
            } catch {
                app.toasts.show(mailError: error)
            }
        }
    }
}
