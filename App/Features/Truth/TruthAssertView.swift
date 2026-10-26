import HyperVaultKit
import SwiftUI

/// Assert into a hosted ledger as yourself: a TB you stand behind, or a UV you
/// believe and want checked. A TB is signed by you and answerable to you.
struct TruthAssertView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    let ledger: TruthLedger
    let onDone: () -> Void

    @State private var model: TruthAssertModel
    @State private var draft: TruthAssertDraft
    @State private var errorMessage: String?
    @FocusState private var focus: Field?

    private enum Field: Hashable { case text, basis, verify }

    /// `draft` is what the form starts with: empty for a person, filled for a preview.
    init(client: HVClient, ledger: TruthLedger, draft: TruthAssertDraft = TruthAssertDraft(type: .uv), onDone: @escaping () -> Void) {
        self.ledger = ledger
        self.onDone = onDone
        _model = State(initialValue: TruthAssertModel(client: client))
        _draft = State(initialValue: draft)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HV.Space.m) {
                    if !ledger.isHosted {
                        Label("\(ledger.name) mirrors stenographer, so nothing can be asserted into it here. Pick a hosted ledger.", systemImage: "lock")
                            .font(.hvCallout)
                            .foregroundStyle(Palette.textSecondary)
                    } else if model.needsHandle {
                        TruthHandleForm { try await model.saveHandle($0) }
                    } else {
                        form
                    }
                }
                .padding(HV.Space.m)
                .hvReadableWidth()
            }
            .scrollDismissesKeyboard(.interactively)
            .hvScreenBackground()
            .navigationTitle("Assert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(model.isSending) }
            }
            .task { await model.loadHandle() }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(model.isSending)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: HV.Space.m) {
            Picker("Kind", selection: $draft.type) {
                Text("UV: I believe this").tag(TruthEntryType.uv)
                Text("TB: I stand behind this").tag(TruthEntryType.tb)
            }
            .pickerStyle(.segmented)
            Text(draft.type == .tb
                ? "A TB is signed by you and answerable to you. It needs evidence, and it outranks recalled memory."
                : "A UV is a belief to be checked. It goes on the docket, and is never shown as proven.")
                .font(.hvFootnote)
                .foregroundStyle(Palette.textSecondary)

            HVLabeledField(
                title: draft.type == .tb ? "The claim" : "What you believe",
                footnote: draft.type == .tb ? "What is settled, and what it replaces." : "In full sentences."
            ) {
                TextField(
                    draft.type == .tb ? "The claim" : "What you believe",
                    text: $draft.text,
                    prompt: truthPrompt(draft.type == .tb ? "Retries are capped at 5; the old cap of 3 is dead." : "Retries are idempotent across regions."),
                    axis: .vertical
                )
                .lineLimit(3...8)
                .font(.system(.body, design: .serif))
                .focused($focus, equals: .text)
            }

            if draft.type == .uv {
                HVLabeledField(title: "Why you believe it") {
                    TextField("Why you believe it", text: $draft.basis, prompt: truthPrompt("The design doc says so."), axis: .vertical)
                        .lineLimit(2...5)
                        .focused($focus, equals: .basis)
                }
                HVLabeledField(title: "Where to check it", footnote: "A file, a symbol or a place to look.") {
                    TextField("Where to check it", text: $draft.verifyBy, prompt: truthPrompt("src/retry.ts"))
                        .focused($focus, equals: .verify)
                }
            } else {
                TruthEvidenceEditor(rows: $draft.evidence, label: "Evidence (at least one)")
                retiring
            }

            if let errorMessage {
                Text(errorMessage).font(.hvFootnote).foregroundStyle(Palette.danger)
            }
            Button {
                send()
            } label: {
                if model.isSending { ProgressView().tint(.white) } else { Text("Assert \(draft.type.tag)") }
            }
            .buttonStyle(.hvPrimary)
            .disabled(!draft.canSend || model.isSending)
            // Said while the button is off, so it is plain what turns it on, not only once something is typed.
            if let hint = draft.problem {
                Text(hint)
                    .font(.hvCaption)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private var retiring: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: HV.Space.xs) {
                Text("Later saves that state the dead value get a warning.")
                    .font(.hvCaption)
                    .foregroundStyle(Palette.textSecondary)
                HVLabeledField(title: "The dead value") {
                    TextField("The dead value", text: $draft.deadValue, prompt: truthPrompt("30"))
                }
                HVLabeledField(title: "Subject (optional)") {
                    TextField("Subject", text: $draft.subject, prompt: truthPrompt("LOG_BUDGET"))
                }
                HVLabeledField(title: "What replaced it (optional)") {
                    TextField("What replaced it", text: $draft.currentValue, prompt: truthPrompt("100"))
                }
            }
            .padding(.top, HV.Space.xs)
        } label: {
            Text("Retires a value (optional)").font(.hvFootnote.weight(.semibold)).foregroundStyle(Palette.textSecondary)
        }
    }

    private func send() {
        errorMessage = nil
        Task {
            do {
                try await model.send(draft, ledger: ledger.slug)
                Haptics.success()
                app.toasts.success(draft.type == .tb ? "Asserted: a TB signed by you, answerable to you." : "Asserted a UV. It is on your docket.")
                onDone()
                dismiss()
            } catch {
                errorMessage = TruthModel.sentence(error)
                Haptics.failure()
            }
        }
    }
}

