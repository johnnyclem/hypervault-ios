import HyperVaultKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Bring truth in: a stenographer stream into a mirror ledger (all or nothing,
/// one transaction), or a page ledger, whose every line becomes a proposal on
/// the docket. Nothing from a page is truth until you approve it.
struct TruthImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    let ledger: TruthLedger
    let onStream: (String) async throws -> TruthImportResult
    let onPage: (_ slug: String?, _ jsonl: String?) async throws -> TruthPageImportResult

    @State private var text = ""
    @State private var fileName: String?
    @State private var preview = TruthImportPreview()
    @State private var showPicker = false
    @State private var isWorking = false
    @State private var message: String?
    @State private var lineErrors: [TruthImportLineError] = []
    @State private var pageName = ""
    @State private var pageMessage: String?
    @State private var isFilingPage = false

    var body: some View {
        NavigationStack {
            Form {
                streamSection
                pageSection
            }
            .scrollContentBackground(.hidden)
            .hvScreenBackground()
            .navigationTitle("Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.fontWeight(.semibold) }
            }
            .fileImporter(isPresented: $showPicker, allowedContentTypes: Self.types, allowsMultipleSelection: false) { result in
                load(result)
            }
        }
        .presentationDetents([.large])
    }

    private static var types: [UTType] {
        [UTType.plainText, UTType.json, UTType(filenameExtension: "jsonl"), UTType(filenameExtension: "ndjson")].compactMap { $0 }
    }

    // MARK: A stenographer stream

    private var streamSection: some View {
        Section {
            if !ledger.isHosted {
                Button { showPicker = true } label: { Label("Choose a .jsonl file", systemImage: "doc") }
                Button { paste() } label: { Label("Paste from the clipboard", systemImage: "doc.on.clipboard") }
                if preview.lineCount > 0 || fileName != nil {
                    VStack(alignment: .leading, spacing: 2) {
                        if let fileName { Text(fileName).font(.hvFootnote.weight(.semibold)) }
                        Text(preview.summary).font(.hvFootnote).foregroundStyle(Palette.textSecondary)
                        if let problem = preview.firstProblem {
                            Text("Line \(problem.line): \(problem.error)").font(.hvFootnote).foregroundStyle(Palette.danger)
                        } else if preview.isTooLarge {
                            Text("That file is larger than 2 MB.").font(.hvFootnote).foregroundStyle(Palette.danger)
                        }
                    }
                }
                Button {
                    runStream()
                } label: {
                    HStack {
                        Text("Import into \(ledger.name)").fontWeight(.semibold)
                        Spacer()
                        if isWorking { ProgressView() }
                    }
                }
                .disabled(!preview.canSend || isWorking)
                if let message { Text(message).font(.hvFootnote).foregroundStyle(Palette.textSecondary) }
                ForEach(lineErrors) { error in
                    Text("Line \(error.line): \(error.error)").font(.hvFootnote).foregroundStyle(Palette.danger)
                }
            } else {
                Text("A hosted ledger is written here, not imported. Choose a mirror ledger to import a stenographer stream.")
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.textSecondary)
            }
        } header: {
            Text("A stenographer stream")
        } footer: {
            Text("The export_wiki_entries file. One transaction: if any line is refused, nothing is written and every bad line is named. Importing again is safe.")
        }
    }

    // MARK: A page ledger

    private var pageSection: some View {
        Section {
            TextField("The page's name or link", text: $pageName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button {
                filePage()
            } label: {
                HStack {
                    Text("File its lines for review").fontWeight(.semibold)
                    Spacer()
                    if isFilingPage { ProgressView() }
                }
            }
            .disabled(Self.slug(from: pageName).isEmpty || isFilingPage)
            if let pageMessage { Text(pageMessage).font(.hvFootnote).foregroundStyle(Palette.textSecondary) }
        } header: {
            Text("A page ledger")
        } footer: {
            Text("For ledgers typed into a page of yours. Every line becomes a proposal on the docket, in \(ledger.name). Nothing is truth until you approve it there, one card at a time. The page is left as it is.")
        }
    }

    /// `https://hypervault.store/a/my-page` or `my-page`: the slug either way.
    static func slug(from input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: "/a/") {
            let rest = trimmed[range.upperBound...]
            return String(rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
        }
        return trimmed
    }

    // MARK: Actions

    private func load(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            message = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                fileName = url.lastPathComponent
                set(text: String(decoding: data, as: UTF8.self))
            } catch {
                message = "Could not read that file."
            }
        }
    }

    private func paste() {
        guard let pasted = UIPasteboard.general.string, !pasted.isEmpty else {
            message = "The clipboard has no text."
            return
        }
        fileName = nil
        set(text: pasted)
    }

    private func set(text newText: String) {
        text = newText
        preview = TruthImportPreview.parse(newText)
        message = nil
        lineErrors = []
    }

    private func runStream() {
        guard preview.canSend, !isWorking else { return }
        isWorking = true
        message = nil
        lineErrors = []
        Task {
            defer { isWorking = false }
            do {
                let result = try await onStream(text)
                message = result.sentence
                Haptics.success()
                if result.errors.isEmpty { text = ""; preview = TruthImportPreview(); fileName = nil }
            } catch {
                lineErrors = TruthImportFailure.lineErrors(in: error)
                message = TruthModel.sentence(error)
                Haptics.failure()
            }
        }
    }

    private func filePage() {
        let slug = Self.slug(from: pageName)
        guard !slug.isEmpty, !isFilingPage else { return }
        isFilingPage = true
        pageMessage = nil
        Task {
            defer { isFilingPage = false }
            do {
                let result = try await onPage(slug, nil)
                pageMessage = result.sentence
                if result.filed > 0 { Haptics.success() }
            } catch {
                pageMessage = TruthModel.sentence(error)
                Haptics.failure()
            }
        }
    }
}
