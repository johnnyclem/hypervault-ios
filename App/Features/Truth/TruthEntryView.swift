import HyperVaultKit
import SwiftUI

enum TruthLoad<Value> {
    case loading
    case loaded(Value)
    case failed(String)
}

/// One entry's trace (what it rests on, what rests on it) and ripple (what a change to it reaches).
@MainActor
@Observable
final class TruthEntryModel {
    private(set) var trace: TruthLoad<TruthDerivation> = .loading
    private(set) var ripple: TruthLoad<TruthRipple> = .loading

    @ObservationIgnored private let client: HVClient
    let ref: TruthEntryRef

    init(client: HVClient, ref: TruthEntryRef) {
        self.client = client
        self.ref = ref
    }

    func load() async {
        let id = ref.row.id
        let ledger = ref.ledger
        do {
            trace = .loaded(try await client.send(.truthDerivation(id: id, ledger: ledger)))
        } catch {
            trace = .failed(TruthModel.sentence(error))
        }
        do {
            ripple = .loaded(try await client.send(.truthRipple(id: id, ledger: ledger)))
        } catch {
            ripple = .failed(TruthModel.sentence(error))
        }
    }

    func remove() async throws {
        _ = try await client.send(.deleteTruthEntry(id: ref.row.id, ledger: ref.ledger))
    }
}

