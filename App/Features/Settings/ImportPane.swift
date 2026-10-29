import HyperVaultKit
import SwiftUI
import UniformTypeIdentifiers

/// Import, a pane of the You tab: two rows, as the web has them (components/account-sections.tsx). The first goes on to
/// the history importer; the second keeps one file, and sends it where it belongs by its type, as the web's side menu Import
/// does (components/import-anything-button.tsx): a component or an HTML file as a running page, a PDF or an image as it is,
/// a text, Markdown or Word file as a memory (`ImportFileModel`).
struct ImportPane: View {
    @Environment(AppModel.self) private var app
    @Environment(AppEnvironment.self) private var env

    @State private var importing = false
    @State private var model: ImportFileModel?
    @State private var problem: String?

    private var isBusy: Bool { model?.isBusy == true }

    /// Everything the one-stop import keeps: the picker offers these, and the name decides what each one is.
    private static var fileTypes: [UTType] {
        FileImport.extensions.compactMap { UTType(filenameExtension: $0) }
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
                // The web's account line adds "(up to 10 MB)" after PDFs, which is older than its code: the server takes 50 MB on Pro
                // and 1 MB on Free, and the app's own check says 50 MB (`FileImport`). The size is left out rather than be wrong.
                importRow(
                    "file", title: "A file",
                    detail: "Pick a file and it goes where it belongs. A .jsx or .html file becomes a running, installable page; a PDF or an image is saved as it is; a .txt, .md or .docx file becomes a memory.",
                    action: isBusy ? "Importing" : "Import a file", isDisabled: isBusy
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
        .onAppear { if model == nil { model = ImportFileModel(client: env.client) } }
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
        let model = model ?? ImportFileModel(client: env.client)
        self.model = model
        problem = nil
        switch await model.keep(url, branch: MemoryBranchStore.current(for: env.user.id)) {
        case .page(let slug, let duplicate):
            app.toasts.show(duplicate ? LibraryCopy.alreadyKept : LibraryCopy.kept, style: .success)
            app.router.push(.artifact(slug: slug), on: .you)
        case .memory(let id, let message):
            app.toasts.success(message)
            if !id.isEmpty { app.router.push(.memory(id: id), on: .you) }
        case .refused(let reason):
            problem = reason
            Haptics.failure()
        }
    }
}
