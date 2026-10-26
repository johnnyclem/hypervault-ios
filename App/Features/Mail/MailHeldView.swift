import HyperVaultKit
import SwiftUI

/// Mail that came from someone other than the person, which their agents
/// cannot see. In this version nothing creates such mail, so this is usually
/// an explanation and "Nothing is held."; when something is, the person can
/// let their agents see it.
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
    private(set) var messages: [MailMessage] = []
    private(set) var releasing: String?
    @ObservationIgnored private let client: HVClient
    @ObservationIgnored private let mailbox: String?

    init(client: HVClient, mailbox: String?) {
        self.client = client
        self.mailbox = mailbox
    }

    func load() async {
        do {
            let page = try await client.send(.mailHeld(mailbox: mailbox))
            messages = page.messages
            phase = .loaded
        } catch {
            phase = .failed(MailModel.sentence(error))
        }
    }

    func release(_ message: MailMessage) async throws {
        releasing = message.id
        defer { releasing = nil }
        _ = try await client.send(.mailRelease(id: message.id, mailbox: mailbox))
        messages.removeAll { $0.id == message.id }
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
            Text("They will be able to read it. Nothing else changes.")
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
            if model.messages.isEmpty {
                HVEmptyState(symbol: "tray", title: "Nothing is held.")
            } else {
                ForEach(model.messages) { message in
                    VStack(alignment: .leading, spacing: HV.Space.s) {
                        MailMessageCard(message: message)
                        Button("Let agents see this") {
                            Haptics.tap()
                            candidate = message
                        }
                        .buttonStyle(.hvSecondary)
                        .disabled(model.releasing == message.id)
                    }
                }
            }
        }
    }

    private func release(_ message: MailMessage) {
        Task {
            do {
                try await model.release(message)
                Haptics.success()
                app.toasts.success("Your agents can see it now.")
                onChange()
            } catch {
                app.toasts.show(mailError: error)
            }
        }
    }
}