struct TruthEntryScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var model: TruthEntryModel
    @State private var confirmRemove = false
    let onChange: () -> Void

    init(client: HVClient, ref: TruthEntryRef, onChange: @escaping () -> Void = {}) {
        _model = State(initialValue: TruthEntryModel(client: client, ref: ref))
        self.onChange = onChange
    }

    private var row: TruthEntryRow { model.ref.row }

    var body: some View {
        List {
            headerSection
            detailSection
            traceSection
            rippleSection
            if !model.ref.isHosted { removeSection }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .hvScreenBackground()
        .navigationTitle(row.type == .tb ? "Signed truth" : "Unverified claim")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .refreshable { await model.load() }
        .confirmationDialog("Remove this from the ledger?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { remove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This only removes HyperVault's copy. The stenographer ledger is untouched, and the next import brings it back.")
        }
    }

    // MARK: What it says

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: HV.Space.s) {
                TruthTagFlow {
                    TruthTypeTag(type: row.type)
                    TruthStatusBadge(status: row.status)
                    TruthStandingBadge(standing: row.standing, showsSound: true)
                    if row.isStale { HVTag(text: "Stale", tint: Palette.amber) }
                }
                TruthClaimText(text: row.line.text, lines: nil, large: true)
                if let standing = row.standing {
                    Text(row.reasonSentence ?? standing.meaning)
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            .padding(.vertical, HV.Space.xxs)
            .accessibilityElement(children: .combine)
            .hvListRow()
        }
    }

    private var detailSection: some View {
        Section {
            if row.type == .tb {
                if let signer = row.line.signedBy { detail("Signed by", signer) }
                if let answers = row.answerableBy { detail("Answerable", answers) }
            } else if let author = row.line.author {
                detail("Asserted by", author)
            }
            if let ts = row.line.ts { detail("When", ts.formatted(date: .abbreviated, time: .shortened)) }
            if let basis = row.line.basis, !basis.isEmpty { detail("Basis", basis) }
            if let verify = row.line.verifyBy { detail("Verify by", verify.sentence) }
            if let freshness = row.freshness, freshness.isStale, let since = freshness.since {
                detail("Unverified since", since.formatted(date: .abbreviated, time: .omitted))
            }
            if let contests = row.line.contests { detail("Contests", TruthID.short(contests)) }
            if !row.line.evidence.isEmpty {
                VStack(alignment: .leading, spacing: HV.Space.xs) {
                    Text("Evidence").font(.hvFootnote).foregroundStyle(Palette.textSecondary)
                    ForEach(Array(row.line.evidence.enumerated()), id: \.offset) { _, evidence in
                        TruthEvidenceRow(evidence: evidence)
                    }
                }
                .padding(.vertical, HV.Space.xxs)
                .hvListRow()
            }
            detail("Id", row.line.id, isReference: true)
        } header: {
            HVSectionHeader(title: "Record")
        }
    }

    /// A label over its value. An id is a reference to copy, so it is set as one.
    private func detail(_ title: String, _ value: String, isReference: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: HV.Space.xxs) {
            Text(title).font(.hvFootnote).foregroundStyle(Palette.textSecondary)
            Text(verbatim: value)
                .font(isReference ? .hvMono : .hvBody)
                .foregroundStyle(Palette.textPrimary)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .hvListRow()
    }

    // MARK: Trace and ripple

    private var traceSection: some View {
        Section {
            switch model.trace {
            case .loading:
                HVLoadingState(message: "Tracing").listRowBackground(Color.clear)
            case .failed(let message):
                Text(message).font(.hvFootnote).foregroundStyle(Palette.textSecondary).hvListRow()
            case .loaded(let derivation):
                // What rests on this entry is the next section's job, from the ripple, which reaches further.
                TruthTraceView(derivation: derivation, showsDependents: false).hvListRow()
            }
        } header: {
            HVSectionHeader(title: "Trace")
        } footer: {
            Text("What this rests on, one row each. The premise it fails on is marked.").hvSectionNote()
        }
    }

    private var rippleSection: some View {
        Section {
            switch model.ripple {
            case .loading:
                HVLoadingState().listRowBackground(Color.clear)
            case .failed(let message):
                Text(message).font(.hvFootnote).foregroundStyle(Palette.textSecondary).hvListRow()
            case .loaded(let ripple):
                Text(ripple.sentence).font(.hvSubheadline).foregroundStyle(Palette.textSecondary).hvListRow()
                let named = claims(in: ripple)
                ForEach(ripple.entries) { entry in
                    TruthBriefRow(entry: entry, claims: named, listedUnder: row.id).hvListRow()
                }
                ForEach(ripple.context) { context in
                    contextRow(context).hvListRow()
                }
            }
        } header: {
            HVSectionHeader(title: "What rests on it")
        } footer: {
            Text("Other entries, and the memories and pages built on them: what a change to this would reach.").hvSectionNote()
        }
    }

    /// What each entry in the ripple says, and this one too, so a row can name where it came from.
    private func claims(in ripple: TruthRipple) -> [String: String] {
        var out = [row.id: row.line.text]
        for entry in ripple.entries where !entry.text.isEmpty { out[entry.id] = entry.text }
        return out
    }

    @ViewBuilder
    private func contextRow(_ context: TruthRippleContext) -> some View {
        let open: (() -> Void)? = openAction(context)
        Button {
            open?()
        } label: {
            HStack(alignment: .top, spacing: HV.Space.s) {
                Image(systemName: context.kind == "memory" ? HVSymbol.memory : "doc.text")
                    .foregroundStyle(Palette.textSecondary)
                    .hvIconSlot(24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: HV.Space.xxs) {
                    Text(verbatim: context.title).font(.hvBody).foregroundStyle(Palette.textPrimary)
                    Text(context.relationPhrase + (context.stale ? " · out of date" : ""))
                        .font(.hvCaption)
                        .foregroundStyle(context.stale ? Palette.amber : Palette.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(open == nil)
    }

    private func openAction(_ context: TruthRippleContext) -> (() -> Void)? {
        guard let item = context.item else { return nil }
        if item.isMemory { return { app.router.push(.memory(id: item.id)) } }
        if let slug = item.slug { return { app.router.push(.artifact(slug: slug)) } }
        return nil
    }

    private var removeSection: some View {
        Section {
            Button("Remove from this ledger", role: .destructive) { confirmRemove = true }
                .hvListRow()
        } footer: {
            Text("A mirror ledger is a copy of a stenographer stream. Removing an entry only removes the copy.").hvSectionNote()
        }
    }

    private func remove() {
        Task {
            do {
                try await model.remove()
                Haptics.success()
                onChange()
                dismiss()
            } catch {
                app.toasts.show(error: error)
            }
        }
    }
}
