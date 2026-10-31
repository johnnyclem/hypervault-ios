import HyperVaultKit
import SwiftUI

/// A group of files that runs as one web app: the files, edited one at a time, a
/// preview that runs them together, and the same changes the web editor makes
/// (add a file, change one, remove one; the root index.html stays).
@MainActor
@Observable
final class GroupEditorModel {
    /// The slug of a group being edited; nil while one is being made.
    private(set) var slug: String?
    var title = ""
    var tags = ""
    var isPrivate = true
    private(set) var files: [ArtifactGroupFile] = []
    private(set) var phase: ArtifactLoad<Bool> = .loaded(true)
    private(set) var saving = false
    private(set) var error: String?

    private var savedFiles: [ArtifactGroupFile] = []
    private var savedTitle = ""
    private var savedTags = ""
    private var savedPrivate = true
    private let client: HVClient

    init(client: HVClient, slug: String?) {
        self.client = client
        self.slug = slug
        if slug == nil {
            files = ArtifactGroupRules.starterFiles
        } else {
            phase = .loading
        }
    }

    var isEditing: Bool { slug != nil }

    /// False while the group is still being read, or could not be.
    var isReady: Bool {
        if case .loaded = phase { return true }
        return false
    }

    var isDirty: Bool {
        guard isEditing else { return true }
        return title != savedTitle || tags != savedTags || isPrivate != savedPrivate || files != savedFiles
    }

    func load() async {
        guard let slug else { return }
        phase = .loading
        do {
            let group = try await client.send(.artifactGroup(slug: slug))
            title = group.title
            tags = group.tags.joined(separator: ", ")
            isPrivate = group.visibility != .public
            files = ArtifactGroupRules.sorted(group.files)
            savedFiles = files
            savedTitle = title
            savedTags = tags
            savedPrivate = isPrivate
            phase = .loaded(true)
        } catch {
            phase = .failed(ArtifactErrors.message(error))
        }
    }

    // MARK: Files

    func content(of path: String) -> String {
        files.first { $0.path == path }?.content ?? ""
    }

    func setContent(_ content: String, of path: String) {
        guard let index = files.firstIndex(where: { $0.path == path }) else { return }
        // Made again rather than changed, so its size is the new content's, as the server's will be.
        files[index] = ArtifactGroupFile(path: path, content: content)
    }

    /// Adds an empty file. Returns the sentence that says why not, if it cannot.
    func addFile(_ rawPath: String) -> String? {
        switch ArtifactGroupRules.validate(path: rawPath) {
        case .failure(let failure):
            return failure.message
        case .success(let path):
            if files.contains(where: { $0.path.lowercased() == path.lowercased() }) { return "\"\(path)\" already exists." }
            files.append(ArtifactGroupFile(path: path, content: ""))
            files = ArtifactGroupRules.sorted(files)
            return nil
        }
    }

    func rename(_ path: String, to rawPath: String) -> String? {
        guard ArtifactGroupRules.isRemovable(path) else { return "index.html is the page everything starts from, so it keeps its name." }
        switch ArtifactGroupRules.validate(path: rawPath) {
        case .failure(let failure):
            return failure.message
        case .success(let next):
            if next == path { return nil }
            if files.contains(where: { $0.path.lowercased() == next.lowercased() && $0.path != path }) { return "\"\(next)\" already exists." }
            guard let index = files.firstIndex(where: { $0.path == path }) else { return nil }
            files[index] = ArtifactGroupFile(path: next, content: files[index].content)
            files = ArtifactGroupRules.sorted(files)
            return nil
        }
    }

    func remove(_ path: String) {
        guard ArtifactGroupRules.isRemovable(path) else { return }
        files.removeAll { $0.path == path }
    }

    /// The whole group as one document, to run.
    var previewDocument: String {
        let index = files.first { $0.path == ArtifactGroupRules.indexFile }?.content ?? ""
        return ArtifactGroupPreview.document(indexHTML: index, files: files)
    }

    // MARK: Saving

