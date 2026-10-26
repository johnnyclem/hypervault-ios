import HyperVaultKit
import SwiftUI

/// Where Account & keys can push to.
private enum KeysDestination: Hashable {
    case key(AgentKey)
    case pairing
    case webhooks
}

/// Account & keys: connect an agent, see each agent's key and whether its setup finished, change what a
/// key may do, revoke it. Webhooks sit under Advanced. The native version of the web's "Agent keys" pane
/// (components/api-keys-card.tsx).
struct AgentsAndKeysView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(AppModel.self) private var app

    @State private var model: AgentsAndKeysModel?
    @State private var showConnect = false
    @State private var keyToRevoke: AgentKey?

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                HVLoadingState().frame(maxHeight: .infinity)
            }
        }
        .hvScreenBackground()
        .navigationTitle("Account & keys")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(for: KeysDestination.self) { destination in
            switch destination {
            case .key(let key):
                if let model { KeyDetailView(keyID: key.id, model: model) }
            case .pairing: PairApprovalScreen(code: nil)
            case .webhooks: WebhooksView()
            }
        }
        .task {
            if model == nil { model = AgentsAndKeysModel(client: env.client, rest: env.keysRest, cache: env.cache, userID: env.user.id) }
            await model?.load()
        }
        .sheet(isPresented: $showConnect, onDismiss: { Task { await model?.load() } }) {
            ConnectAgentSheet()
        }
        .onReceive(NotificationCenter.default.publisher(for: .hvKeysChanged)) { _ in
            Task { await model?.load() }
        }
    }

    @ViewBuilder
    private func content(_ model: AgentsAndKeysModel) -> some View {
        switch model.phase {
        case .loading:
            HVListSkeleton(rows: 4).frame(maxHeight: .infinity, alignment: .top)
        case .failed(let message):
            HVErrorState(message: message) { Task { await model.load() } }
                .frame(maxHeight: .infinity)
        case .loaded:
            list(model)
        }
    }

    private func list(_ model: AgentsAndKeysModel) -> some View {
        List {
            if model.isStale {
                Section { HVStaleBanner().listRowBackground(Color.clear).listRowSeparator(.hidden) }
            }

            Section {
                connectCard(model)
                    .listRowInsets(EdgeInsets(top: HV.Space.s, leading: HV.Space.m, bottom: HV.Space.xl, trailing: HV.Space.m))
                    .listRowBackground(Color.clear)
            }

            Section(header: HVSectionHeader(title: "Keys", detail: model.keys.isEmpty ? nil : "\(model.keys.count)")) {
                if model.keys.isEmpty {
                    emptyKeys
                } else {
                    ForEach(model.keys) { key in
                        NavigationLink(value: KeysDestination.key(key)) {
                            KeyRow(key: key, status: model.status(of: key))
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { keyToRevoke = key } label: { Label("Revoke", systemImage: "xmark.circle") }
                        }
                    }
                }
            }

            if model.pairingOn == true {
                Section(
                    header: HVSectionHeader(title: "Waiting for an AI tool?"),
                    footer: Text("If an AI tool showed you a code, enter it here to give it a key of its own.").font(.hvCaption)
                ) {
                    NavigationLink(value: KeysDestination.pairing) {
                        HVRow(symbol: "link.badge.plus", tint: Palette.violet, title: "Approve an AI tool", subtitle: "Enter the code it is showing")
                    }
                }
            }

            Section(header: HVSectionHeader(title: "Advanced")) {
                NavigationLink(value: KeysDestination.webhooks) {
                    HVRow(symbol: "dot.radiowaves.left.and.right", tint: Palette.coral, title: "Webhooks", subtitle: "Be told when a truth is challenged")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .refreshable { await model.load() }
        .confirmationDialog(
            revokeTitle,
            isPresented: Binding(get: { keyToRevoke != nil }, set: { if !$0 { keyToRevoke = nil } }),
            titleVisibility: .visible,
            presenting: keyToRevoke
        ) { key in
            Button("Revoke key", role: .destructive) { revoke(key, in: model) }
            Button("Keep it", role: .cancel) {}
        } message: { _ in
            Text("The agent using it stops working at once. This cannot be undone.")
        }
    }

    private var revokeTitle: String {
        if let key = keyToRevoke { return "Revoke \(key.displayName ?? key.prefixLabel)?" }
        return "Revoke this key?"
    }

    private func connectCard(_ model: AgentsAndKeysModel) -> some View {
        VStack(alignment: .leading, spacing: HV.Space.m) {
            Text(introLine(model))
                .font(.hvCallout)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                showConnect = true
            } label: {
                Label("Connect an agent", systemImage: "plus")
            }
            .buttonStyle(.hvPrimary)
        }
        .padding(.vertical, HV.Space.xs)
    }

    private func introLine(_ model: AgentsAndKeysModel) -> String {
        let connected = model.snapshot.connectedCount
        if connected > 0 { return "\(connected) agent\(connected == 1 ? "" : "s") connected." }
        return "One key per agent. A key is shown once, and comes with a setup challenge the agent completes to prove the link works."
    }

    private var emptyKeys: some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            Text("No keys yet").font(.hvHeadline)
            Text("Connect an agent and its key shows up here, with whether it has finished setting up.")
                .font(.hvFootnote)
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(.vertical, HV.Space.xs)
        .accessibilityElement(children: .combine)
    }

    private func revoke(_ key: AgentKey, in model: AgentsAndKeysModel) {
        Task {
            do {
                try await model.revoke(key)
                Haptics.success()
                app.toasts.success("Key revoked.")
            } catch {
                app.toasts.show(error: error)
            }
        }
    }
}

