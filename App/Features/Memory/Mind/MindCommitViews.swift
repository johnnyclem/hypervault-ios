import HyperVaultKit
import SwiftUI

/// `git log` for the mind: what was changed, when, and by whom (you, or an agent holding one of your keys).
struct MindCommitLogView: View {
    let list: MemoryListModel

    @State private var model: MindCommitLogModel

    init(list: MemoryListModel) {
        self.list = list
        _model = State(initialValue: MindCommitLogModel(branch: list.branch, env: list.env))
    }

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                HVListSkeleton(rows: 7).frame(maxHeight: .infinity, alignment: .top)
            case .failed(let message):
                HVErrorState(message: message) { Task { await model.load() } }
                    .frame(maxHeight: .infinity)
            case .loaded:
                if model.commits.isEmpty {
                    HVEmptyState(symbol: "clock.arrow.circlepath", title: "No history yet", message: "Every memory you keep, edit or forget is recorded here.")
                        .frame(maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: HV.Space.xs) {
                            if model.isStale { HVStaleBanner() }
                            ForEach(model.commits) { commit in
                                NavigationLink {
                                    MindCommitDetailView(commit: commit, list: list)
                                } label: {
                                    MindCommitRow(commit: commit)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(HV.Space.m)
                        .hvReadableWidth()
                    }
                    .refreshable { await model.refresh() }
                }
            }
        }
        .hvScreenBackground()
        .navigationTitle("History of \(list.branch)")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
    }
}

struct MindCommitRow: View {
    let commit: MindCommit

    var body: some View {
        HStack(alignment: .top, spacing: HV.Space.s) {
            HVIconBadge(symbol: commit.kind.symbol, tint: commit.kind.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(commit.message.isEmpty ? "(no message)" : commit.message)
                    .font(.hvBody)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    Image(systemName: commit.authorKind.symbol)
                        .font(.system(size: 10))
                        .accessibilityHidden(true)
                    Text("\(commit.author) \u{00B7} \(MemoryDates.quiet(commit.createdAt))")
                }
                .font(.hvCaption)
                .foregroundStyle(Palette.textSecondary)
                let summary = commit.changeCounts.summary
                if !summary.isEmpty {
                    Text(summary)
                        .font(.hvCaption)
                        .foregroundStyle(Palette.textTertiary)
                }
            }
            Spacer(minLength: HV.Space.xs)
            Text(commit.shortId)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Palette.textTertiary)
        }
        .padding(HV.Space.s + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// One commit: what it changed. A forgotten memory can be brought back from here.
struct MindCommitDetailView: View {
    let list: MemoryListModel

    @Environment(AppModel.self) private var app
    @State private var model: MindCommitDetailModel

    init(commit: MindCommit, list: MemoryListModel) {
        self.list = list
        _model = State(initialValue: MindCommitDetailModel(commit: commit, branch: list.branch, env: list.env))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HV.Space.l) {
                header
                switch model.phase {
                case .loading:
                    HVLoadingState()
                case .failed(let message):
                    HVErrorState(message: message) { Task { await model.load() } }
                case .loaded(.diff(let diff)):
                    MindStateDiffView(diff: diff, onRestore: { memory in bringBack(memory) }, restoringID: model.restoringID)
                case .loaded(.start(let state)):
                    start(state)
                }
            }
            .padding(HV.Space.m)
            .padding(.bottom, HV.Space.xl)
            .hvReadableWidth()
        }
        .hvScreenBackground()
        .navigationTitle("Commit \(model.commit.shortId)")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
    }

    private var header: some View {
        let commit = model.commit
        return VStack(alignment: .leading, spacing: HV.Space.xs) {
            HStack(spacing: HV.Space.s) {
                HVIconBadge(symbol: commit.kind.symbol, tint: commit.kind.tint, size: 40)
                Text(commit.message.isEmpty ? "(no message)" : commit.message)
                    .font(.hvTitle3)
                    .foregroundStyle(Palette.textPrimary)
                    .textSelection(.enabled)
            }
            MemoryMetaLine(symbol: commit.authorKind.symbol, text: "\(commit.author) \u{00B7} \(MemoryDates.full(commit.createdAt))")
            if !commit.changeCounts.summary.isEmpty {
                MemoryMetaLine(symbol: "square.stack.3d.up", text: commit.changeCounts.summary)
            }
            if commit.isMerge {
                MemoryMetaLine(symbol: "arrow.triangle.merge", text: "A merge: it brought another branch in.", tint: Palette.violet)
            }
            Text(commit.id)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Palette.textTertiary)
                .textSelection(.enabled)
        }
    }

    private func start(_ state: MindState) -> some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            HVSectionHeader(title: "The first commit", detail: "\(state.memories.count)")
            Text("Nothing came before it. This is what it started with.")
                .font(.hvCallout)
                .foregroundStyle(Palette.textSecondary)
            ForEach(state.memories) { memory in
                HVRow(symbol: "brain.head.profile", tint: Palette.blue, title: memory.title, subtitle: memory.summary)
                    .padding(.vertical, 4)
            }
        }
    }

    private func bringBack(_ memory: MindDiffMemory) {
        Task {
            do {
                let message = try await model.bringBack(memory)
                Haptics.success()
                app.toasts.success(message)
            } catch {
                app.toasts.show(error: error)
            }
        }
    }
}
