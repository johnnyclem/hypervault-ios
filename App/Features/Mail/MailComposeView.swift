import HyperVaultKit
import SwiftUI

/// A new note from the person. There is no recipient to pick: in this version
/// mail goes between the person and the agents on one mailbox, so a note goes
/// to the agents' side of it.
struct MailComposeView: View {
    @Environment(\.dismiss) private var dismiss

    let address: String?
    let agentsSeeReplies: Bool
    let onSend: (_ subject: String, _ text: String) async throws -> Void

    @State private var subject = ""
    @State private var text = ""
    @State private var isSending = false
    @State private var errorMessage: String?
    @FocusState private var focus: Field?

    private enum Field: Hashable { case subject, body }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HV.Space.m) {
                    recipient
                    TextField("Subject", text: $subject)
                        .focused($focus, equals: .subject)
                        .submitLabel(.next)
                        .onSubmit { focus = .body }
                        .hvFieldChrome(isFocused: focus == .subject)
                    TextField("Note", text: $text, axis: .vertical)
                        .lineLimit(6...20)
                        .focused($focus, equals: .body)
                        .hvFieldChrome(isFocused: focus == .body)
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.hvFootnote)
                            .foregroundStyle(Palette.danger)
                            .accessibilityAddTraits(.isStaticText)
                    }
                }
                .padding(HV.Space.m)
                .hvReadableWidth()
            }
            .scrollDismissesKeyboard(.interactively)
            .hvScreenBackground()
            .navigationTitle("New note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        send()
                    } label: {
                        if isSending { ProgressView() } else { Text("Send").fontWeight(.semibold) }
                    }
                    .disabled(trimmed.isEmpty || isSending)
                }
            }
            .onAppear { focus = .body }
        }
        .interactiveDismissDisabled(isSending)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var recipient: some View {
        HStack(spacing: HV.Space.xs) {
            Text("To: your agents")
                .font(.hvSubheadline)
                .foregroundStyle(Palette.textSecondary)
            if let address {
                Text(address)
                    .font(.hvMono)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
            }
            if !agentsSeeReplies { MailNotSharedTag() }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func send() {
        guard !trimmed.isEmpty, !isSending else { return }
        isSending = true
        errorMessage = nil
        Task {
            do {
                try await onSend(subject, trimmed)
                Haptics.success()
                dismiss()
            } catch {
                errorMessage = MailModel.sentence(error)
                Haptics.failure()
                isSending = false
            }
        }
    }
}
