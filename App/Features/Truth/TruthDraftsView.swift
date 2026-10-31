import HyperVaultKit
import SwiftUI

/// Drafts: candidate truths chat staged for stenographer to file. HyperVault
/// signs nothing; each draft waits for a notary.
@MainActor
@Observable
final class TruthDraftsModel {
    private(set) var phase: TruthLoad<[TruthProposal]> = .loading
    private(set) var status: TruthProposalStatus = .open
    private(set) var busy: Set<String> = []

    @ObservationIgnored private let client: HVClient
    let ledger: String

    init(client: HVClient, ledger: String) {
        self.client = client
        self.ledger = ledger
    }

    func load() async {
        do {
            phase = .loaded(try await client.send(.truthProposals(status: status, ledger: ledger)).proposals)
        } catch {
            phase = .failed(TruthModel.sentence(error))
        }
    }

    func select(_ next: TruthProposalStatus) async {
        guard next != status else { return }
        status = next
        phase = .loading
        await load()
    }

    func move(_ proposal: TruthProposal, to next: TruthProposalStatus) async throws {
        busy.insert(proposal.id)
        defer { busy.remove(proposal.id) }
        _ = try await client.send(.setTruthProposal(id: proposal.id, status: next, ledger: ledger))
        await load()
    }

    /// The open drafts as a proposals stream; `mark` writes the chain and the drafts become "exported".
    func export(mark: Bool) async throws -> (url: URL, count: Int) {
        let response = try await client.sendRaw(.exportTruthProposals(ledger: ledger, mark: mark))
        let count = response.header("x-proposal-count").flatMap(Int.init) ?? 0
        let url = try TruthShareFile.write(response.data, named: TruthFiles.proposalsName(slug: ledger))
        if mark { await load() }
        return (url, count)
    }
}

struct TruthDraftsScreen: View {
    @Environment(AppModel.self) private var app
    @State private var model: TruthDraftsModel
    @State private var confirmExport = false
    @State private var confirmDismiss: TruthProposal?
    @State private var shared: TruthSharedFile?
    let onChange: () -> Void

    init(client: HVClient, ledger: String, onChange: @escaping () -> Void = {}) {
        _model = State(initialValue: TruthDraftsModel(client: client, ledger: ledger))
        self.onChange = onChange
    }

    var body: some View {
        List {
            Section {
                HVChoicePicker(title: "Status", selection: Binding(get: { model.status }, set: { next in Task { await model.select(next) } })) {
                    ForEach(TruthProposalStatus.allCases) { status in Text(status.title).tag(status) }
                }
                .listRowBackground(Color.clear)
            } footer: {
                // A footer in a grouped list sits on the page as quiet text; in a plain list it got its own black band.
                Text("Candidates chat compaction or an agent staged. HyperVault never signs truth: each draft waits for a notary in stenographer.")
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.textSecondary)
            }
            switch model.phase {
            case .loading:
                HVLoadingState().listRowBackground(Color.clear)
            case .failed(let message):
                HVErrorState(message: message) { Task { await model.load() } }.listRowBackground(Color.clear)
            case .loaded(let proposals):
                if proposals.isEmpty {
                    HVEmptyState(symbol: "doc.text", title: "No \(model.status.rawValue) drafts.")
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(proposals) { proposal in
                        draftRow(proposal)
                            .hvListRow()
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .hvScreenBackground()
        .navigationTitle("Drafts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { confirmExport = true } label: { Image(systemName: "square.and.arrow.up").frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel("Export open drafts")
            }
        }
        .task { await model.load() }
        .refreshable { await model.load() }
        .sheet(item: $shared) { file in TruthActivitySheet(items: [file.url]) }
        .confirmationDialog("Export the open drafts?", isPresented: $confirmExport, titleVisibility: .visible) {
            Button("Export and mark exported") { export(mark: true) }
            Button("Export without marking") { export(mark: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Marking continues the ledger's proposals file, so the next export picks up where this one stops.")
        }
        .confirmationDialog(
            "Dismiss this draft?",
            isPresented: Binding(get: { confirmDismiss != nil }, set: { if !$0 { confirmDismiss = nil } }),
            titleVisibility: .visible,
            presenting: confirmDismiss
        ) { proposal in
            Button("Dismiss for good", role: .destructive) { move(proposal, to: .dismissed) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("A dismissed draft is never proposed again.")
        }
    }

    private func draftRow(_ proposal: TruthProposal) -> some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            TruthTagFlow {
                TruthTypeTag(type: proposal.isTombstone ? .tb : .uv)
                HVTag(text: proposal.status.title, tint: Palette.textSecondary)
            }
            TruthClaimText(text: proposal.headline, lines: 4)
            if !proposal.evidenceLines.isEmpty {
                Text("Evidence: " + proposal.evidenceLines.joined(separator: " · ")).font(.hvFootnote).foregroundStyle(Palette.textSecondary)
            }
            if let basis = proposal.basis { Text("Basis: \(basis)").font(.hvFootnote).foregroundStyle(Palette.textSecondary) }
            if let verify = proposal.verifyBy { Text("Verify by: \(verify)").font(.hvFootnote).foregroundStyle(Palette.textSecondary) }
            if let signal = proposal.signalDetail { Text("Signal: \(signal)").font(.hvFootnote).foregroundStyle(Palette.textSecondary) }
            Text(footer(proposal)).font(.hvCaption).foregroundStyle(Palette.textTertiary)
            HStack(spacing: HV.Space.m) {
                ForEach(proposal.status.moves) { next in
                    // Dismissing is the one move that cannot be undone from here, so it reads as such.
                    Button(next.moveTitle, role: next == .dismissed ? .destructive : nil) {
                        if next == .dismissed { confirmDismiss = proposal } else { move(proposal, to: next) }
                    }
                    .disabled(model.busy.contains(proposal.id))
                }
            }
            .buttonStyle(.hvGhost)
        }
        .padding(.vertical, HV.Space.xxs)
    }

    private func footer(_ proposal: TruthProposal) -> String {
        var parts = ["From \(proposal.originPhrase)"]
        if let created = proposal.createdAt { parts.append(created.formatted(date: .abbreviated, time: .omitted)) }
        if let exported = proposal.exportedAt { parts.append("exported \(exported.formatted(date: .abbreviated, time: .omitted))") }
        return parts.joined(separator: " · ")
    }

    private func move(_ proposal: TruthProposal, to next: TruthProposalStatus) {
        Task {
            do {
                try await model.move(proposal, to: next)
                Haptics.select()
                onChange()
            } catch {
                app.toasts.show(error: error)
            }
        }
    }

    private func export(mark: Bool) {
        Task {
            do {
                let result = try await model.export(mark: mark)
                if result.count == 0 {
                    app.toasts.show("No open drafts to export.")
                } else {
                    shared = TruthSharedFile(url: result.url)
                    if mark { app.toasts.success("Exported \(result.count) draft\(result.count == 1 ? "" : "s"). They are marked exported."); onChange() }
                }
            } catch {
                app.toasts.show(error: error)
            }
        }
    }
}