@MainActor
@Observable
final class TruthAssertModel {
    private(set) var isSending = false
    private(set) var needsHandle = false
    @ObservationIgnored private let client: HVClient

    init(client: HVClient) {
        self.client = client
    }

    func loadHandle() async {
        if let signers = try? await client.send(.truthSigners) { needsHandle = signers.handle == nil }
    }

    func saveHandle(_ text: String) async throws {
        if let problem = TruthHandle.problem(text) { throw HVError.invalidRequest(problem) }
        _ = try await client.send(.setTruthHandle(text))
        needsHandle = false
    }

    func send(_ draft: TruthAssertDraft, ledger: String) async throws {
        if let problem = draft.problem { throw HVError.invalidRequest(problem) }
        isSending = true
        defer { isSending = false }
        do {
            _ = try await client.send(.assertTruth(draft, ledger: ledger))
        } catch {
            if (error as? HVError)?.isTruthHandleRequired == true { needsHandle = true }
            throw error
        }
    }
}

/// A new ledger: a hosted one is written here; a mirror is filled by importing a stenographer stream.
struct TruthNewLedgerView: View {
    @Environment(\.dismiss) private var dismiss
    var hostedOnly = false
    let onCreate: (_ slug: String, _ name: String, _ kind: TruthLedgerKind) async throws -> Void

    @State private var name = ""
    @State private var slug = ""
    @State private var slugEdited = false
    @State private var kind: TruthLedgerKind = .hosted
    @State private var isCreating = false
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HV.Space.m) {
                    if !hostedOnly {
                        Picker("Kind", selection: $kind) {
                            Text("Hosted").tag(TruthLedgerKind.hosted)
                            Text("Mirror").tag(TruthLedgerKind.mirror)
                        }
                        .pickerStyle(.segmented)
                    }
                    Text(kind == .hosted
                        ? "A hosted ledger is written here: you and your agents assert into it, and the review decides it."
                        : "A mirror holds a stream imported from stenographer. Decide its items there.")
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.textSecondary)
                    HVLabeledField(title: "Name") {
                        TextField("Name", text: $name, prompt: truthPrompt("Team notes"))
                            .focused($focused)
                            .onChange(of: name) { _, new in if !slugEdited { slug = TruthLedgerSlug.suggest(from: new) } }
                    }
                    // The footnote says why the button below is off until there is a short name.
                    HVLabeledField(
                        title: "Short name",
                        footnote: slug.isEmpty ? "Give it a name to start." : "What the ledger goes by. Lowercase letters, digits, - and _."
                    ) {
                        TextField("Short name", text: $slug, prompt: truthPrompt("team-notes"))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.hvMono)
                            .onChange(of: slug) { _, new in if new != TruthLedgerSlug.suggest(from: name) { slugEdited = true } }
                    }
                    if let errorMessage {
                        Text(errorMessage).font(.hvFootnote).foregroundStyle(Palette.danger)
                    }
                    Button {
                        create()
                    } label: {
                        if isCreating { ProgressView().tint(.white) } else { Text("Create ledger") }
                    }
                    .buttonStyle(.hvPrimary)
                    .disabled(slug.isEmpty || isCreating)
                }
                .padding(HV.Space.m)
                .hvReadableWidth()
            }
            .scrollDismissesKeyboard(.interactively)
            .hvScreenBackground()
            .navigationTitle("New ledger")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isCreating) }
            }
            .onAppear { focused = true }
        }
        .interactiveDismissDisabled(isCreating)
    }

    private func create() {
        if let problem = TruthLedgerSlug.problem(slug) {
            errorMessage = problem
            return
        }
        isCreating = true
        errorMessage = nil
        Task {
            defer { isCreating = false }
            do {
                try await onCreate(slug, name, hostedOnly ? .hosted : kind)
                dismiss()
            } catch {
                errorMessage = TruthModel.sentence(error)
                Haptics.failure()
            }
        }
    }
}
