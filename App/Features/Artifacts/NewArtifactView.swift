import HyperVaultKit
import SwiftUI
import UniformTypeIdentifiers

/// Keeping something an AI made: paste it (or load a file), name it if you like,
/// choose who can open it, and keep it. The server decides whether it is HTML or
/// a React component and wraps the second so it runs.
@MainActor
@Observable
final class NewArtifactModel {
    var title = ""
    var content = ""
    var sourcePrompt = ""
    var tags = ""
    var connectTo = ""
    var visibility: ArtifactVisibility = .private
    var forceHtml = false
    var installable = true
    var living = false
    private(set) var loadedFileName: String?
    private(set) var saving = false
    private(set) var error: String?
    private(set) var result: ArtifactSaveResult?

    /// "jsx" when the text came from a `.jsx` or `.tsx` file: the server then runs it as a component even when detection is unsure.
    private var typeHint: String?
    private let client: HVClient
    private let limits: Capabilities.Limits

    init(client: HVClient, limits: Capabilities.Limits) {
        self.client = client
        self.limits = limits
    }

    var contentBytes: Int { content.utf8.count }
    var isOverLimit: Bool { contentBytes > limits.artifactBytes }
    var promptCount: Int { sourcePrompt.trimmingCharacters(in: .whitespacesAndNewlines).count }
    var promptIsOverLimit: Bool { promptCount > limits.sourcePromptChars }
    var promptLimit: Int { limits.sourcePromptChars }
    var byteLimit: Int { limits.artifactBytes }

    var canKeep: Bool {
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isOverLimit && !promptIsOverLimit && !saving
    }

    /// The limit, in the server's words, before it has to say it with a 413.
    var limitMessage: String? {
        if isOverLimit { return "Artifact is over the \(Self.megabytes(limits.artifactBytes)) limit. Trim embedded assets and try again." }
        if promptIsOverLimit { return "The source prompt is over the \(limits.sourcePromptChars.formatted()) character limit." }
        return nil
    }

    func typed(_ text: String) {
        content = text
        loadedFileName = nil
        typeHint = nil
        result = nil
        error = nil
    }

    /// Text from a file the person picked. Returns a sentence when it cannot be used.
    func load(data: Data, filename: String) -> String? {
        guard data.count <= limits.artifactBytes else {
            return "That file is over the \(Self.megabytes(limits.artifactBytes)) limit."
        }
        guard let text = String(data: data, encoding: .utf8) else { return "That file isn't text, so it can't be kept as a page." }
        content = text
        loadedFileName = filename
        let base = (filename as NSString).deletingPathExtension
        if title.trimmingCharacters(in: .whitespaces).isEmpty { title = base }
        let ext = (filename as NSString).pathExtension.lowercased()
        typeHint = (ext == "jsx" || ext == "tsx") ? "jsx" : nil
        result = nil
        error = nil
        return nil
    }

    func keep() async {
        guard canKeep else { return }
        saving = true
        error = nil
        defer { saving = false }
        let request = ArtifactSaveRequest(
            content: content,
            title: Self.nonEmpty(title),
            type: forceHtml ? nil : typeHint,
            tags: Self.list(tags),
            connectTo: Self.list(connectTo),
            makePwa: installable,
            forceHtml: forceHtml,
            mutable: living,
            visibility: visibility,
            sourcePrompt: Self.nonEmpty(sourcePrompt)
        )
        do {
            result = try await client.send(.saveArtifact(request))
        } catch {
            // What was typed stays where it is: nothing is lost to a failed keep.
            self.error = ArtifactErrors.message(error)
        }
    }

    /// Starts over for the next thing.
    func reset() {
        title = ""
        content = ""
        sourcePrompt = ""
        tags = ""
        connectTo = ""
        loadedFileName = nil
        typeHint = nil
        result = nil
        error = nil
    }

    static func list(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }
            .filter { !$0.isEmpty }
    }

    static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func megabytes(_ bytes: Int) -> String {
        bytes % 1_000_000 == 0 ? "\(bytes / 1_000_000) MB" : String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }
}

struct NewArtifactView: View {
    /// Called with the kept page when the person opens it, nil when they just close.
    var onDone: (ArtifactSaveResult?) -> Void

    @State private var model: NewArtifactModel
    @State private var importing = false
    @State private var fileError: String?
    @State private var showMore = false
    @FocusState private var titleFocused: Bool

    init(env: AppEnvironment, onDone: @escaping (ArtifactSaveResult?) -> Void) {
        self.onDone = onDone
        _model = State(initialValue: NewArtifactModel(client: env.client, limits: env.limits))
    }

