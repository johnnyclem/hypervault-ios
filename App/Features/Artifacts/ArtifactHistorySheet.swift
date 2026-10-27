import HyperVaultKit
import SwiftUI

/// A living page's history, read like `git log`: newest first, the head marked,
/// each commit with who wrote it. A commit opens to what it changed, and can be
/// restored, which is a new commit on top (history is never rewritten).
@MainActor
@Observable
final class ArtifactHistoryModel {
    private(set) var phase: ArtifactLoad<ArtifactVersionList> = .loading
    let slug: String
    private let client: HVClient

    init(client: HVClient, slug: String) {
        self.client = client
        self.slug = slug
    }

    var head: ArtifactVersion? {
        phase.value?.versions.first { $0.isHead } ?? phase.value?.versions.first
    }

    func load() async {
        do {
            phase = .loaded(try await client.send(.artifactVersions(slug: slug, limit: 100)))
        } catch {
            phase = .failed(ArtifactErrors.message(error))
        }
    }

    /// What a commit changed: the diff from its parent. Nil parent means the first commit.
    func changes(of version: ArtifactVersion) async -> ArtifactLoad<[ArtifactDiffLine]> {
        guard let parent = version.parentVersionId else { return .loaded([]) }
        do {
            let diff = try await client.send(.artifactDiff(slug: slug, from: parent, to: version.id))
            return .loaded(ArtifactDiffLines.parse(patch: diff.patch))
        } catch {
            return .failed(ArtifactErrors.message(error))
        }
    }

    func source(at version: ArtifactVersion) async -> ArtifactLoad<String> {
        do {
            return .loaded(try await client.send(.artifactContent(slug: slug, version: version.id)).content)
        } catch {
            return .failed(ArtifactErrors.message(error))
        }
    }

    /// Makes a commit's content the head again, on top of the head the person is looking at.
    func restore(_ version: ArtifactVersion) async throws {
        _ = try await client.send(.revertArtifact(slug: slug, to: version.id, base: head?.id))
        await load()
    }
}

struct ArtifactHistorySheet: View {
    let detail: ArtifactDetailModel
    var onRestored: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var model: ArtifactHistoryModel

    init(detail: ArtifactDetailModel, onRestored: @escaping () -> Void = {}) {
        self.detail = detail
        self.onRestored = onRestored
        _model = State(initialValue: ArtifactHistoryModel(client: detail.env.client, slug: detail.slug))
    }

    var body: some View {
        NavigationStack {
            content
                .hvScreenBackground()
                .navigationTitle("History")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
                .navigationDestination(for: ArtifactVersion.self) { version in
                    ArtifactVersionScreen(model: model, version: version, canRestore: detail.isOwner != false) {
                        onRestored()
                        dismiss()
                    }
                }
        }
        .task { await model.load() }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            HVListSkeleton(rows: 5).frame(maxHeight: .infinity, alignment: .top)
        case .failed(let message):
            HVErrorState(message: message) { Task { await model.load() } }.frame(maxHeight: .infinity)
        case .loaded(let list):
            if !list.mutable || list.versions.isEmpty {
                HVEmptyState(
                    symbol: "clock.arrow.circlepath",
                    title: "No history yet",
                    message: list.mutable
                        ? "Changes to this page will be listed here, newest first."
                        : "This page is frozen. A page kept as a living page records a version for every change."
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    Section {
                        ForEach(list.versions) { version in
                            NavigationLink(value: version) { ArtifactVersionRow(version: version) }
                        }
                    }
                    .hvListRow()
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .refreshable { await model.load() }
            }
        }
    }
}

struct ArtifactVersionRow: View {
    let version: ArtifactVersion

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(version.summary)
                .font(.hvBody.weight(.medium))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(2)
            if version.isHead || version.isRebased {
                // Under the name, and wrapping, so a long message and two tags never crowd each other.
                ArtifactFlowLayout(spacing: HV.Space.xs) {
                    if version.isHead { HVTag(text: "Latest", tint: Palette.mint) }
                    if version.isRebased { HVTag(text: "Rebased", tint: Palette.amber) }
                }
            }
            HStack(spacing: HV.Space.xs) {
                HVIcon(version.authorKind == "agent" ? "cpu" : "person.fill")
                    .font(.system(size: 11))
                Text(version.authorLine)
                if let ago = LibraryCopy.ago(since: version.authoredAt ?? version.createdAt) {
                    Text("\u{00B7} \(ago)")
                }
            }
            .font(.hvFootnote)
            .foregroundStyle(Palette.textSecondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// One commit: what it changed, its whole source, and a way back to it.
struct ArtifactVersionScreen: View {
    let model: ArtifactHistoryModel
    let version: ArtifactVersion
    let canRestore: Bool
    var onRestored: () -> Void

    @Environment(AppModel.self) private var app
    @State private var changes: ArtifactLoad<[ArtifactDiffLine]> = .loading
    @State private var confirmRestore = false
    @State private var restoring = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HV.Space.m) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(version.summary).font(.hvTitle3)
                    Text(headerLine).font(.hvFootnote).foregroundStyle(Palette.textSecondary)
                }

                HVSectionHeader(title: version.parentVersionId == nil ? "First version" : "What changed").artifactCardCaption()
                changesView

