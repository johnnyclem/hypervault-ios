import HyperVaultKit
import SwiftUI
import UniformTypeIdentifiers

/// Import, a pane of the You tab: two rows, as the web has them (components/account-sections.tsx). The first goes on to
/// the history importer; the second keeps one file, a `.jsx` or `.tsx` component as a running page and a PDF as it is
/// (components/jsx-import-button.tsx).
struct ImportPane: View {
    @Environment(AppModel.self) private var app
    @Environment(AppEnvironment.self) private var env

    @State private var importing = false
    @State private var isBusy = false
    @State private var problem: String?

    /// A PDF, and the component files: the picker offers them, and the name decides what each one is.
    private static var fileTypes: [UTType] {
        var types: [UTType] = [.pdf, .sourceCode]
        for ext in ["jsx", "tsx"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }

    var body: some View {
        List {
            Section {
                Text(AccountPane.import.descriptionLine)
                    .font(.hvCallout)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: HV.Space.xs, leading: HV.Space.m, bottom: HV.Space.xs, trailing: HV.Space.m))
            }

            Section {
                importRow(
                    "history", title: "Your AI history",
                    detail: "Bring your ChatGPT, Claude, Gemini, and Grok history home, then continue any thread in Chat with your vault as memory.",
                    action: "Import your AI history"
                ) {
                    app.router.push(.importHistory, on: .you)
                }
                // The web's line adds "(up to 10 MB)" after PDFs, which is older than its code: the server takes 50 MB on Pro and
                // 1 MB on Free, and the app's own check says 50 MB (`FileImport`). The size is left out rather than be wrong.
                importRow(
                    "file", title: "A file",
                    detail: "A .jsx file is auto-wrapped into a running, installable page. PDFs are saved as-is.",
                    action: isBusy ? "Importing" : "Import .jsx / .pdf file", isDisabled: isBusy
                ) {
                    problem = nil
                    importing = true
                }
                if let problem {
                    KeysInlineMessage(text: problem)
                        .accessibilityIdentifier("import.problem")
                }
            }
            .hvListRow()
        }
        .scrollContentBackground(.hidden)
        .hvScreenBackground()
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.fileTypes, allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await keep(url) }
        }
    }

    private func importRow(
        _ id: String, title: String, detail: String, action: String, isDisabled: Bool = false, perform: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            Text(title).font(.hvBody)
            Text(detail)
                .font(.hvFootnote)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: perform) { Text(action) }
                .buttonStyle(.hvSecondary)
                .disabled(isDisabled)
                .accessibilityIdentifier("import.\(id)")
                .padding(.top, HV.Space.xxs)
        }
        .padding(.vertical, HV.Space.xs)
    }

    /// Keeps the file the person picked, and opens what it became.
    private func keep(_ url: URL) async {
        let name = url.lastPathComponent
        guard let kind = FileImport.kind(ofFilename: name) else {
            problem = FileImport.pickAFile
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if kind == .pdf, let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, FileImport.isOverTheCeiling(bytes: size) {
            problem = FileImport.pdfTooBig
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            problem = "That file couldn't be read."
            return
        }
        isBusy = true
        problem = nil
        defer { isBusy = false }
        do {
            let result: ArtifactSaveResult
            switch kind {
            case .pdf:
                result = try await ArtifactUploader(client: env.client).upload(data: data, filename: name)
            case .component:
                guard let text = String(data: data, encoding: .utf8) else {
                    problem = "That file isn't text, so it can't be kept as a page."
                    return
                }
                result = try await env.client.send(.saveArtifact(FileImport.saveRequest(componentText: text, filename: name)))
            }
            app.toasts.show(result.duplicate ? LibraryCopy.alreadyKept : LibraryCopy.kept, style: .success)
            app.router.push(.artifact(slug: result.slug), on: .you)
        } catch {
            problem = keysMessage(for: error)
        }
    }
}