    var body: some View {
        NavigationStack {
            Group {
                if let result = model.result {
                    ArtifactKeptView(result: result, onOpen: { onDone(result) }, onAnother: { model.reset() })
                } else {
                    form
                }
            }
            .hvScreenBackground()
            // The kept page has no bar title: its headline (the web's "Kept. Here's the link.") already says it.
            .navigationTitle(model.result == nil ? "New page" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(model.result == nil ? "Cancel" : "Done") { onDone(nil) } }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(model.saving)
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.fileTypes, allowsMultipleSelection: false) { picked in
            read(picked)
        }
    }

    // MARK: Form

    /// "0 KB", "12 KB": the formatter's own "Zero KB" reads oddly next to a limit.
    private static func size(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private static var fileTypes: [UTType] {
        var types: [UTType] = [.html, .plainText, .text, .sourceCode]
        for ext in ["jsx", "tsx", "md", "markdown"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HV.Space.l) {
                Text("Paste anything your AI made. If it is a React component, it is wrapped into a page that runs.")
                    .font(.hvCallout)
                    .foregroundStyle(Palette.textSecondary)

                contentField
                titleField
                visibilityField
                moreOptions

                if let message = model.limitMessage { ArtifactErrorLine(message: message) }
                if let fileError { ArtifactErrorLine(message: fileError) }
                if let error = model.error { ArtifactErrorLine(message: error) }
            }
            .padding(HV.Space.m)
            .hvReadableWidth()
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: HV.Space.xs) {
                // A button that is off should say what turns it on.
                if model.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Paste something to keep it.")
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.textSecondary)
                }
                Button {
                    Task {
                        await model.keep()
                        if model.result != nil { Haptics.success() } else if model.error != nil { Haptics.failure() }
                    }
                } label: {
                    if model.saving { ProgressView().tint(.white) } else { Text("Keep it") }
                }
                .buttonStyle(.hvPrimary)
                .disabled(!model.canKeep)
            }
            .padding(HV.Space.m)
            .background(Palette.background)
        }
    }

    private var contentField: some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            // The heading and the two buttons share a row while they fit; at a large text size the buttons drop under it,
            // and at the largest, where the two do not fit side by side either, they stack.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: HV.Space.xs) {
                    HVSectionHeader(title: "Paste from chat")
                    Spacer()
                    pasteAndFile
                }
                VStack(alignment: .leading, spacing: HV.Space.xs) {
                    HVSectionHeader(title: "Paste from chat")
                    HStack(spacing: HV.Space.xs) { pasteAndFile }
                }
                VStack(alignment: .leading, spacing: HV.Space.xs) {
                    HVSectionHeader(title: "Paste from chat")
                    pasteAndFile
                }
            }
            ArtifactCodeView(
                text: Bindable(model).content,
                isEditable: true,
                identifier: "artifact.new.content",
                placeholder: "Paste HTML or a React component. We'll work out which and make it run."
            )
                .frame(height: 260)
                .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: HV.Radius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: HV.Radius.control, style: .continuous)
                        .strokeBorder(Palette.border, lineWidth: 1)
                        .allowsHitTesting(false)
                )
            HStack {
                if let name = model.loadedFileName {
                    Label("From \(name)", systemImage: "doc").font(.hvCaption).foregroundStyle(Palette.textSecondary)
                }
                Spacer()
                Text("\(Self.size(model.contentBytes)) of \(NewArtifactModel.megabytes(model.byteLimit))")
                    .font(.hvCaption.monospacedDigit())
                    .foregroundStyle(model.isOverLimit ? Palette.danger : Palette.textSecondary)
            }
        }
    }

    /// The two ways to bring text in. Both take the same shape and size, the control radius at the large control size:
    /// `HVPasteButton` sets them on the system's Paste control, so the File button is set to match.
    @ViewBuilder
    private var pasteAndFile: some View {
        HVPasteButton { strings in
            guard let text = strings.first else { return }
            model.typed(text)
        }
        Button {
            fileError = nil
            importing = true
        } label: {
            Label("File", systemImage: "doc")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: HV.Radius.control))
        .controlSize(.large)
    }

    private var titleField: some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            HVSectionHeader(title: "Title")
            TextField("Title", text: Bindable(model).title, prompt: artifactPrompt("Untitled"))
                .accessibilityIdentifier("artifact.new.title")
                .focused($titleFocused)
                .submitLabel(.done)
                .hvFieldChrome(isFocused: titleFocused)
        }
    }

    private var visibilityField: some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            HVSectionHeader(title: "Who can open it")
            HVChoicePicker(title: "Who can open it", selection: Bindable(model).visibility) {
                Text("Only me").tag(ArtifactVisibility.private)
                Text("Anyone with the link").tag(ArtifactVisibility.public)
            }
            Text(model.visibility == .private
                ? "Only you and people you add can open the link. You can change this any time."
                : "Anyone who has the link can open it. You can change this any time.")
                .font(.hvFootnote)
                .foregroundStyle(Palette.textSecondary)
        }
    }

    private var moreOptions: some View {
        DisclosureGroup(isExpanded: $showMore) {
            VStack(alignment: .leading, spacing: HV.Space.m) {
                HVLabeledField(title: "Source prompt", footnote: "The prompt that made this. It is saved into the page so any AI can pick up where you left off.") {
                    VStack(alignment: .trailing, spacing: HV.Space.xxs) {
                        TextField("Source prompt", text: Bindable(model).sourcePrompt, prompt: artifactPrompt("Optional"), axis: .vertical)
                            .lineLimit(3...8)
                        Text("\(model.promptCount.formatted()) of \(model.promptLimit.formatted())")
                            .font(.hvCaption.monospacedDigit())
                            .foregroundStyle(model.promptIsOverLimit ? Palette.danger : Palette.textSecondary)
                    }
                }
                HVLabeledField(title: "Tags", footnote: "Separated by commas.") {
                    TextField("Tags", text: Bindable(model).tags, prompt: artifactPrompt("Optional"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                HVLabeledField(title: "Connect to", footnote: "Titles or addresses of related pages, separated by commas. Similar pages are connected for you too.") {
                    TextField("Connect to", text: Bindable(model).connectTo, prompt: artifactPrompt("Optional"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Toggle("Keep versions, so it can be rewritten", isOn: Bindable(model).living)
                Toggle("Make it installable", isOn: Bindable(model).installable)
                Toggle("Plain HTML, skip React detection", isOn: Bindable(model).forceHtml)
            }
            .padding(.top, HV.Space.s)
        } label: {
            Text("More options").font(.hvHeadline)
        }
    }

    // MARK: Files

    private func read(_ picked: Result<[URL], Error>) {
        switch picked {
        case .failure(let error):
            fileError = ArtifactErrors.message(error)
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                fileError = "That file couldn't be read."
                return
            }
            fileError = model.load(data: data, filename: url.lastPathComponent)
        }
    }
}

/// "Kept. Here's the link." with the link, and what to do with it.
struct ArtifactKeptView: View {
    let result: ArtifactSaveResult
    var onOpen: () -> Void
    var onAnother: (() -> Void)?

    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            VStack(spacing: HV.Space.l) {
                Image(systemName: result.duplicate ? "checkmark.circle" : "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Palette.success)
                    .padding(.top, HV.Space.xl)
                    .accessibilityHidden(true)
                VStack(spacing: HV.Space.xs) {
                    // The bar has no title in this state, so this is the page's heading for VoiceOver.
                    Text(result.duplicate ? LibraryCopy.alreadyKept : LibraryCopy.kept)
                        .font(.hvTitle)
                        .accessibilityAddTraits(.isHeader)
                    if !result.message.isEmpty {
                        Text(extraLines)
                            .font(.hvCallout)
                            .foregroundStyle(Palette.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                }
                Text(result.url)
                    .font(.hvMono)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
                    .hvCard()

                VStack(spacing: HV.Space.xs) {
                    Button("Open", action: onOpen).buttonStyle(.hvPrimary)
                    if let url = URL(string: result.url) {
                        ShareLink(item: url) { Label("Share link", systemImage: "square.and.arrow.up") }
                            .buttonStyle(.hvSecondary)
                    }
                    Button {
                        ArtifactPasteboard.copy(result.url)
                        Haptics.tap()
                        app.toasts.show(LibraryCopy.linkCopied, style: .info)
                    } label: {
                        Label(LibraryCopy.copyLink, systemImage: HVSymbol.copy)
                    }
                    .buttonStyle(.hvGhost)
                    if let onAnother {
                        Button("Keep another", action: onAnother).buttonStyle(.hvGhost)
                    }
                }
                .frame(maxWidth: 360)
            }
            .padding(HV.Space.l)
            .hvReadableWidth()
        }
    }

    /// The server's message without the line the heading already says.
    private var extraLines: String {
        var text = result.message
        for lead in [LibraryCopy.kept, LibraryCopy.alreadyKept] where text.hasPrefix(lead) {
            text = String(text.dropFirst(lead.count))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
