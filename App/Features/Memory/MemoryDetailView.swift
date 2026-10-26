import HyperVaultKit
import SwiftUI

/// One memory, on its own page: what it says, how it is linked, who last
/// touched it, and what can be done with it: edit, history, digest, share, forget.
struct MemoryDetailView: View {
    let id: String
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        MemoryDetailContent(id: id, env: env)
    }
}

private struct MemoryDetailContent: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var model: MemoryDetailModel
    @State private var showEdit = false
    @State private var confirmForget = false

    init(id: String, env: AppEnvironment) {
        _model = State(initialValue: MemoryDetailModel(id: id, env: env))
    }

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                ScrollView { detailSkeleton }
            case .failed(let message):
                HVErrorState(message: message) { Task { await model.load() } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .gone(let message):
                goneView(message)
            case .loaded:
                if let page = model.page { loaded(page) }
            }
        }
        .hvScreenBackground()
        .navigationTitle("Memory")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let page = model.page, model.phase == .loaded { actionsMenu(page) }
            }
        }
        .task { await model.load() }
        .sheet(isPresented: $showEdit) {
            if let page = model.page {
                MemoryEditSheet(model: model, memory: page.memory)
            }
        }
        .confirmationDialog("Forget this memory?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget", role: .destructive) { forget() }
        } message: {
            Text("It leaves your memory and its links. Its history stays, so you can bring it back.")
        }
    }

    // MARK: Content

    private func loaded(_ page: MemoryPage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HV.Space.l) {
                if model.isStale { HVStaleBanner() }
                header(page)
                if showsSummary(page) { summary(page.memory) }
                MemoryMarkdownView(blocks: model.blocks)
                receipt(page)
                if let truth = page.truth, !truth.restsOn.isEmpty { truthCard(truth) }
                if !page.related.isEmpty { related(page.related) }
                if !page.artifacts.isEmpty { artifacts(page.artifacts) }
                shortcuts(page)
            }
            .padding(HV.Space.m)
            .padding(.bottom, HV.Space.xl)
            .hvReadableWidth()
        }
        .refreshable { await model.reload() }
    }

    private func header(_ page: MemoryPage) -> some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            Text(page.memory.title)
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(Palette.textPrimary)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: HV.Space.xs) {
                MemorySourceChip(source: page.memory.source)
                if let date = page.memory.createdAt {
                    Text(MemoryDates.full(date))
                        .font(.hvCaption)
                        .foregroundStyle(Palette.textTertiary)
                }
                if page.branch != MindBranchName.defaultName {
                    HVTag(text: page.branch, tint: Palette.violet)
                }
            }
            if !page.memory.tags.isEmpty {
                MemoryTagList(tags: page.memory.tags)
                    .padding(.top, 2)
            }
        }
    }

    /// A summary beside a short memory only repeats it.
    private func showsSummary(_ page: MemoryPage) -> Bool {
        !page.memory.summary.isEmpty && page.memory.content.count > 500
    }

    private func summary(_ memory: MemoryFull) -> some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            HVSectionHeader(title: "Summary")
            Text(memory.summary)
                .font(.hvCallout)
                .foregroundStyle(Palette.textSecondary)
                .textSelection(.enabled)
        }
        .padding(HV.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous))
    }

    @ViewBuilder
    private func receipt(_ page: MemoryPage) -> some View {
        if let receipt = page.provenance {
            VStack(alignment: .leading, spacing: HV.Space.xs) {
                HVSectionHeader(title: "Last change")
                MemoryMetaLine(symbol: receipt.authorKind.symbol, text: MemoryReceiptText.line(receipt))
                if !receipt.commitId.isEmpty {
                    Text("Commit \(receipt.shortCommitId)")
                        .font(.hvMono)
                        .foregroundStyle(Palette.textTertiary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func truthCard(_ truth: MemoryTruth) -> some View {
        VStack(alignment: .leading, spacing: HV.Space.s) {
            HVSectionHeader(title: "Rests on", detail: truth.restsOn.count == 1 ? "1 truth" : "\(truth.restsOn.count) truths")
            if truth.stale > 0 {
                MemoryMetaLine(
                    symbol: "exclamationmark.triangle.fill",
                    text: truth.stale == 1 ? "One of these has changed since this memory was written." : "\(truth.stale) of these have changed since this memory was written.",
                    tint: Palette.warning
                )
            }
            ForEach(truth.restsOn) { edge in
                VStack(alignment: .leading, spacing: 2) {
                    Text(edge.entryText.isEmpty ? edge.entryId : edge.entryText)
                        .font(.hvSubheadline)
                        .foregroundStyle(Palette.textPrimary)
                        .multilineTextAlignment(.leading)
                    if let summary = edge.staleSummary, edge.isStale {
                        Text(summary)
                            .font(.hvCaption)
                            .foregroundStyle(Palette.warning)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
            NavigationLink(value: Route.truth) {
                Text("Open Truth")
                    .font(.hvSubheadline.weight(.semibold))
            }
            .buttonStyle(.hvGhost)
        }
        .hvCard()
    }

    private func related(_ memories: [MemoryRelated]) -> some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            HVSectionHeader(title: "Linked memories", detail: "\(memories.count)")
            ForEach(memories) { memory in
                NavigationLink(value: Route.memory(id: memory.id)) {
                    HVRow(symbol: "brain.head.profile", tint: Palette.blue, title: memory.title, subtitle: memory.summary) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.textTertiary)
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
            }
        }
    }

    private func artifacts(_ pages: [MemoryArtifactRef]) -> some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            HVSectionHeader(title: "Linked pages", detail: "\(pages.count)")
            ForEach(pages) { artifact in
                NavigationLink(value: Route.artifact(slug: artifact.slug)) {
                    HVRow(symbol: "doc.richtext", tint: Palette.rose, title: artifact.title, subtitle: artifact.type) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.textTertiary)
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
            }
        }
    }

    private func shortcuts(_ page: MemoryPage) -> some View {
        VStack(spacing: 0) {
            NavigationLink {
                MemoryHistoryView(memoryID: page.memory.id, title: page.memory.title, branch: model.branch, env: model.env) {
                    Task { await model.reload() }
                }
            } label: {
                HVRow(
                    symbol: "clock.arrow.circlepath", tint: Palette.violet, title: "History",
                    subtitle: page.revisionCount > 0 ? "\(page.revisionCount) \(page.revisionCount == 1 ? "revision" : "revisions")" : "Every change is a commit"
                ) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.textTertiary)
                }
                .padding(.vertical, HV.Space.xs)
            }
            .buttonStyle(.plain)
            .frame(minHeight: 44)
            Divider()
            Button {
                digest()
            } label: {
                HVRow(symbol: "scissors", tint: Palette.cyan, title: "Digest this", subtitle: "Split it into smaller memories, for you to review") {
                    if model.isWorking { ProgressView() }
                }
                .padding(.vertical, HV.Space.xs)
            }
            .buttonStyle(.plain)
            .disabled(model.isWorking)
            .frame(minHeight: 44)
        }
        .padding(.horizontal, HV.Space.m)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: HV.Radius.l, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: HV.Radius.l, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
    }

    // MARK: Menu and actions

    private func actionsMenu(_ page: MemoryPage) -> some View {
        Menu {
            Button { showEdit = true } label: { Label("Edit", systemImage: "pencil") }
            Button {
                UIPasteboard.general.string = page.memory.content
                Haptics.success()
                app.toasts.success("Copied.")
            } label: { Label("Copy text", systemImage: "doc.on.doc") }
            ShareLink(item: shareText(page.memory), subject: Text(page.memory.title)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            Button { digest() } label: { Label("Digest this", systemImage: "scissors") }
            Divider()
            Button(role: .destructive) { confirmForget = true } label: { Label("Forget", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Actions")
    }

    private func shareText(_ memory: MemoryFull) -> String {
        "\(memory.title)\n\n\(memory.content)"
    }

    private func forget() {
        Task {
            do {
                let message = try await model.forget()
                Haptics.success()
                app.toasts.success(message)
                dismiss()
            } catch {
                app.toasts.show(error: error)
            }
        }
    }

    private func digest() {
        Task {
            do {
                let proposal = try await model.digest()
                if proposal.staged {
                    Haptics.success()
                    app.toasts.success(proposal.message)
                    app.router.push(.digest)
                } else {
                    app.toasts.show(proposal.message.isEmpty ? "Nothing to split. This reads as a single memory." : proposal.message)
                }
            } catch {
                app.toasts.show(error: error)
            }
        }
    }

    // MARK: States

    private var detailSkeleton: some View {
        VStack(alignment: .leading, spacing: HV.Space.s) {
            HVSkeleton(height: 26, width: 260)
            HVSkeleton(height: 14, width: 180)
            Spacer().frame(height: HV.Space.s)
            ForEach(0..<6, id: \.self) { _ in
                HVSkeleton(height: 14)
            }
            HVSkeleton(height: 14, width: 200)
        }
        .padding(HV.Space.m)
        .accessibilityLabel("Loading")
    }

    private func goneView(_ message: String) -> some View {
        VStack(spacing: HV.Space.m) {
            HVEmptyState(
                symbol: "brain.head.profile",
                title: "This memory is not here",
                message: message + " It may have been forgotten. Its history can bring it back."
            )
            NavigationLink {
                MemoryHistoryView(memoryID: model.id, title: "Memory", branch: model.branch, env: model.env) {
                    Task { await model.load() }
                }
            } label: {
                Text("See its history")
                    .font(.hvSubheadline.weight(.semibold))
            }
            .buttonStyle(.hvGhost)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
