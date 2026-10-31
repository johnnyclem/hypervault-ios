import HyperVaultKit
import SwiftUI

/// Edit a memory. The change is saved as a commit on the branch, with the
/// message written here (or the server's "edit: Title").
struct MemoryEditSheet: View {
    let model: MemoryDetailModel
    let memory: MemoryFull

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var content: String
    @State private var tags: [String]
    @State private var note = ""
    @State private var problem: String?
    @State private var isSaving = false
    @State private var confirmDiscard = false
    @FocusState private var focus: Field?

    private enum Field { case title, content, note }

    init(model: MemoryDetailModel, memory: MemoryFull) {
        self.model = model
        self.memory = memory
        _title = State(initialValue: memory.title)
        _content = State(initialValue: memory.content)
        _tags = State(initialValue: memory.tags)
    }

    private var request: MemoryEditRequest? {
        MemoryEditRequest.make(original: memory, title: title, content: content, tags: tags, message: note, branch: model.branch)
    }

    private var hasChanges: Bool { request != nil }
    private var limit: Int { model.env.limits.memoryBytes }
    private var isOverLimit: Bool { content.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count > limit }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HV.Space.m) {
                    HVLabeledField(title: "Title") {
                        TextField("A short name", text: $title, prompt: Text.hvPrompt("A short name"))
                            .font(.hvHeadline)
                            .focused($focus, equals: .title)
                            .accessibilityIdentifier("memory.edit.title")
                    }

                    HVLabeledField(title: "Text") {
                        TextEditor(text: $content)
                            .focused($focus, equals: .content)
                            .accessibilityIdentifier("memory.edit.content")
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 220)
                    }

                    if isOverLimit {
                        Text("That chunk is over the \(MemoryLimits.label(forBytes: limit)) memory limit. Split it into smaller memories.")
                            .font(.hvFootnote)
                            .foregroundStyle(Palette.danger)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        MemoryFieldLabel(title: "Tags")
                        MemoryTagEditor(tags: $tags)
                    }

                    HVLabeledField(title: "Commit message", footnote: "Saved as a commit on \(model.branch). You can always go back from History.") {
                        TextField("edit: \(memory.title)", text: $note, prompt: Text.hvPrompt("edit: \(memory.title)"))
                            .focused($focus, equals: .note)
                            .accessibilityIdentifier("memory.edit.note")
                    }

                    if let problem {
                        Text(problem)
                            .font(.hvFootnote)
                            .foregroundStyle(Palette.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(HV.Space.m)
                .hvReadableWidth()
            }
            .scrollDismissesKeyboard(.interactively)
            .hvScreenBackground()
            .navigationTitle("Edit memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if hasChanges { confirmDiscard = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { save() }
                            .fontWeight(.semibold)
                            .disabled(!hasChanges || isOverLimit)
                    }
                }
            }
            .confirmationDialog("Discard your changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
        }
        .interactiveDismissDisabled(hasChanges)
        .presentationDetents([.large])
    }

    private func save() {
        guard let request, !isSaving else { return }
        focus = nil
        problem = nil
        isSaving = true
        Task {
            do {
                let message = try await model.save(request)
                isSaving = false
                Haptics.success()
                app.toasts.success(message)
                dismiss()
            } catch {
                isSaving = false
                if !MemoryErrors.isCancelled(error) {
                    problem = MemoryErrors.message(error)
                    Haptics.failure()
                }
            }
        }
    }
}

/// Tags as removable chips with a field to add more.
struct MemoryTagEditor: View {
    @Binding var tags: [String]
    @State private var entry = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            if !tags.isEmpty {
                MemoryFlowLayout(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        Button {
                            Haptics.select()
                            tags.removeAll { $0 == tag }
                        } label: {
                            HStack(spacing: 4) {
                                Text(tag)
                                Image(systemName: HVSymbol.close)
                                    .font(.system(.caption2, weight: .semibold))
                                    .imageScale(.small)
                            }
                            .font(.system(.footnote, weight: .medium))
                            .foregroundStyle(Palette.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Palette.surfaceRaised, in: Capsule())
                            .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove tag \(tag)")
                    }
                }
            }
            TextField(tags.count >= MemoryTags.maxCount ? "That is the most tags a memory can have" : "Add a tag", text: $entry, prompt: Text.hvPrompt(tags.count >= MemoryTags.maxCount ? "That is the most tags a memory can have" : "Add a tag"))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($focused)
                .disabled(tags.count >= MemoryTags.maxCount)
                .onSubmit(commit)
                .onChange(of: entry) { _, text in
                    if text.hasSuffix(",") { commit() }
                }
                .hvFieldChrome(isFocused: focused)
        }
    }

    private func commit() {
        let added = MemoryTags.parse(entry)
        entry = ""
        guard !added.isEmpty else { return }
        tags = MemoryTags.clean(tags + added)
    }
}
