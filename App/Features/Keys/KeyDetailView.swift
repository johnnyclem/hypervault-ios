import HyperVaultKit
import SwiftUI

/// One key: what it is called, when it was made and last used, what it may do with mail and the address it does
/// it as, the setup steps again, its setup challenge page, and revoking it. Every line is something the server
/// states about the key; whether its agent is connected is not among them. The key itself is gone (it was shown
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
                HVEmptyState(symbol: HVSymbol.key, title: "This key is gone", message: "It was revoked.", actionTitle: "Back") { dismiss() }
                    .frame(maxHeight: .infinity)
            }
        }
        .hvScreenBackground()
        .navigationTitle("Key")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func details(_ key: AgentKey) -> some View {
        let challengeSlug = model.challengeSlug(of: key)
        let isRevoking = model.revoking.contains(key.id)
        return List {
            Section {
                header(key)
                    .listRowInsets(EdgeInsets(top: HV.Space.s, leading: HV.Space.m, bottom: HV.Space.s, trailing: HV.Space.m))
            }
            .hvListRow()

            Section {
                LabeledContent("Key", value: key.prefixLabel)
                LabeledContent("Made", value: key.createdAt?.keysDay ?? "Unknown")
                LabeledContent("Last used", value: key.lastUsedAt.map { AccountWords.agoLine(seconds: Date().timeIntervalSince($0)) } ?? "Never")
            } footer: {
                Text("The key itself was shown once, when it was made. It cannot be shown again.")
            }
            .hvListRow()

            if key.hasMailControls {
                mailSection(key)
            }

            Section {
                Button { showSteps = true } label: {
                    HVRow(symbol: "list.bullet.rectangle", tint: Palette.blue, title: "Setup steps", subtitle: "Steps for an agent, with this key's place marked") { KeysChevron() }
                }
                if let challengeSlug {
                    Button {
                        app.router.open(.route(.artifact(slug: challengeSlug)))
                    } label: {
                        HVRow(symbol: "doc.text", tint: Palette.violet, title: "Its challenge page", subtitle: "The page the agent has to rewrite") { KeysChevron() }
                    }
                }
            }
            .hvListRow()

            Section {
                Button(role: .destructive) { confirmRevoke = true } label: {
                    Label(isRevoking ? KeysCopy.revoking : KeysCopy.revoke, systemImage: "xmark.circle").foregroundStyle(Palette.danger)
                }
                .disabled(model.changing.contains(key.id))
            } footer: {
                Text("The agent using it stops working at once. The row is kept for audit.")
            }
            .hvListRow()
        }
        .scrollContentBackground(.hidden)
        .task { await model.loadMailboxes() }
        .confirmationDialog(KeysCopy.reallyRevoke, isPresented: $confirmRevoke, titleVisibility: .visible) {
            Button(KeysCopy.revoke, role: .destructive) { revoke(key) }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text(KeysCopy.revokeMessage(for: key))
        }
        .sheet(isPresented: $showSteps) {
            ConnectAgentSheet(existingKey: key, challengeSlug: challengeSlug)
        }
    }

    /// "Can send mail", the address the key reads and sends as, and the web's line when that address was released.
    private func mailSection(_ key: AgentKey) -> some View {
        let pin = AgentKeyMailPin(key: key, mailboxes: model.mailboxes)
        return Section(footer: Text("Reading its mailbox is always allowed. Sending is your choice.")) {
            Toggle(AccountWords.mailSendLabel, isOn: Binding(
                get: { key.canSendMail },
                set: { setMail(key, $0) }
            ))
            .disabled(model.changing.contains(key.id))
            if pin.isOffered {
                addressPicker(key, pin)
            }
            if key.mailPinCleared {
                Label(AccountWords.mailPinClearedLine, systemImage: "exclamationmark.triangle.fill")
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.warning)
            }
        }
        .hvListRow()
    }

    /// "Default address" and each claimed address, with the one the key reads and sends as chosen. A key whose address
    /// was released has none chosen: "Pick an address" stands in, and Default address is a change like the rest.
    private func addressPicker(_ key: AgentKey, _ pin: AgentKeyMailPin) -> some View {
        Picker(AccountWords.mailPinLabel, selection: Binding(
            get: { pin.selection },
            set: { chooseAddress($0, for: key) }
        )) {
            if pin.selection == .choosing {
                Text(AccountWords.mailPinChoose).disabled(true).tag(AgentKeyMailPin.Selection.choosing)
            }
            Text(AccountWords.mailPinDefault).tag(AgentKeyMailPin.Selection.defaultAddress)
            ForEach(pin.choices) { choice in
                Text(choice.address).tag(AgentKeyMailPin.Selection.claim(choice.claimId))
            }
            if let other = pin.unlistedClaimId {
                Text(AccountWords.mailPinOther).tag(AgentKeyMailPin.Selection.claim(other))
            }
        }
        .pickerStyle(.menu)
        .disabled(model.changing.contains(key.id))
    }

    private func header(_ key: AgentKey) -> some View {
        // Beside the name while it fits. At accessibility sizes the badge would leave the name a narrow column, so it goes
        // above it.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: HV.Space.s))
            : AnyLayout(HStackLayout(alignment: .center, spacing: HV.Space.m))
        return layout {
            HVIconBadge(symbol: key.isPaired ? "link" : HVSymbol.key, tint: Palette.amber, size: 48)
            VStack(alignment: .leading, spacing: HV.Space.xxs) {
                Text(key.displayName ?? "Untitled key").font(.hvTitle3)
                if key.isPaired {
                    Text("Made by approving an AI tool").font(.hvFootnote).foregroundStyle(Palette.textSecondary)
                }
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

    private func chooseAddress(_ selection: AgentKeyMailPin.Selection, for key: AgentKey) {
        switch selection {
        case .choosing: return
        case .defaultAddress: setMailAddress(key, claimId: nil)
        case .claim(let claimId): setMailAddress(key, claimId: claimId)
        }
    }

    private func setMailAddress(_ key: AgentKey, claimId: String?) {
        Task {
            do {
                try await model.setMailAddress(key, claimId: claimId)
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
    PreviewHost(routes: KeysPreviewData.routes + MailPreviewData.routes) { KeyDetailPreview() }
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
