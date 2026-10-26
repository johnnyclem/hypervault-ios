import HyperVaultKit
import SwiftUI

/// Choosing the name truth is signed under. It is set once, and it is the name
/// on everything the person asserts or decides.
struct TruthHandleForm: View {
    let onSave: (String) async throws -> Void

    @State private var handle = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: HV.Space.s) {
            Text("Choose the name you sign truth under")
                .font(.hvHeadline)
            Text("It goes on everything you assert or decide, and it is set once. Pick the name you want to answer to.")
                .font(.hvFootnote)
                .foregroundStyle(Palette.textSecondary)
            HVLabeledField(title: "Your name or handle") {
                TextField("Your name or handle", text: $handle, prompt: truthPrompt("sam"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit { save() }
            }
            if let errorMessage {
                Text(errorMessage).font(.hvFootnote).foregroundStyle(Palette.danger)
            }
            Button {
                save()
            } label: {
                if isSaving { ProgressView().tint(.white) } else { Text("Save and continue") }
            }
            .buttonStyle(.hvPrimary)
            .disabled(handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
        }
        .hvCard()
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        Task {
            defer { isSaving = false }
            do {
                try await onSave(handle)
                Haptics.success()
            } catch {
                errorMessage = TruthModel.sentence(error)
                Haptics.failure()
            }
        }
    }
}

/// Decide a card: what the action does, what it needs from you, and one button.
struct TruthDecisionSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let model: TruthReviewModel
    let action: TruthAction
    let item: TruthDocketItem
    let onDone: () -> Void

    @State private var draft = TruthDecisionDraft()
    @State private var errorMessage: String?
    @State private var replies: [TruthAgentReply]?
    @State private var deferralChoice = DeferralChoice.week

    enum DeferralChoice: String, CaseIterable, Identifiable {
        case tomorrow = "Tomorrow", week = "Next week", month = "Next month", pick = "Pick a date"
        var id: String { rawValue }
    }

    private var state: TruthActionState { model.state(of: action, for: item) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HV.Space.m) {
                    Text(state.explanation)
                        .font(.hvCallout)
                        .foregroundStyle(Palette.textSecondary)
                    TruthClaimText(text: item.text.isEmpty ? "(no text)" : item.text, lines: 3)
                        .padding(HV.Space.s)
                        .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous))
                    if model.handle == nil {
                        TruthHandleForm { try await model.saveHandle($0) }
                    } else {
                        inputs
                        if let errorMessage {
                            Text(errorMessage).font(.hvFootnote).foregroundStyle(Palette.danger)
                        }
                        if let replies { answer(replies) }
                        confirmButton
                    }
                }
                .padding(HV.Space.m)
                .hvReadableWidth()
            }
            .scrollDismissesKeyboard(.interactively)
            .hvScreenBackground()
            .navigationTitle(state.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(replies == nil ? "Cancel" : "Done") { dismiss() }
                }
            }
            .onAppear {
                if draft.appealTarget == nil { draft.appealTarget = item.contestedBy.first?.id }
                if draft.roomID == nil { draft.roomID = model.rooms.first?.id }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(model.isWorking)
    }

    // MARK: Inputs

    @ViewBuilder
    private var inputs: some View {
        if item.kind == .appeal, action != .deferral { appealPicker }
        switch action {
        case .approve:
            if !item.kind.isProposal { noteField(footnote: "It goes on the record.") }
        case .refute:
            if !item.kind.isProposal {
                TruthEvidenceEditor(rows: $draft.evidence, label: "Evidence that refutes it (at least one)")
                noteField()
            }
        case .deferral:
            deferralPicker
        case .strike:
            HVLabeledField(title: "Your opinion", footnote: "It goes in the ruling, answerable to you.") {
                TextField("Your opinion", text: $draft.opinion, prompt: truthPrompt("Why this is struck"), axis: .vertical)
                    .lineLimit(3...8)
            }
        case .ask:
            askInputs
        }
    }

    private func noteField(footnote: String? = nil) -> some View {
        HVLabeledField(title: "Note (optional)", footnote: footnote) {
            TextField("Note", text: $draft.note, prompt: truthPrompt("Anything worth keeping with the decision"), axis: .vertical)
                .lineLimit(2...6)
        }
    }

    private var appealPicker: some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            Text(item.contestedBy.count > 1 ? "Which appeal?" : "The appeal").font(.hvFootnote.weight(.semibold)).foregroundStyle(Palette.textSecondary)
            ForEach(item.contestedBy) { uv in
                Button {
                    Haptics.select()
                    draft.appealTarget = uv.id
                } label: {
                    HStack(alignment: .top, spacing: HV.Space.s) {
                        Image(systemName: draft.appealTarget == uv.id ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(draft.appealTarget == uv.id ? Color.accentColor : Palette.textTertiary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: uv.assertion).font(.hvCallout).foregroundStyle(Palette.textPrimary)
                            Text(uv.author).font(.hvCaption).foregroundStyle(Palette.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(draft.appealTarget == uv.id ? .isSelected : [])
            }
        }
    }

    private var deferralPicker: some View {
        VStack(alignment: .leading, spacing: HV.Space.s) {
            Text("Bring it back").font(.hvFootnote.weight(.semibold)).foregroundStyle(Palette.textSecondary)
            Picker("Bring it back", selection: $deferralChoice) {
                ForEach(DeferralChoice.allCases) { choice in Text(choice.rawValue).tag(choice) }
            }
            .pickerStyle(.menu)
            if deferralChoice == .pick {
                DatePicker("Until", selection: Binding(get: { draft.until ?? Self.date(daysFromNow: 7) }, set: { draft.until = $0 }), in: Date()..., displayedComponents: .date)
            }
        }
    }

    private static func date(daysFromNow days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date().addingTimeInterval(Double(days) * 86_400)
    }

    @ViewBuilder
    private var askInputs: some View {
        if model.rooms.isEmpty {
            Text("You have no agent rooms yet. Make one in Chat and the question goes there. The record on the card is what stands meanwhile.")
                .font(.hvFootnote)
                .foregroundStyle(Palette.textSecondary)
        } else {
            VStack(alignment: .leading, spacing: HV.Space.xs) {
                Picker("Room", selection: Binding(get: { draft.roomID ?? "" }, set: { draft.roomID = $0 })) {
                    ForEach(model.rooms) { room in Text(room.title).tag(room.id) }
                }
                .pickerStyle(.menu)
                HVLabeledField(title: "Your question (optional)", footnote: "The claim, basis and verify-by go with it.") {
                    TextField("Your question", text: $draft.question, prompt: truthPrompt("What would settle this?"), axis: .vertical)
                        .lineLimit(2...6)
                }
            }
        }
    }

    private func answer(_ replies: [TruthAgentReply]) -> some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            Text("The room answered").font(.hvFootnote.weight(.semibold)).foregroundStyle(Palette.violet)
            if replies.isEmpty {
                Text("No reply yet. The record on the card is what stands.").font(.hvFootnote).foregroundStyle(Palette.textSecondary)
            }
            ForEach(replies) { reply in
                VStack(alignment: .leading, spacing: 1) {
                    Text(reply.handle ?? "agent").font(.hvCaption.weight(.semibold))
                    Text(verbatim: reply.content).font(.hvFootnote)
                }
            }
        }
        .padding(HV.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.violet.opacity(0.10), in: RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous))
    }

    // MARK: Confirm

    @ViewBuilder
    private var confirmButton: some View {
        if replies == nil {
            let blocked = !state.isAvailable || model.isWorking || TruthDocketRules.problem(with: action, for: item, draft: draft) != nil
            if action == .strike || action == .refute {
                Button(action: confirm) { confirmLabel }
                    .buttonStyle(.hvSecondary)
                    .disabled(blocked)
            } else {
                Button(action: confirm) { confirmLabel }
                    .buttonStyle(.hvPrimary)
                    .disabled(blocked)
            }
        }
    }

    @ViewBuilder
    private var confirmLabel: some View {
        if model.isWorking { ProgressView() } else { Text(confirmTitle) }
    }

    private var confirmTitle: String {
        switch action {
        case .ask: return "Ask"
        default: return state.label
        }
    }

    private func confirm() {
        errorMessage = nil
        applyDeferral()
        Task {
            do {
                if action == .ask {
                    replies = try await model.ask(item: item, draft: draft)
                    Haptics.success()
                    onDone()
                    return
                }
                let outcome = try await model.decide(action, item: item, draft: draft)
                haptic(for: outcome)
                app.toasts.show(outcome.sentence, style: .success)
                onDone()
                dismiss()
            } catch {
                errorMessage = TruthModel.sentence(error)
                Haptics.failure()
            }
        }
    }

    private func applyDeferral() {
        guard action == .deferral else { return }
        switch deferralChoice {
        case .tomorrow: draft.until = Self.date(daysFromNow: 1)
        case .week: draft.until = nil
        case .month: draft.until = Self.date(daysFromNow: 30)
        case .pick: break
        }
    }

    private func haptic(for outcome: TruthDecisionOutcome) {
        switch action {
        case .strike: Haptics.warning()
        case .refute: Haptics.press()
        default: Haptics.success()
        }
    }
}
