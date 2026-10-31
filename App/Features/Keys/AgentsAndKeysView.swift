import HyperVaultKit
import SwiftUI

/// Where Agent keys can push to.
private enum KeysDestination: Hashable {
    case key(AgentKey)
    case webhooks
}

/// Agent keys: connect an agent, see each key with what the server states about it (its name, prefix and last
/// use), change what a key may do, revoke it. Webhooks sit under Advanced. The native version of the web's
/// "Agent keys" pane (components/api-keys-card.tsx). It says nothing about whether an agent is connected: no route
/// reports the server's check of the setup challenge.
struct AgentsAndKeysView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(AppModel.self) private var app
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
        .navigationDestination(for: KeysDestination.self) { destination in
            switch destination {
            case .key(let key):
                if let model { KeyDetailView(keyID: key.id, model: model) }
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
                connectCard
                    // No bottom inset: the list's own gap between sections sits under this one, as it does under the others.
                    .listRowInsets(EdgeInsets(top: HV.Space.s, leading: HV.Space.m, bottom: 0, trailing: HV.Space.m))
                    .listRowBackground(Color.clear)
            }

            Section(header: HVSectionHeader(title: "Keys", detail: model.keys.isEmpty ? nil : "\(model.keys.count)")) {
                if model.keys.isEmpty {
                    emptyKeys
                } else {
                    ForEach(model.keys) { key in
                        NavigationLink(value: KeysDestination.key(key)) {
                            KeyRow(key: key, isRevoking: model.revoking.contains(key.id))
                        }
                        .accessibilityIdentifier("keys.row.\(key.id)")
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { keyToRevoke = key } label: { Label("Revoke", systemImage: "xmark.circle") }
                                .disabled(model.revoking.contains(key.id))
                        }
                    }
                }
            }
            .hvListRow()

            Section(header: HVSectionHeader(title: "Advanced")) {
                NavigationLink(value: KeysDestination.webhooks) {
                    HVRow(symbol: "dot.radiowaves.left.and.right", title: "Webhooks", subtitle: "Be told when a truth is challenged")
                }
            }
            .hvListRow()
        }
        .scrollContentBackground(.hidden)
        .refreshable { await model.load() }
        .confirmationDialog(
            KeysCopy.reallyRevoke,
            isPresented: Binding(get: { keyToRevoke != nil }, set: { if !$0 { keyToRevoke = nil } }),
            titleVisibility: .visible,
            presenting: keyToRevoke
        ) { key in
            Button(KeysCopy.revoke, role: .destructive) { revoke(key, in: model) }
            Button("Keep it", role: .cancel) {}
        } message: { key in
            Text(KeysCopy.revokeMessage(for: key))
        }
    }

    private var connectCard: some View {
        VStack(alignment: .leading, spacing: HV.Space.m) {
            Text(KeysCopy.paneDescription)
                .font(.hvCallout)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                showConnect = true
            } label: {
                // At accessibility sizes the plus would sit beside a wrapped label and pull it off centre.
                if dynamicTypeSize.isAccessibilitySize {
                    Text("Connect an agent")
                } else {
                    Label("Connect an agent", systemImage: HVSymbol.add)
                }
            }
            .buttonStyle(.hvPrimary)
            .multilineTextAlignment(.center)
            .accessibilityIdentifier("keys.connect")
        }
    }

    private var emptyKeys: some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            Text("No keys yet").font(.hvHeadline)
            Text("Connect an agent and its key shows up here.")
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

/// One key: its name, its prefix and when it was last used. Nothing about whether its agent is connected.
struct KeyRow: View {
    let key: AgentKey
    var isRevoking = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var tile: CGFloat = 36

    private var isLarge: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        KeysRowLayout(alignment: .top) {
            // The neutral tile the Vault draws, at the side HVRow's tile has: it follows the type, to 44 at most.
            HVTile(symbol: key.isPaired ? "link" : HVSymbol.key, size: HV.glyphBox(scaled: tile, base: HV.rowTile))
        } words: {
            VStack(alignment: .leading, spacing: HV.Space.xxs) {
                Text(key.displayName ?? "Untitled key")
                    .font(.hvBody)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(isLarge ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                detail
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// The prefix and the last use each get their own line at every size, so the rows of one list are the same height
    /// and none is cut short ("Last used 19...") or wraps ("Last used 14 / days ago").
    private var detail: some View {
        let usage = isRevoking ? KeysCopy.revoking : AccountWords.lastUsedLine(key.lastUsedAt)
        return VStack(alignment: .leading, spacing: HV.Space.xxs) {
            Text(key.prefixLabel)
            Text(usage)
        }
        .font(.hvFootnote)
        .foregroundStyle(Palette.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

#if DEBUG
enum KeysPreviewData {
    static let keysJSON = """
    [{"id":"k1","key_prefix":"hv_Zk3pQ9vL","name":"Claude Code","created_at":"2026-10-20T10:00:00Z","last_used_at":"2026-10-25T08:00:00Z","scopes":["mail:read","mail:send"],"mail_claim_id":null,"mail_pin_cleared":false},
     {"id":"k2","key_prefix":"hv_Aa1Bb2Cc","name":"Paired: Cursor on Sam's Mac","created_at":"2026-10-18T10:00:00Z","last_used_at":null,"scopes":["mail:read"],"mail_claim_id":null,"mail_pin_cleared":false},
     {"id":"k3","key_prefix":"hv_Dd3Ee4Ff","name":"default","created_at":"2026-10-10T10:00:00Z","last_used_at":"2026-10-12T10:00:00Z","scopes":["mail:read"],"mail_claim_id":null,"mail_pin_cleared":false}]
    """

    /// One key whose pinned address was released: it reads and cannot send until an address is picked again.
    static let releasedKeysJSON = """
    [{"id":"k1","key_prefix":"hv_Zk3pQ9vL","name":"Claude Code","created_at":"2026-10-20T10:00:00Z","last_used_at":"2026-10-25T08:00:00Z","scopes":["mail:read","mail:send"],"mail_claim_id":null,"mail_pin_cleared":true}]
    """

    static let pagesJSON = """
    [{"slug":"agent-setup-1","tags":["agent-setup-challenge","hv_Zk3pQ9vL"]},
     {"slug":"agent-setup-2","tags":["agent-setup-challenge","hv_Aa1Bb2Cc"]}]
    """

    static let routes: [MockRoute] = [
        .json(.get, "/rest/v1/api_keys", keysJSON),
        .json(.get, "/rest/v1/artifacts", pagesJSON),
    ]
}

#Preview("Agent keys") {
    PreviewHost(routes: KeysPreviewData.routes) { AgentsAndKeysView() }
}

#Preview("Agent keys, no keys") {
    PreviewHost(routes: [.json(.get, "/rest/v1/api_keys", "[]")]) { AgentsAndKeysView() }
}
#endif