                NavigationLink {
                    ArtifactVersionSource(model: model, version: version)
                } label: {
                    HVRow(symbol: "doc.plaintext", tint: Palette.blue, title: "See the whole source") {
                        HVIcon(HVSymbol.open).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.textTertiary)
                    }
                }
                .buttonStyle(.plain)
                .hvCard(padding: HV.Space.s)

                if let error { ArtifactErrorLine(message: error) }
            }
            .padding(HV.Space.m)
            .hvReadableWidth()
        }
        .hvScreenBackground()
        .navigationTitle("Version")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if canRestore, !version.isHead {
                Button {
                    confirmRestore = true
                } label: {
                    if restoring { ProgressView().tint(.white) } else { Text("Restore this version") }
                }
                .buttonStyle(.hvPrimary)
                .disabled(restoring)
                .padding(HV.Space.m)
                .background(Palette.background)
            }
        }
        .confirmationDialog("Restore this version?", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("Restore") { restore() }
        } message: {
            Text("It becomes the newest version. The versions after it stay in the history.")
        }
        .task { changes = await model.changes(of: version) }
    }

    private var headerLine: String {
        var parts = [version.authorLine]
        if let ago = LibraryCopy.ago(since: version.authoredAt ?? version.createdAt) { parts.append(ago) }
        if version.isHead { parts.append("latest") }
        return parts.joined(separator: " \u{00B7} ")
    }

    @ViewBuilder
    private var changesView: some View {
        switch changes {
        case .loading:
            HVLoadingState().hvCard(padding: 0)
        case .failed(let message):
            ArtifactErrorLine(message: message)
        case .loaded(let lines):
            ArtifactDiffView(lines: lines)
                .frame(maxHeight: 480)
                .hvCard(padding: 0)
        }
    }

    private func restore() {
        restoring = true
        error = nil
        Task {
            defer { restoring = false }
            do {
                try await model.restore(version)
                app.toasts.show("Restored. It is the newest version now.", style: .success)
                onRestored()
            } catch {
                self.error = ArtifactErrors.message(error)
                Haptics.failure()
            }
        }
    }
}

/// The whole source at one commit, to read and copy.
struct ArtifactVersionSource: View {
    let model: ArtifactHistoryModel
    let version: ArtifactVersion

    @Environment(AppModel.self) private var app
    @State private var source: ArtifactLoad<String> = .loading

    var body: some View {
        Group {
            switch source {
            case .loading:
                HVLoadingState().frame(maxHeight: .infinity)
            case .failed(let message):
                HVErrorState(message: message).frame(maxHeight: .infinity)
            case .loaded(let text):
                ArtifactCodeView(text: .constant(text), isEditable: false)
            }
        }
        .hvScreenBackground()
        .navigationTitle("Source")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if case .loaded(let text) = source {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        ArtifactPasteboard.copy(text)
                        Haptics.tap()
                        app.toasts.show("Copied", style: .info)
                    } label: {
                        Image(systemName: HVSymbol.copy)
                    }
                    .accessibilityLabel("Copy source")
                }
            }
        }
        .task { source = await model.source(at: version) }
    }
}

/// A diff, line by line: added lines green, removed lines red, the unchanged
/// folded. `nil` is a pair of texts too long to compare on a phone.
struct ArtifactDiffView: View {
    let lines: [ArtifactDiffLine]?

    var body: some View {
        if let lines {
            if lines.isEmpty {
                Text("Nothing changed.")
                    .font(.hvCallout)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(HV.Space.m)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(lines) { line in row(line) }
                    }
                }
            }
        } else {
            Text("These are too long to compare here. Open the source to read them.")
                .font(.hvCallout)
                .foregroundStyle(Palette.textSecondary)
                .padding(HV.Space.m)
        }
    }

    private func row(_ line: ArtifactDiffLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(marker(line.kind))
                .foregroundStyle(color(line.kind))
                .frame(width: 12, alignment: .center)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(line.kind == .hunk || line.kind == .note ? Palette.textSecondary : Palette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.hvMono)
        .padding(.horizontal, HV.Space.xs)
        .padding(.vertical, 2)
        .background(background(line.kind))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility(line))
    }

    private func marker(_ kind: ArtifactDiffLine.Kind) -> String {
        switch kind {
        case .added: return "+"
        case .removed: return "\u{2212}"
        case .context, .hunk, .note: return " "
        }
    }

    private func color(_ kind: ArtifactDiffLine.Kind) -> Color {
        switch kind {
        case .added: return Palette.success
        case .removed: return Palette.danger
        case .context, .hunk, .note: return Palette.textTertiary
        }
    }

    private func background(_ kind: ArtifactDiffLine.Kind) -> Color {
        switch kind {
        case .added: return Palette.success.opacity(0.14)
        case .removed: return Palette.danger.opacity(0.14)
        case .hunk: return Palette.surfaceRaised
        case .context, .note: return .clear
        }
    }

    private func accessibility(_ line: ArtifactDiffLine) -> String {
        switch line.kind {
        case .added: return "Added: \(line.text)"
        case .removed: return "Removed: \(line.text)"
        case .context: return line.text
        case .hunk: return line.text
        case .note: return line.text
        }
    }
}