    /// Makes the group, or writes the changes. Returns the slug when it went through.
    func save() async -> String? {
        if let failure = ArtifactGroupRules.validate(files: files) {
            error = failure.message
            return nil
        }
        saving = true
        error = nil
        defer { saving = false }
        let tagList = NewArtifactModel.list(tags)
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibility: ArtifactVisibility = isPrivate ? .private : .public

        guard let slug else {
            do {
                let made = try await client.send(.createArtifactGroup(
                    title: name.isEmpty ? "Untitled group" : name, files: files, tags: tagList, visibility: visibility
                ))
                self.slug = made.slug
                savedFiles = files
                savedTitle = title
                savedTags = tags
                savedPrivate = isPrivate
                return made.slug
            } catch {
                self.error = ArtifactErrors.message(error)
                return nil
            }
        }

        do {
            if title != savedTitle || tags != savedTags || isPrivate != savedPrivate {
                // A group that is behind a password keeps it unless the person chose the other way.
                let next: ArtifactVisibility? = isPrivate == savedPrivate ? nil : visibility
                _ = try await client.send(.updateArtifactGroup(
                    slug: slug, title: name.isEmpty ? "Untitled group" : name, tags: tagList, visibility: next
                ))
                savedTitle = title
                savedTags = tags
                savedPrivate = isPrivate
            }
            // Each step is saved as it lands, so a save that stops half way is finished by the next one:
            // an add the server has already taken would answer 409, a remove it has already done 404.
            for step in ArtifactGroupChanges(saved: savedFiles, now: files).steps {
                switch step {
                case .add(let file):
                    do { _ = try await client.send(.addGroupFile(slug: slug, path: file.path, content: file.content)) } catch { throw GroupStepError("add", file.path, error) }
                    savedFiles = ArtifactGroupRules.sorted(savedFiles + [file])
                case .write(let file):
                    do { _ = try await client.send(.writeGroupFile(slug: slug, path: file.path, content: file.content)) } catch { throw GroupStepError("save", file.path, error) }
                    savedFiles = ArtifactGroupRules.sorted(savedFiles.filter { $0.path != file.path } + [file])
                case .remove(let path):
                    do { _ = try await client.send(.deleteGroupFile(slug: slug, path: path)) } catch { throw GroupStepError("remove", path, error) }
                    savedFiles.removeAll { $0.path == path }
                }
            }
            savedFiles = files
            return slug
        } catch {
            let message = (error as? GroupStepError)?.message ?? ArtifactErrors.message(error)
            await reconcile(slug: slug)
            // A step can go through and only its answer be lost. If the server then holds everything, it is saved.
            if nothingLeftToSend {
                savedFiles = files
                return slug
            }
            self.error = message
            return nil
        }
    }

    private var nothingLeftToSend: Bool {
        title == savedTitle && tags == savedTags && isPrivate == savedPrivate
            && ArtifactGroupChanges(saved: savedFiles, now: files).isEmpty
    }

    /// After a failure the server may hold more than the person was told: a step can go through and its answer
    /// be lost on the way back. Read the group again and take its word for the files this save was about, so
    /// the next save sends only what is still missing. The person's edits and any file the save never named
    /// (one added somewhere else) are left alone.
    private func reconcile(slug: String) async {
        guard let group = try? await client.send(.artifactGroup(slug: slug)) else { return }
        let named = Set(files.map(\.path)).union(savedFiles.map(\.path))
        savedFiles = ArtifactGroupRules.sorted(savedFiles.filter { !named.contains($0.path) } + group.files.filter { named.contains($0.path) })
    }

    /// A step of a save that the server refused, named so the person knows which file.
    struct GroupStepError: Error {
        let message: String

        init(_ verb: String, _ path: String, _ underlying: Error) {
            self.message = "Couldn't \(verb) \"\(path)\": \(ArtifactErrors.message(underlying))"
        }
    }
}

struct GroupEditorView: View {
    /// Called with the group's slug when the person is done (nil when they leave without keeping one).
    var onDone: (String?) -> Void

    @Environment(AppModel.self) private var app
    @State private var model: GroupEditorModel
    @State private var path = NavigationPath()
    @State private var addingFile = false
    @State private var newFileName = ""
    @State private var addError: String?
    @State private var renaming: String?
    @State private var renameTo = ""
    @State private var previewing = false
    @State private var confirmClose = false
    private let env: AppEnvironment

