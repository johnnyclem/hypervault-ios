import HyperVaultKit
import SwiftUI

/// The one setting mail has, and the export. "Agents can see my replies"
/// decides what the person writes next; it never rewrites a note that exists.
struct MailSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    let address: String?
    let agentsSeeReplies: Bool
    let onToggle: (Bool) async throws -> Void
    let onExport: () async throws -> URL

    @State private var seesReplies: Bool
    @State private var isBusy = false
    @State private var isExporting = false
    @State private var errorMessage: String?
    @State private var shared: MailSharedFile?

    init(
        address: String?,
        agentsSeeReplies: Bool,
        onToggle: @escaping (Bool) async throws -> Void,
        onExport: @escaping () async throws -> URL
    ) {
        self.address = address
        self.agentsSeeReplies = agentsSeeReplies
        self.onToggle = onToggle
        self.onExport = onExport
        _seesReplies = State(initialValue: agentsSeeReplies)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Agents can see my replies", isOn: Binding(get: { seesReplies }, set: { change(to: $0) }))
                        .disabled(isBusy)
                } footer: {
                    Text("When this is off, what you write is marked Not shared with agents. Mail already written does not change.")
                }

                Section {
                    Button {
                        export()
                    } label: {
                        HStack {
                            Label("Export this mailbox", systemImage: "square.and.arrow.up")
                            Spacer()
                            if isExporting { ProgressView() }
                        }
                    }
                    .disabled(isExporting)
                } footer: {
                    Text("Releasing an address deletes its mailbox, so keep a copy first. You get every message, as a file.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).font(.hvFootnote).foregroundStyle(Palette.danger)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .hvScreenBackground()
            .navigationTitle(address ?? "Mailbox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
            .sheet(item: $shared) { file in
                MailActivitySheet(items: [file.url])
            }
        }
    }

    private func change(to value: Bool) {
        let previous = seesReplies
        seesReplies = value
        isBusy = true
        errorMessage = nil
        Task {
            defer { isBusy = false }
            do {
                try await onToggle(value)
                Haptics.select()
            } catch {
                seesReplies = previous
                errorMessage = MailModel.sentence(error)
                Haptics.failure()
            }
        }
    }

    private func export() {
        isExporting = true
        errorMessage = nil
        Task {
            defer { isExporting = false }
            do {
                shared = MailSharedFile(url: try await onExport())
            } catch {
                errorMessage = MailModel.sentence(error)
                Haptics.failure()
            }
        }
    }
}
