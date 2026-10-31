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
                    HVLabeledField(title: "Subject (optional)") {
                        TextField("What it is about", text: $subject, prompt: Text.hvPrompt("What it is about"))
                            .accessibilityIdentifier("mail.compose.subject")
                            .focused($focus, equals: .subject)
                            .submitLabel(.next)
                            .onSubmit { focus = .body }
                    }
                    HVLabeledField(title: "Note") {
                        TextField("Write to your agents", text: $text, prompt: Text.hvPrompt("Write to your agents"), axis: .vertical)
                            .accessibilityIdentifier("mail.compose.body")
                            .lineLimit(6...20)
                            .focused($focus, equals: .body)
                    }
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

    /// Who it goes to, with the one privacy signal on its own line: three things in one row left the tag
    /// wrapping into a tall capsule, and would do worse at a larger text size.
    private var recipient: some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: HV.Space.xs) {
                    recipientName
                    recipientAddress
                }
                VStack(alignment: .leading, spacing: HV.Space.xxs) {
                    recipientName
                    recipientAddress
                }
            }
            if !agentsSeeReplies { MailNotSharedTag() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var recipientName: some View {
        Text("To: your agents")
            .font(.hvSubheadline)
            .foregroundStyle(Palette.textSecondary)
    }

    @ViewBuilder
    private var recipientAddress: some View {
        if let address {
            Text(address)
                .font(.hvMono)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
        }
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
