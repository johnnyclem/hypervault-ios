import HyperVaultKit
import SwiftUI
import UniformTypeIdentifiers

/// What the sheet is keeping: something written or pasted, a document, a link.
private enum MemorizeKind: String, CaseIterable, Identifiable {
    case write, file, link

    var id: String { rawValue }

    var title: String {
        switch self {
        case .write: return "Write"
        case .file: return "File"
        case .link: return "Link"
        }
    }
}

/// "Memorize this": write or paste a chunk worth keeping, or bring in a
/// document or a web page. Everything is titled, tagged, summarized and linked
/// by the server; the person adds nothing unless they want to.
struct MemorizeSheet: View {
    let list: MemoryListModel

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var kind: MemorizeKind = .write
    @State private var draft = MemoryDraft()
    @State private var link = ""
    @State private var picked: PickedFile?
    @State private var showImporter = false
    @State private var isWorking = false
    /// Where a file that goes by way of storage is: the long part of a big import, with a line to say so.
    @State private var stage: MemoryFileImporter.Stage?
    /// The file import in flight, so that Cancel and a swipe down can stop it: a big file is on its way up a phone connection,
    /// and nothing else would end it. A note or a link is a small request the person expects to be kept, so it is not stopped.
    @State private var fileImport: Task<Void, Never>?
    @State private var problem: String?
    @FocusState private var focus: Field?

    private enum Field { case content, title, tags, link }

