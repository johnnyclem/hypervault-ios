import HyperVaultKit
import SwiftUI

/// A page's source: read it, copy it, and for a living page write it. A write
/// names the version it was built on, so a page changed in between (by an agent,
/// by someone it is shared with) comes back as a conflict the person chooses
/// through, and nothing is overwritten by accident.
@MainActor
@Observable
final class ArtifactSourceModel {
    enum Pane: String, CaseIterable, Identifiable {
        case source = "Source"
        case page = "Page"
        case prompt = "Prompt"
        var id: String { rawValue }
    }

    private(set) var phase: ArtifactLoad<ArtifactContent> = .loading
    var draft = ""
    var isEditing = false
    private(set) var saving = false
    private(set) var conflict: ArtifactConflict?
    private(set) var saveError: String?
    /// The markup as stored (a React page's wrapper, not its JSX): read when asked.
    private(set) var stored: ArtifactLoad<String>?
    var pane: Pane = .source

    let slug: String
    let sourcePrompt: String?
    let isJsx: Bool
    private let client: HVClient

    init(client: HVClient, slug: String, sourcePrompt: String?, isJsx: Bool) {
        self.client = client
        self.slug = slug
        self.sourcePrompt = sourcePrompt
        self.isJsx = isJsx
    }

    var content: ArtifactContent? { phase.value }
    var isMutable: Bool { content?.mutable ?? false }
    var isDirty: Bool { isEditing && draft != (content?.content ?? "") }

    var panes: [Pane] {
        var panes: [Pane] = [.source]
        if isJsx { panes.append(.page) }
        if let sourcePrompt, !sourcePrompt.isEmpty { panes.append(.prompt) }
        return panes
    }

    func load() async {
        do {
            let loaded = try await client.send(.artifactContent(slug: slug))
            phase = .loaded(loaded)
            draft = loaded.content
        } catch {
            phase = .failed(ArtifactErrors.message(error))
        }
    }

    func loadStored() async {
        guard stored == nil else { return }
        stored = .loading
        do {
            stored = .loaded(try await client.send(.artifactSource(slug: slug)).content)
        } catch {
            stored = .failed(ArtifactErrors.message(error))
        }
    }

    func beginEditing() {
        guard isMutable else { return }
        draft = content?.content ?? ""
        saveError = nil
        isEditing = true
    }

    func discard() {
        draft = content?.content ?? ""
        isEditing = false
        conflict = nil
        saveError = nil
    }

    /// Commits the draft on top of the version it was read at. True when it went through.
    func save(message: String? = nil) async -> Bool {
        guard let content, !saving else { return false }
        return await write(on: content.headVersionId, message: message)
    }

    /// "Keep mine" after a conflict: write the draft on top of the head that was found.
    func keepMine() async -> Bool {
        guard let head = conflict?.headVersionId, !saving else { return false }
        conflict = nil
        return await write(on: head, message: "keep local edits")
    }

    /// "Keep editing": the conflict has been seen; the next save finds its own.
    func dismissConflict() {
        conflict = nil
    }

    /// "Use theirs": drop the edit and show the head as it stands.
    func useTheirs() async {
        conflict = nil
        isEditing = false
        await load()
    }

    private func write(on base: String?, message: String?) async -> Bool {
        saving = true
        saveError = nil
        defer { saving = false }
        // A page with no recorded version can only be written over; say so by asking for it.
        // Markup stays markup: only a React page is run through the component detector again.
        let request = ArtifactWriteRequest(
            content: draft, message: message?.isEmpty == false ? message : nil,
            baseVersionId: base, forceHtml: (content?.isJsx ?? false) ? nil : true, force: base == nil ? true : nil
        )
        do {
            _ = try await client.send(.writeArtifact(slug: slug, request))
            isEditing = false
            await load()
            return true
        } catch let error as HVError {
            if let failure = error.failure, let found = ArtifactConflict(failure: failure) {
                conflict = found
            } else {
                saveError = error.userMessage
            }
            return false
        } catch {
            saveError = ArtifactErrors.message(error)
            return false
        }
    }
}

struct ArtifactSourceSheet: View {
    let detail: ArtifactDetailModel
    /// Called after a write went through, so the page can show the new version.
    var onSaved: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @State private var model: ArtifactSourceModel
    @State private var confirmClose = false
    @State private var showConflict = false

