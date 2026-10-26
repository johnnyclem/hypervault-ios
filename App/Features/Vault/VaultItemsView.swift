import HyperVaultKit
import SwiftUI

private enum VaultDestination: Hashable {
    case secret(String)
}

/// Logins, cards & keys: what is saved once so the agents you allow can use it. The list shows each entry's
/// name and a masked line (a username, `Visa •••• 4242`); a value is encrypted when it is saved and is never
/// shown again, here or anywhere. The native version of the web's Vault pane.
struct VaultItemsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(AppModel.self) private var app

    @State private var model: VaultItemsModel?
    @State private var adding = false
    @State private var unlocking = false

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                HVLoadingState().frame(maxHeight: .infinity)
            }
        }
        .hvScreenBackground()
        .navigationTitle("Logins, cards & keys")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(for: VaultDestination.self) { destination in
            switch destination {
            case .secret(let name):
                if let model { VaultItemDetailView(name: name, model: model) }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { startAdding() } label: { Image(systemName: "plus") }
                    .disabled(model == nil)
                    .accessibilityLabel("Add to your vault")
            }
        }
        .task {
            if model == nil { model = VaultItemsModel(client: env.client, rest: env.keysRest, userID: env.user.id) }
            await model?.load()
        }
        .sheet(isPresented: $adding) {
            if let model { VaultAddItemSheet(model: model) }
        }
    }

    /// Adding is the one place a secret is typed, so Settings' lock (when it is on) is asked first.
    private func startAdding() {
        guard !unlocking else { return }
        unlocking = true
        Task {
            defer { unlocking = false }
            if await KeysBiometricGate.confirm(reason: "Add to your vault") { adding = true }
        }
    }

    @ViewBuilder
    private func content(_ model: VaultItemsModel) -> some View {
        switch model.phase {
        case .loading:
            HVListSkeleton(rows: 6).frame(maxHeight: .infinity, alignment: .top)
        case .failed(let message):
            HVErrorState(message: message) { Task { await model.load() } }.frame(maxHeight: .infinity)
        case .loaded:
            list(model)
        }
    }

    private func list(_ model: VaultItemsModel) -> some View {
        @Bindable var model = model
        return List {
            Section {
                VStack(alignment: .leading, spacing: HV.Space.s) {
                    Text("Save a login, card or contact once. Agents you give a key, like Claude Code, Codex, Cursor, Gemini CLI or your own script, can use it, and only the ones you allow.")
                        .font(.hvCallout)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .firstTextBaseline, spacing: HV.Space.xs) {
                        Image(systemName: "lock.fill").accessibilityHidden(true)
                        Text("Values are encrypted when you save them and never shown again.")
                    }
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.textTertiary)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: HV.Space.xs, leading: HV.Space.m, bottom: HV.Space.xs, trailing: HV.Space.m))

                filters(model)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            .listRowSeparator(.hidden)

            let shown = model.visible
            if shown.isEmpty {
                Section {
                    empty(model)
                        .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(shown) { secret in
                        NavigationLink(value: VaultDestination.secret(secret.name)) {
                            VaultRow(secret: secret)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search")
        .refreshable { await model.load() }
    }

    private func filters(_ model: VaultItemsModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: HV.Space.xs) {
                chip("All", category: nil, model: model)
                ForEach(VaultCategory.allCases) { category in
                    chip(category.label, category: category, model: model)
                }
            }
            .padding(.horizontal, HV.Space.m)
            .padding(.vertical, HV.Space.xxs)
        }
        .accessibilityElement(children: .contain)
    }

    private func chip(_ title: String, category: VaultCategory?, model: VaultItemsModel) -> some View {
        let selected = model.filter == category
        let count = model.count(in: category)
        return Button {
            Haptics.select()
            model.filter = category
        } label: {
            HVChip(title: count > 0 ? "\(title) \(count)" : title, isSelected: selected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func empty(_ model: VaultItemsModel) -> some View {
        if !model.query.isEmpty {
            HVEmptyState(symbol: "magnifyingglass", title: "Nothing called that", message: "Try part of a name, a username or a card's last four digits.")
        } else if let filter = model.filter {
            HVEmptyState(symbol: "lock.rectangle.stack", title: "Nothing here yet", message: filter.emptyLine, actionTitle: "Add", action: startAdding)
        } else {
            HVEmptyState(
                symbol: "lock.rectangle.stack", title: "Nothing saved yet",
                message: "Add a login, a card or contact info, then choose which agents may use it.",
                actionTitle: "Add something", action: startAdding
            )
        }
    }
}

// MARK: Row

struct VaultRow: View {
    let secret: VaultSecret

    var body: some View {
        HStack(spacing: HV.Space.s + 2) {
            VaultTile(secret: secret)
            VStack(alignment: .leading, spacing: 2) {
                Text(secret.name)
                    .font(.hvBody)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                Text(secret.subtitle)
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: HV.Space.xs)
            Text(secret.lastAccessedAt == nil ? AccountWords.neverUsed : AccountWords.agoLine(seconds: Date().timeIntervalSince(secret.lastAccessedAt ?? Date())))
                .font(.hvCaption)
                .foregroundStyle(Palette.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(secret.name), \(secret.subtitle). \(AccountWords.lastUsedLine(secret.lastAccessedAt))")
    }
}

#if DEBUG
enum VaultPreviewData {
    static let secretsJSON = """
    {"secrets":[
      {"id":"s1","name":"github.com","kind":"login","description":"Work account","created_at":"2026-10-20T10:00:00Z","updated_at":"2026-10-20T10:00:00Z","last_accessed_at":"2026-10-25T09:30:00Z","hint":"jane@appleseed.dev"},
      {"id":"s2","name":"visa-4242","kind":"card","description":null,"created_at":"2026-10-21T10:00:00Z","updated_at":"2026-10-21T10:00:00Z","last_accessed_at":null,"hint":"Visa •••• 4242"},
      {"id":"s3","name":"amex-0005","kind":"card","description":null,"created_at":"2026-10-21T11:00:00Z","updated_at":"2026-10-21T11:00:00Z","last_accessed_at":"2026-10-22T09:30:00Z","hint":"Amex •••• 0005"},
      {"id":"s4","name":"contact","kind":"contact","description":null,"created_at":"2026-10-22T10:00:00Z","updated_at":"2026-10-22T10:00:00Z","last_accessed_at":null,"hint":"jane@appleseed.dev"},
      {"id":"s5","name":"home","kind":"contact","description":null,"created_at":"2026-10-22T10:00:00Z","updated_at":"2026-10-22T10:00:00Z","last_accessed_at":null,"hint":"Address"},
      {"id":"s6","name":"stripe-restricted-key","kind":"opaque","description":"Read-only","created_at":"2026-10-23T10:00:00Z","updated_at":"2026-10-23T10:00:00Z","last_accessed_at":"2026-10-24T09:30:00Z","hint":null}
    ]}
    """

    static let routes: [MockRoute] = [
        .json(.get, "/api/secrets", secretsJSON),
        .json(.get, "/rest/v1/api_keys", KeysPreviewData.keysJSON),
        .json(.get, "/api/secrets/github.com/grants", #"{"grants":[{"id":"g1","api_key_id":"k1","created_at":"2026-10-24T10:00:00Z"}]}"#),
    ]
}

#Preview("Vault") {
    KeysPreviewHost(routes: VaultPreviewData.routes) { VaultItemsView() }
}

#Preview("Vault, empty") {
    KeysPreviewHost(routes: [.json(.get, "/api/secrets", #"{"secrets":[]}"#)]) { VaultItemsView() }
}
#endif
