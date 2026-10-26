import HyperVaultKit
import SwiftUI

/// One key: what it is called, when it was made and last used, whether its agent finished setting up,
/// what it may do with mail, the setup steps again, and revoking it. The key itself is gone (it was shown
/// once); the steps carry a placeholder where it goes.
struct KeyDetailView: View {
    let keyID: String
    let model: AgentsAndKeysModel

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var confirmRevoke = false
    @State private var showSteps = false

    var body: some View {
        Group {
            if let key = model.keys.first(where: { $0.id == keyID }) {
                details(key)
            } else {
                // Revoked (here or elsewhere): there is nothing left to show.
                HVEmptyState(symbol: "key.horizontal", title: "This key is gone", message: "It was revoked.", actionTitle: "Back") { dismiss() }
                    .frame(maxHeight: .infinity)
            }
        }
        .hvScreenBackground()
        .navigationTitle("Key")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func details(_ key: AgentKey) -> some View {
        let status = model.status(of: key)
        return List {
            Section {
                header(key, status: status)
                    .listRowInsets(EdgeInsets(top: HV.Space.s, leading: HV.Space.m, bottom: HV.Space.s, trailing: HV.Space.m))
            }
            .hvListRow()

            Section {
                LabeledContent("Key", value: key.prefixLabel)
                LabeledContent("Made", value: key.createdAt?.keysDay ?? "Unknown")
                LabeledContent("Last used", value: key.lastUsedAt.map { AccountWords.agoLine(seconds: Date().timeIntervalSince($0)) } ?? "Never")
                LabeledContent("Agent") {
                    if let status {
                        Text(status.complete ? "Connected" : "Waiting for its setup challenge")
                            .foregroundStyle(status.complete ? Palette.success : Palette.warning)
                    } else {
                        Text("Not known").foregroundStyle(Palette.textSecondary)
                    }
                }
            } footer: {
                Text("The key itself was shown once, when it was made. It cannot be shown again.")
            }
            .hvListRow()

            if key.hasMailControls {
                Section(footer: Text("Reading its mailbox is always allowed. Sending is your choice.")) {
                    Toggle(AccountWords.mailSendLabel, isOn: Binding(
                        get: { key.canSendMail },
                        set: { setMail(key, $0) }
                    ))
                    .disabled(model.changing.contains(key.id))
                }
                .hvListRow()
            }

            Section {
                Button { showSteps = true } label: {
                    HVRow(symbol: "list.bullet.rectangle", tint: Palette.blue, title: "Setup steps", subtitle: "Steps for an agent, with this key's place marked") { KeysChevron() }
                }
                if let status, !status.complete {
                    Button {
                        app.router.open(.route(.artifact(slug: status.slug)))
                    } label: {
                        HVRow(symbol: "doc.text", tint: Palette.violet, title: "Its challenge page", subtitle: "The page the agent has to rewrite") { KeysChevron() }
                    }
                }
            }
            .hvListRow()

            Section {
                Button(role: .destructive) { confirmRevoke = true } label: {
                    Label("Revoke key", systemImage: "xmark.circle").foregroundStyle(Palette.danger)
                }
                .disabled(model.changing.contains(key.id))
            } footer: {
                Text("The agent using it stops working at once. The row is kept for audit.")
            }
            .hvListRow()
        }
        .scrollContentBackground(.hidden)
        .confirmationDialog("Revoke \(key.displayName ?? key.prefixLabel)?", isPresented: $confirmRevoke, titleVisibility: .visible) {
            Button("Revoke key", role: .destructive) { revoke(key) }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("The agent using it stops working at once. This cannot be undone.")
        }
        .sheet(isPresented: $showSteps) {
            ConnectAgentSheet(existingKey: key, challengeSlug: status?.slug)
        }
    }

    private func header(_ key: AgentKey, status: AgentSetupStatus?) -> some View {
        let tag = status.map { HVTag(text: $0.complete ? "Agent connected" : "Setup pending", tint: $0.complete ? Palette.success : Palette.warning) }
        // Beside the name while it fits. At accessibility sizes the badge would leave the name a narrow column, so it goes
        // above it, and the tag goes under the name, where it can have the width.
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: HV.Space.s))
            : AnyLayout(HStackLayout(alignment: .center, spacing: HV.Space.m))
        return layout {
            HVIconBadge(symbol: key.isPaired ? "link" : "key.horizontal", tint: status?.complete == true ? Palette.mint : Palette.amber, size: 48)
            VStack(alignment: .leading, spacing: HV.Space.xxs) {
                Text(key.displayName ?? "Untitled key").font(.hvTitle3)
                if key.isPaired {
                    Text("Made by approving an AI tool").font(.hvFootnote).foregroundStyle(Palette.textSecondary)
                }
                if stacked, let tag { tag }
            }
            if !stacked {
                Spacer(minLength: 0)
                if let tag { tag }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func setMail(_ key: AgentKey, _ canSend: Bool) {
        Task {
            do {
                try await model.setCanSendMail(key, canSend)
                Haptics.success()
            } catch {
                app.toasts.show(error: error)
            }
        }
    }

    private func revoke(_ key: AgentKey) {
        Task {
            do {
                try await model.revoke(key)
                Haptics.success()
                app.toasts.success("Key revoked.")
                dismiss()
            } catch {
                app.toasts.show(error: error)
            }
        }
    }
}

#if DEBUG
#Preview("Key") {
    PreviewHost(routes: KeysPreviewData.routes) { KeyDetailPreview() }
}

private struct KeyDetailPreview: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model: AgentsAndKeysModel?

    var body: some View {
        Group {
            if let model { KeyDetailView(keyID: "k1", model: model) } else { HVLoadingState() }
        }
        .task {
            let loaded = AgentsAndKeysModel(client: env.client, rest: env.keysRest, cache: env.cache, userID: env.user.id)
            await loaded.load()
            model = loaded
        }
    }
}
#endif