    struct PickedFile: Equatable {
        let name: String
        let data: Data
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HV.Space.l) {
                    HVChoicePicker(title: "What to keep", selection: $kind) {
                        ForEach(MemorizeKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }

                    switch kind {
                    case .write: writeForm
                    case .file: fileForm
                    case .link: linkForm
                    }

                    if let problem {
                        Text(problem)
                            .font(.hvFootnote)
                            .foregroundStyle(Palette.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isStaticText)
                    }

                    Button(action: submit) {
                        if isWorking { ProgressView().tint(Palette.onAction) } else { Text(actionTitle) }
                    }
                    .buttonStyle(.hvPrimary)
                    .disabled(!canSubmit || isWorking)

                    NavigationLink {
                        MemoryExportPromptView()
                    } label: {
                        HVRow(symbol: HVSymbol.importData, title: "Bring memories from another AI", subtitle: "Ask ChatGPT, Gemini or Grok to hand over what it knows")
                    }
                    .buttonStyle(.plain)
                    .padding(.top, HV.Space.xs)
                }
                .padding(HV.Space.m)
                .hvReadableWidth()
            }
            .scrollDismissesKeyboard(.interactively)
            .hvScreenBackground()
            .navigationTitle("Memorize")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        stopFileImport()
                        dismiss()
                    }
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.importTypes, allowsMultipleSelection: false) { result in
                handlePick(result)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        // On the stack and not on its first screen, which also disappears when "Bring memories from another AI" is pushed.
        .onDisappear { stopFileImport() }
    }

    // MARK: Forms

    private var limitLabel: String { MemoryLimits.label(forBytes: list.env.limits.memoryBytes) }

    /// The most a file may be, as the server says it ("10 MB"; "4 MB" from a server that does not say).
    private var fileLimitLabel: String { MemoryImportPolicy.fileLabel(limits: list.env.limits) }

    private var writeForm: some View {
        VStack(alignment: .leading, spacing: HV.Space.m) {
            Text("Paste anything from a chat or a coding session. It is titled, tagged, summarized and linked for you.")
                .font(.hvCallout)
                .foregroundStyle(Palette.textSecondary)

            VStack(alignment: .leading, spacing: HV.Space.xs) {
                HVLabeledField(title: "What to keep") {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $draft.content)
                            .focused($focus, equals: .content)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 150)
                        if draft.content.isEmpty {
                            // A hint inside the editor; the label above is what names it. The insets are the editor's own.
                            Text("Paste or write something")
                                .foregroundStyle(Palette.textTertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
                }
                HStack {
                    HVPasteButton { strings in
                        guard let text = strings.first, !text.isEmpty else { return }
                        draft.content = draft.content.isEmpty ? text : draft.content + "\n\n" + text
                    }
                    Spacer()
                    Text(sizeLine)
                        .font(.hvCaption)
                        .foregroundStyle(isOverLimit ? Palette.danger : Palette.textSecondary)
                }
            }

            HVLabeledField(title: "Title", footnote: "Optional. Left blank, it is titled for you.") {
                TextField("A short name", text: $draft.title, prompt: Text.hvPrompt("A short name"))
                    .focused($focus, equals: .title)
            }
            HVLabeledField(title: "Tags", footnote: "Optional. Separate them with commas.") {
                TextField("trip, passports", text: $draft.tagsText, prompt: Text.hvPrompt("trip, passports"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .tags)
            }
            HStack {
                Text("Where it came from")
                    .font(.hvSubheadline)
                    .foregroundStyle(Palette.textSecondary)
                Spacer()
                Picker("Where it came from", selection: $draft.source) {
                    ForEach(MemorySource.writable, id: \.self) { source in
                        Text(source == "manual" ? "Me" : MemorySource.label(source)).tag(source)
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    private var fileForm: some View {
        VStack(alignment: .leading, spacing: HV.Space.s) {
            Text("A PDF, a Word document, Markdown or plain text becomes a memory. Up to \(fileLimitLabel).")
                .font(.hvCallout)
                .foregroundStyle(Palette.textSecondary)
            Button {
                problem = nil
                showImporter = true
            } label: {
                HStack(spacing: HV.Space.s) {
                    HVIcon(picked == nil ? "doc.badge.plus" : "doc.text.fill")
                        .font(.title3)
                        .foregroundStyle(Palette.textSecondary)
                    VStack(alignment: .leading, spacing: HV.Space.xxs) {
                        Text(picked?.name ?? "Choose a file")
                            .font(.hvBody)
                            .foregroundStyle(Palette.textPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if let picked {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(picked.data.count), countStyle: .file))
                                .font(.hvCaption)
                                .foregroundStyle(Palette.textSecondary)
                        }
                    }
                    Spacer()
                    Text(picked == nil ? "Browse" : "Change")
                        .font(.hvSubheadline)
                        .foregroundStyle(Color.accentColor)
                }
                .hvCard()
            }
            .buttonStyle(.plain)
            .disabled(isWorking)

            // A big file is put in storage before the server reads it, which takes a while on a phone connection.
            if isWorking, let stage {
                Text(stage.line)
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    private var linkForm: some View {
        VStack(alignment: .leading, spacing: HV.Space.s) {
            Text("A GitHub repository becomes a digest of the project. Any other page is kept as a note.")
                .font(.hvCallout)
                .foregroundStyle(Palette.textSecondary)
            HVLabeledField(title: "Link") {
                TextField("github.com/owner/repo, or any article", text: $link, prompt: Text.hvPrompt("github.com/owner/repo, or any article"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .focused($focus, equals: .link)
                    .onSubmit(submit)
            }
        }
    }

    // MARK: State

    private var sizeLine: String {
        let bytes = draft.trimmedContent.utf8.count
        if bytes == 0 { return "Up to \(limitLabel)" }
        return "\(MemoryLimits.label(forBytes: bytes)) of \(limitLabel)"
    }

    private var isOverLimit: Bool { draft.trimmedContent.utf8.count > list.env.limits.memoryBytes }

    private var actionTitle: String {
        switch kind {
        case .write: return "Memorize"
        case .file: return "Import file"
        case .link: return "Import link"
        }
    }

    private var canSubmit: Bool {
        switch kind {
        case .write: return !draft.trimmedContent.isEmpty && !isOverLimit
        case .file: return picked != nil
        case .link: return MemoryImportPolicy.normalizedURL(link) != nil
        }
    }

    // MARK: Picking a file

    static var importTypes: [UTType] {
        var types: [UTType] = [.pdf, .plainText, .text]
        for ext in ["docx", "md", "markdown", "mdx"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }

    private func handlePick(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            problem = MemoryErrors.message(error)
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let name = url.lastPathComponent
                if let refusal = MemoryImportPolicy.problem(filename: name, byteCount: data.count, limits: list.env.limits) {
                    picked = nil
                    problem = refusal
                } else {
                    picked = PickedFile(name: name, data: data)
                    problem = nil
                }
            } catch {
                problem = "That file could not be read. \(MemoryErrors.message(error))"
            }
        }
    }

    // MARK: Sending

    /// Ends a file import that is still going. It finishes as a cancellation, which `submit` shows no sentence for.
    private func stopFileImport() {
        fileImport?.cancel()
        fileImport = nil
    }

    private func submit() {
        guard canSubmit, !isWorking else { return }
        if kind == .write, let refusal = draft.problem(limitBytes: list.env.limits.memoryBytes) {
            problem = refusal
            return
        }
        focus = nil
        problem = nil
        isWorking = true
        let client = list.client
        let branch = list.branch
        let limits = list.env.limits
        let kind = self.kind
        let draft = self.draft
        let picked = self.picked
        let link = MemoryImportPolicy.normalizedURL(self.link)
        let work = Task {
            do {
                let kept: MemoryKept
                switch kind {
                case .write:
                    kept = try await client.send(.memoryCreate(draft, branch: branch))
                case .file:
                    guard let picked else { return }
                    // The importer sends a file in the request when it fits and by way of storage when it does not.
                    kept = try await MemoryFileImporter(client: client, limits: limits)
                        .importFile(filename: picked.name, data: picked.data, branch: branch) {
                            // The line is on the screen, and a line that appears or changes is not read out by itself.
                            stage = $0
                            VoiceOverAnnouncer.shared.announce(stage: $0)
                        }
                case .link:
                    guard let link else { return }
                    kept = try await client.send(.memoryImport(url: link, branch: branch))
                }
                isWorking = false
                stage = nil
                list.didKeep(kept)
                app.toasts.success(kept.message.isEmpty ? HVCopy.keptInMemoryLine : kept.message)
                dismiss()
            } catch {
                isWorking = false
                stage = nil
                if !MemoryErrors.isCancelled(error) {
                    problem = (error as? HVError).map { MemoryImportPolicy.message(for: $0, limits: limits) } ?? error.localizedDescription
                    Haptics.failure()
                }
            }
        }
        if kind == .file { fileImport = work }
    }
}