    init(detail: ArtifactDetailModel, onSaved: @escaping () -> Void = {}) {
        self.detail = detail
        self.onSaved = onSaved
        _model = State(initialValue: ArtifactSourceModel(
            client: detail.env.client, slug: detail.slug,
            sourcePrompt: detail.summary?.sourcePrompt, isJsx: detail.summary?.isJsx ?? false
        ))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if model.panes.count > 1 { panePicker }
                content
            }
            .hvScreenBackground()
            .navigationTitle(detail.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .confirmationDialog("Discard your changes?", isPresented: $confirmClose, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { model.discard(); dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
            .sheet(isPresented: $showConflict) {
                if let conflict = model.conflict {
                    ArtifactConflictSheet(conflict: conflict, mine: model.draft) { choice in
                        showConflict = false
                        resolve(choice)
                    }
                }
            }
            .onChange(of: model.conflict) { _, conflict in showConflict = conflict != nil }
        }
        .task { await model.load() }
        .interactiveDismissDisabled(model.isDirty)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: Panes

    private var panePicker: some View {
        TruthChoicePicker(title: "Show", selection: Bindable(model).pane) {
            ForEach(model.panes) { pane in Text(pane.rawValue).tag(pane) }
        }
        .padding(.horizontal, HV.Space.m)
        .padding(.vertical, HV.Space.xs)
        .onChange(of: model.pane) { _, pane in
            if pane == .page { Task { await model.loadStored() } }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.pane {
        case .source: sourcePane
        case .page: storedPane
        case .prompt: promptPane
        }
    }

    @ViewBuilder
    private var sourcePane: some View {
        switch model.phase {
        case .loading:
            HVLoadingState(message: "Loading").frame(maxHeight: .infinity)
        case .failed(let message):
            HVErrorState(message: message) { Task { await model.load() } }.frame(maxHeight: .infinity)
        case .loaded(let content):
            VStack(spacing: 0) {
                if let line = banner(content) { bannerView(line) }
                ArtifactCodeView(text: Bindable(model).draft, isEditable: model.isEditing)
                if let error = model.saveError {
                    ArtifactErrorLine(message: error).padding(HV.Space.m)
                }
            }
        }
    }

    @ViewBuilder
    private var storedPane: some View {
        switch model.stored {
        case .none, .some(.loading):
            HVLoadingState(message: "Loading").frame(maxHeight: .infinity)
        case .some(.failed(let message)):
            HVErrorState(message: message) { Task { await model.loadStored() } }.frame(maxHeight: .infinity)
        case .some(.loaded(let text)):
            ArtifactCodeView(text: .constant(text), isEditable: false)
        }
    }

    private var promptPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HV.Space.m) {
                Text(model.sourcePrompt ?? "")
                    .font(.hvBody)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    ArtifactPasteboard.copy(model.sourcePrompt ?? "")
                    Haptics.tap()
                    app.toasts.show("Copied", style: .info)
                } label: {
                    Label("Copy prompt", systemImage: "doc.on.doc")
                }
                .buttonStyle(.hvSecondary)
            }
            .padding(HV.Space.m)
            .hvReadableWidth()
        }
    }

    private func banner(_ content: ArtifactContent) -> String? {
        if model.isEditing { return "Editing. Saving adds a version to the page's history." }
        if content.mutable { return nil }
        return "This page is frozen, so it can be read and copied but not changed."
    }

    private func bannerView(_ text: String) -> some View {
        Text(text)
            .font(.hvFootnote)
            .foregroundStyle(Palette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, HV.Space.m)
            .padding(.vertical, HV.Space.xs)
            .background(Palette.surfaceRaised)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(model.isDirty ? "Cancel" : "Done") {
                if model.isDirty { confirmClose = true } else { dismiss() }
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if model.pane == .source, model.content != nil {
                Button {
                    ArtifactPasteboard.copy(model.isEditing ? model.draft : (model.content?.content ?? ""))
                    Haptics.tap()
                    app.toasts.show("Copied", style: .info)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .accessibilityLabel("Copy source")

                if model.isEditing {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(!model.isDirty || model.saving)
                } else if model.isMutable, detail.canManage {
                    Button("Edit") { model.beginEditing() }
                }
            }
        }
    }

    // MARK: Actions

    private func save() {
        Task {
            if await model.save() {
                app.toasts.show("Saved a new version.", style: .success)
                onSaved()
            } else if model.conflict == nil {
                Haptics.failure()
            }
        }
    }

    private func resolve(_ choice: ArtifactConflictSheet.Choice) {
        Task {
            switch choice {
            case .keepMine:
                if await model.keepMine() {
                    app.toasts.show("Saved over the newer version.", style: .success)
                    onSaved()
                }
            case .useTheirs:
                await model.useTheirs()
            case .keepEditing:
                model.dismissConflict()
            }
        }
    }
}

/// A write that met a newer version: what is there now, what would change, and the choice.
struct ArtifactConflictSheet: View {
    enum Choice { case keepMine, useTheirs, keepEditing }

    let conflict: ArtifactConflict
    let mine: String
    var onChoose: (Choice) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HV.Space.m) {
                    Text("Someone changed this page while you were editing.")
                        .font(.hvTitle3)
                    Text(conflict.message)
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.textSecondary)
                    if let head = conflict.head {
                        Label("\(head.authorName ?? "Someone") wrote \"\(head.message.isEmpty ? "edit" : head.message)\"", systemImage: "clock.arrow.circlepath")
                            .font(.hvFootnote)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    HVSectionHeader(title: "What keeping yours would change").artifactCardCaption()
                    ArtifactDiffView(lines: ArtifactDiffLines.compare(old: conflict.headContent, new: mine))
                        .frame(minHeight: 160, maxHeight: 360)
                        .hvCard(padding: 0)
                }
                .padding(HV.Space.m)
                .hvReadableWidth()
            }
            .hvScreenBackground()
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: HV.Space.xs) {
                    Button("Keep the latest version") { onChoose(.useTheirs) }
                        .buttonStyle(.hvPrimary)
                    Button("Keep mine, replacing it") { onChoose(.keepMine) }
                        .buttonStyle(.hvSecondary)
                    Button("Keep editing") { onChoose(.keepEditing) }
                        .buttonStyle(.hvGhost)
                }
                .padding(HV.Space.m)
                .background(Palette.background)
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled()
    }
}
