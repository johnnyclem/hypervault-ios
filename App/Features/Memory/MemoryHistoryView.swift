import HyperVaultKit
import SwiftUI

/// A memory's edit history: every revision with its commit, a diff against the
/// one before, and a way back. Restoring never rewrites history; it lands as a
/// new commit. A forgotten memory can be brought back from here.
struct MemoryHistoryView: View {
    let title: String
    var onRestored: () -> Void

    @Environment(AppModel.self) private var app
    @State private var model: MemoryHistoryModel
    @State private var expanded: Set<String> = []
    @State private var confirming: MemoryRevision?

    init(memoryID: String, title: String, branch: String, env: AppEnvironment, onRestored: @escaping () -> Void = {}) {
        self.title = title
        self.onRestored = onRestored
        _model = State(initialValue: MemoryHistoryModel(memoryID: memoryID, branch: branch, env: env))
    }

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                HVListSkeleton(rows: 5).frame(maxHeight: .infinity, alignment: .top)
            case .failed(let message):
                HVErrorState(message: message) { Task { await model.load() } }
                    .frame(maxHeight: .infinity)
            case .gone(let message):
                HVEmptyState(symbol: "clock.arrow.circlepath", title: "No history", message: message)
                    .frame(maxHeight: .infinity)
            case .loaded:
                if let history = model.history { list(history) }
            }
        }
        .hvScreenBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .confirmationDialog(
            confirming?.op == .delete ? "Bring it back?" : "Restore this version?",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible,
            presenting: confirming
        ) { revision in
            Button(model.isForgotten ? "Bring it back" : "Restore") { restore(revision) }
        } message: { _ in
            Text(model.isForgotten ? "It returns to your memory as it was before it was forgotten." : "The memory goes back to this version. The version it has now stays in history.")
        }
    }

    private func list(_ history: MemoryHistory) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: HV.Space.s) {
                if model.isForgotten, let back = history.lastLive {
                    forgottenBanner(restoring: back)
                }
                HVSectionHeader(title: "History", detail: "\(history.revisions.count) \(history.revisions.count == 1 ? "revision" : "revisions")")
                ForEach(Array(history.revisions.enumerated()), id: \.element.id) { index, revision in
                    revisionCard(revision, history: history, isNewest: index == 0)
                }
            }
            .padding(HV.Space.m)
            .padding(.bottom, HV.Space.xl)
            .hvReadableWidth()
        }
        .refreshable { await model.reload() }
    }

    private func forgottenBanner(restoring revision: MemoryRevision) -> some View {
        VStack(alignment: .leading, spacing: HV.Space.s) {
            Label("This memory was forgotten", systemImage: "trash")
                .font(.hvHeadline)
                .foregroundStyle(Palette.textPrimary)
            Text("Nothing is lost. Its history can bring it back as it was.")
                .font(.hvCallout)
                .foregroundStyle(Palette.textSecondary)
            Button("Bring it back") { confirming = revision }
                .buttonStyle(.hvPrimary)
                .disabled(model.restoringID != nil)
        }
        .hvCard()
    }

    private func revisionCard(_ revision: MemoryRevision, history: MemoryHistory, isNewest: Bool) -> some View {
        let isOpen = expanded.contains(revision.revisionId)
        let canDiff = history.previous(of: revision) != nil && revision.op != .delete
        let canRestore = !isNewest && revision.op != .delete
        return VStack(alignment: .leading, spacing: HV.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: HV.Space.xs) {
                HVTag(text: revision.op.verb, tint: tint(revision.op))
                if isNewest { HVTag(text: "Latest", tint: Palette.blue) }
                if let branch = revision.commit?.branch, branch != model.branch {
                    HVTag(text: branch, tint: Palette.violet)
                }
                Spacer()
                Text(MemoryDates.quiet(revision.commit?.createdAt))
                    .font(.hvCaption)
                    .foregroundStyle(Palette.textTertiary)
            }
            Text(revision.commit?.message ?? revision.title)
                .font(.hvBody)
                .foregroundStyle(Palette.textPrimary)
                .multilineTextAlignment(.leading)
            if let commit = revision.commit {
                MemoryMetaLine(symbol: commit.authorKind.symbol, text: "\(commit.author) \u{00B7} \(MemoryDates.full(commit.createdAt))")
            }
            if canDiff || canRestore {
                HStack(spacing: HV.Space.xs) {
                    if canDiff {
                        Button(isOpen ? "Hide changes" : "Show changes") { toggle(revision) }
                            .buttonStyle(.hvGhost)
                    }
                    if canRestore {
                        Button("Restore this version") { confirming = revision }
                            .buttonStyle(.hvGhost)
                            .disabled(model.restoringID != nil)
                    }
                    Spacer(minLength: 0)
                    if model.restoringID == revision.revisionId { ProgressView() }
                }
                .padding(.leading, -HV.Space.s)
            }
            if isOpen { diffView(for: revision) }
        }
        .hvCard()
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func diffView(for revision: MemoryRevision) -> some View {
        switch model.diffs[revision.revisionId] {
        case .loaded(let diff):
            VStack(alignment: .leading, spacing: HV.Space.xs) {
                if let from = diff.titleFrom, let to = diff.titleTo, from != to {
                    Text("Renamed from \u{201C}\(from)\u{201D}")
                        .font(.hvCaption)
                        .foregroundStyle(Palette.textSecondary)
                }
                if !diff.tagsAdded.isEmpty || !diff.tagsRemoved.isEmpty {
                    MemoryFlowLayout(spacing: 6) {
                        ForEach(diff.tagsAdded, id: \.self) { HVTag(text: "+ \($0)", tint: Palette.success) }
                        ForEach(diff.tagsRemoved, id: \.self) { HVTag(text: "\u{2212} \($0)", tint: Palette.rose) }
                    }
                }
                MindDiffView(diff: diff.diff)
            }
        case .failed(let message):
            Text(message)
                .font(.hvFootnote)
                .foregroundStyle(Palette.danger)
        case .loading, .none:
            HVLoadingState()
        }
    }

    private func tint(_ op: MindOp) -> Color {
        switch op {
        case .create: return Palette.mint
        case .update: return Palette.blue
        case .delete: return Palette.rose
        }
    }

    private func toggle(_ revision: MemoryRevision) {
        if expanded.contains(revision.revisionId) {
            expanded.remove(revision.revisionId)
        } else {
            expanded.insert(revision.revisionId)
            Task { await model.loadDiff(for: revision) }
        }
    }

    private func restore(_ revision: MemoryRevision) {
        confirming = nil
        Task {
            do {
                let message = try await model.restore(revision)
                Haptics.success()
                app.toasts.success(message)
                onRestored()
            } catch {
                app.toasts.show(error: error)
            }
        }
    }
}
