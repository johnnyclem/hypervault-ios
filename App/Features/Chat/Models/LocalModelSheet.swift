import HyperVaultKit
import SwiftUI

/// Add or change a model on your own network. The address is checked by asking
/// the model what it can run, straight from this iPhone.
struct ChatLocalModelSheet: View {
    let existing: ChatLocalModel?
    var onSave: (ChatLocalModel) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ChatLocalModel
    @State private var tokensText: String
    @State private var found: [String] = []
    @State private var isChecking = false
    @State private var checkResult: String?
    @State private var checkFailed = false
    @State private var check: Task<Void, Never>?

    init(existing: ChatLocalModel?, onSave: @escaping (ChatLocalModel) -> Void) {
        self.existing = existing
        self.onSave = onSave
        let start = existing ?? ChatLocalModel(baseURL: "", model: "")
        _draft = State(initialValue: start)
        _tokensText = State(initialValue: String(start.contextTokens))
    }

    private var tokens: Int { Int(tokensText.trimmingCharacters(in: .whitespaces)) ?? 0 }

    private var candidate: ChatLocalModel {
        var copy = draft
        copy.contextTokens = tokens
        return copy
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: HV.Space.m) {
                        HVLabeledField(title: "Name (optional)") {
                            TextField("Name", text: $draft.name, prompt: chatPrompt("Studio Llama"))
                        }
                        HVLabeledField(title: "Address") {
                            TextField("Address", text: $draft.baseURL, prompt: chatPrompt("192.168.1.20:11434"))
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        HVLabeledField(title: "Model") {
                            TextField("Model", text: $draft.model, prompt: chatPrompt("llama3.3"))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    }
                    .padding(.vertical, HV.Space.xs)
                } footer: {
                    ChatFooter("Messages go from this iPhone straight to that address. iOS asks once to let HyperVault reach devices on your network.")
                }
                .hvListRow()

                Section {
                    LabeledContent("Context size") {
                        TextField("Context size", text: $tokensText, prompt: chatPrompt("4096"))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 100)
                    }
                    .frame(minHeight: 44)
                } footer: {
                    ChatFooter("How many tokens the model reads at once. Ollama starts small, so HyperVault trims what it sends to fit.")
                }
                .hvListRow()

                Section {
                    Button(action: runCheck) {
                        HStack {
                            if isChecking { ProgressView() }
                            Text(isChecking ? "Asking the model" : "Check the connection")
                        }
                        .frame(minHeight: 44, alignment: .leading)
                    }
                    .disabled(isChecking || ChatLocalModel(baseURL: draft.baseURL, model: "x").problem != nil)
                    if let checkResult {
                        Text(checkResult)
                            .font(.hvFootnote)
                            .foregroundStyle(checkFailed ? Palette.danger : Palette.textSecondary)
                    }
                    ForEach(found, id: \.self) { name in
                        Button {
                            draft.model = name
                        } label: {
                            HStack {
                                Text(name).font(.hvMono).foregroundStyle(Palette.textPrimary)
                                Spacer()
                                if draft.model == name {
                                    HVIcon("checkmark").foregroundStyle(Color.accentColor)
                                }
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(draft.model == name ? .isSelected : [])
                    }
                }
                .hvListRow()

                Section {
                    VStack(alignment: .leading, spacing: HV.Space.s) {
                        Button(existing == nil ? "Add" : "Save") {
                            var saved = candidate
                            saved.baseURL = ChatLocalModel.normalizedBase(saved.baseURL)
                            saved.model = saved.model.trimmingCharacters(in: .whitespacesAndNewlines)
                            onSave(saved)
                            Haptics.success()
                            dismiss()
                        }
                        .buttonStyle(.hvPrimary)
                        .disabled(candidate.problem != nil)
                        if let problem = candidate.problem {
                            // Indented to the same line as the notes under the cards above.
                            Text(problem)
                                .font(.hvFootnote)
                                .foregroundStyle(Palette.textSecondary)
                                .padding(.horizontal, HV.Space.m)
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
            .scrollContentBackground(.hidden)
            .hvScreenBackground()
            .navigationTitle(existing == nil ? "On your network" : "Edit model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { check?.cancel(); dismiss() } }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func runCheck() {
        isChecking = true
        checkResult = nil
        checkFailed = false
        found = []
        let target = ChatLocalModel(baseURL: draft.baseURL, model: draft.model.isEmpty ? "x" : draft.model)
        check = Task {
            defer { isChecking = false }
            do {
                let names = try await ChatURLSessionLines.modelNames(for: target)
                found = names
                if names.isEmpty {
                    checkResult = "Reached it, but it didn't list any models. You can still type the model's name."
                } else {
                    checkResult = "Reached it. It can run \(names.count) model\(names.count == 1 ? "" : "s"). Tap one to use it."
                    if draft.model.trimmingCharacters(in: .whitespaces).isEmpty, let first = names.first { draft.model = first }
                }
            } catch {
                if Task.isCancelled { return }
                checkFailed = true
                checkResult = error.localizedDescription
            }
        }
    }
}

#Preview("On your network") {
    PreviewHost(embedInNavigation: false) {
        ChatLocalModelSheet(existing: nil) { _ in }
    }
}