// MARK: Rows

/// One key: its name or prefix, when it was last used, and whether its agent has finished setting up.
struct KeyRow: View {
    let key: AgentKey
    let status: AgentSetupStatus?

    var body: some View {
        HStack(alignment: .top, spacing: HV.Space.s + 2) {
            HVIconBadge(symbol: key.isPaired ? "link" : "key.horizontal", tint: status?.complete == true ? Palette.mint : Palette.amber)
            VStack(alignment: .leading, spacing: 2) {
                Text(key.displayName ?? "Untitled key")
                    .font(.hvBody)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                Text("\(key.prefixLabel) · \(AccountWords.lastUsedLine(key.lastUsedAt))")
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(2)
                if let status {
                    HVTag(text: status.complete ? "Agent connected" : "Setup pending", tint: status.complete ? Palette.success : Palette.warning)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
enum KeysPreviewData {
    static let keysJSON = """
    [{"id":"k1","key_prefix":"hv_Zk3pQ9vL","name":"Claude Code","created_at":"2026-10-20T10:00:00Z","last_used_at":"2026-10-25T08:00:00Z","scopes":["mail:read","mail:send"],"mail_claim_id":null,"mail_pin_cleared":false},
     {"id":"k2","key_prefix":"hv_Aa1Bb2Cc","name":"Paired: Cursor on Sam's Mac","created_at":"2026-10-18T10:00:00Z","last_used_at":null,"scopes":["mail:read"],"mail_claim_id":null,"mail_pin_cleared":false},
     {"id":"k3","key_prefix":"hv_Dd3Ee4Ff","name":"default","created_at":"2026-10-10T10:00:00Z","last_used_at":"2026-10-12T10:00:00Z","scopes":["mail:read"],"mail_claim_id":null,"mail_pin_cleared":false}]
    """

    static let pagesJSON = """
    [{"id":"a1","slug":"agent-setup-1","tags":["agent-setup-challenge","hv_Zk3pQ9vL"],"content":"<body data-setup-status=\\"complete\\">"},
     {"id":"a2","slug":"agent-setup-2","tags":["agent-setup-challenge","hv_Aa1Bb2Cc"],"content":"<body data-setup-status=\\"incomplete\\">"}]
    """

    static let versionsJSON = """
    [{"artifact_id":"a1","author_kind":"agent","author_key_id":"k1","created_at":"2026-10-25T09:00:00Z"}]
    """

    static let routes: [MockRoute] = [
        .json(.get, "/rest/v1/api_keys", keysJSON),
        .json(.get, "/rest/v1/artifacts", pagesJSON),
        .json(.get, "/rest/v1/artifact_versions", versionsJSON),
        .failure(.post, "/api/pair/poll", status: 400, message: "device_code is required: the one POST /api/pair/start gave you."),
    ]
}

#Preview("Account & keys") {
    PreviewHost(routes: KeysPreviewData.routes) { AgentsAndKeysView() }
}

#Preview("Account & keys, no keys") {
    PreviewHost(routes: [.json(.get, "/rest/v1/api_keys", "[]")]) { AgentsAndKeysView() }
}
#endif