    init(env: AppEnvironment, slug: String?, onDone: @escaping (String?) -> Void) {
        self.env = env
        self.onDone = onDone
        _model = State(initialValue: GroupEditorModel(client: env.client, slug: slug))
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .hvScreenBackground()
                .navigationTitle(model.isEditing ? (model.title.isEmpty ? "Group" : model.title) : "New group")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: String.self) { file in
                    GroupFileScreen(model: model, path: file) { previewing = true }
                }
                .toolbar { toolbar }
        }
        .task { await model.load() }
        .interactiveDismissDisabled(model.isDirty || model.saving)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $previewing) {
            GroupPreviewSheet(document: model.previewDocument, env: env)
        }
        .alert("New file", isPresented: $addingFile) {
            TextField("app.js", text: $newFileName, prompt: artifactPrompt("app.js"))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Add") { addFile() }
            Button("Cancel", role: .cancel) { newFileName = "" }
        } message: {
            Text(addError ?? "A .html, .css, .js or .jsx file. Use folders like styles/app.css if you like.")
        }
        .alert("Rename file", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameTo, prompt: artifactPrompt("Name"))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Rename") { rename() }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Discard your changes?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { onDone(model.slug) }
            Button("Keep editing", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            HVListSkeleton(rows: 5).frame(maxHeight: .infinity, alignment: .top)
        case .failed(let message):
            HVErrorState(message: message) { Task { await model.load() } }.frame(maxHeight: .infinity)
        case .loaded:
            list
        }
    }

    private var list: some View {
        List {
            Section {
                HVLabeledField(title: "Title") {
                    TextField("Title", text: Bindable(model).title, prompt: artifactPrompt("Untitled group"))
                }
                .listRowSeparator(.hidden)
                HVLabeledField(title: "Tags", footnote: "Separated by commas.") {
                    TextField("Tags", text: Bindable(model).tags, prompt: artifactPrompt("Optional"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .listRowSeparator(.hidden)
                Toggle("Keep it private", isOn: Bindable(model).isPrivate)
            } footer: {
                Text(model.isPrivate ? "Only you and people you add can open it." : "Anyone with the link can open it.")
                    .hvSectionNote()
            }
            .hvListRow()

            Section {
                ForEach(model.files) { file in
                    NavigationLink(value: file.path) {
                        HStack {
                            HVIcon(icon(for: file.path)).foregroundStyle(Palette.textSecondary).hvIconSlot(22)
                            Text(file.path).font(.hvMono).foregroundStyle(Palette.textPrimary).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: HV.Space.xs)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(file.content.utf8.count), countStyle: .file))
                                .font(.hvCaption)
                                .foregroundStyle(Palette.textTertiary)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        if ArtifactGroupRules.isRemovable(file.path) {
                            Button(role: .destructive) { model.remove(file.path) } label: { Label("Remove", systemImage: HVSymbol.delete) }
                        }
                    }
                    .contextMenu {
                        if ArtifactGroupRules.isRemovable(file.path) {
                            Button { renameTo = file.path; renaming = file.path } label: { Label("Rename", systemImage: "pencil") }
                            Button(role: .destructive) { model.remove(file.path) } label: { Label("Remove", systemImage: HVSymbol.delete) }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityHint(ArtifactGroupRules.isRemovable(file.path) ? "" : "The page everything starts from. It can be edited but not removed.")
                }
                Button {
                    newFileName = ""
                    addError = nil
                    addingFile = true
                } label: {
                    Label("Add a file", systemImage: HVSymbol.add).hvRowLabel()
                }
            } header: {
                HVSectionHeader(title: "Files", detail: "\(model.files.count) of \(ArtifactGroupRules.maxFiles)")
            } footer: {
                Text("index.html is where it starts, so it can be changed but not removed.")
                    .hvSectionNote()
            }
            .hvListRow()

            Section {
                Button { previewing = true } label: { Label("Run the preview", systemImage: "play.fill").hvRowLabel() }
                if let error = model.error { ArtifactErrorLine(message: error).listRowBackground(Color.clear) }
            }
            .hvListRow()

            Section {
                DisclosureGroup("How this works") {
                    Text(ArtifactGroupRules.instructions)
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            .hvListRow()
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(model.isDirty && model.isEditing ? "Cancel" : "Close") {
                if model.isDirty && model.isEditing { confirmClose = true } else { onDone(model.slug) }
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button(model.isEditing ? "Save" : "Create") { save() }
                .fontWeight(.semibold)
                .disabled(model.saving || !model.isDirty || !model.isReady)
        }
    }

    private func icon(for path: String) -> String {
        switch path.split(separator: ".").last?.lowercased() {
        case "html": return "chevron.left.forwardslash.chevron.right"
        case "css": return "paintbrush"
        case "js", "jsx": return "curlybraces"
        default: return "doc"
        }
    }

    private func addFile() {
        if let failure = model.addFile(newFileName) {
            addError = failure
            // The alert closed on tapping Add: open it again with the sentence, keeping what was typed.
            DispatchQueue.main.async { addingFile = true }
        } else {
            let added = ArtifactGroupRules.normalize(newFileName)
            newFileName = ""
            addError = nil
            path.append(added)
        }
    }

    private func rename() {
        guard let old = renaming else { return }
        renaming = nil
        if let failure = model.rename(old, to: renameTo) {
            app.toasts.show(failure, style: .error)
        }
    }

    private func save() {
        Task {
            let wasEditing = model.isEditing
            if let slug = await model.save() {
                if wasEditing {
                    app.toasts.show("Saved.", style: .success)
                } else {
                    app.toasts.show("Created. Its link is ready.", style: .success)
                    onDone(slug)
                }
            } else {
                Haptics.failure()
            }
        }
    }
}

/// One file of the group, to read and write.
struct GroupFileScreen: View {
    let model: GroupEditorModel
    let path: String
    var onRun: () -> Void

    var body: some View {
        ArtifactCodeView(
            text: Binding(get: { model.content(of: path) }, set: { model.setContent($0, of: path) }),
            isEditable: true
        )
        .hvScreenBackground()
        .navigationTitle(path)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onRun) { Label("Run", systemImage: "play.fill") }
            }
        }
    }
}

/// The group, run: every file it names inlined into one page, so it needs nothing from the server.
struct GroupPreviewSheet: View {
    let document: String
    let env: AppEnvironment

    @Environment(\.dismiss) private var dismiss
    @State private var content: ArtifactWebContent

    init(document: String, env: AppEnvironment) {
        self.document = document
        self.env = env
        _content = State(initialValue: ArtifactWebContent(source: .html(document, base: env.server.baseURL)))
    }

    var body: some View {
        NavigationStack {
            ArtifactWebView(
                content: content,
                router: ArtifactLinkRouter(serverHost: env.server.baseURL.host, domains: env.capabilities.domains.map(\.domain))
            )
            .navigationTitle("Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.large])
    }
}
