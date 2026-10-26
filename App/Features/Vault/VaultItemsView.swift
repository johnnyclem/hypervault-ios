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
        .keysLargeTitle()
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
                } footer: {
                    note
                }
            } else {
                Section {
                    ForEach(shown) { secret in
                        NavigationLink(value: VaultDestination.secret(secret.name)) {
                            VaultRow(secret: secret)
                        }
                    }
                } footer: {
                    note
                }
                .hvListRow()
            }
        }
        .scrollContentBackground(.hidden)
        .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search")
        .refreshable { await model.load() }
    }

    /// What the vault is for and that a value cannot be read back: said once, under the entries, so the first
    /// screen at any text size is the filters and what is saved.
    private var note: some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            Text("Save a login, card or contact once, and the agents you allow can use it. Agents you give a key, like Claude Code, Codex, Cursor, Gemini CLI or your own script, only ever get what you allow.")
            Label("Values are encrypted when you save them and never shown again.", systemImage: "lock.fill")
        }
        .font(.hvFootnote)
        .foregroundStyle(Palette.textSecondary)
    }

    private func filters(_ model: VaultItemsModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: HV.Space.xs) {
                chip("All", category: nil, model: model)
                ForEach(VaultCategory.allCases) { category in
                    chip(category.label, category: category, model: model)
                }
            }
            // Room at the end, so the last chip can scroll clear of the fade.
            .padding(.trailing, HV.Space.xl)
            .padding(.vertical, HV.Space.xxs)
        }
        // The row stops where the cards below it stop, so a chip that does not fit would end in a hard cut.
        // It fades out instead, which says there is more to scroll to.
        .mask(
            LinearGradient(
                stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.92), .init(color: .clear, location: 1)],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
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

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var tile: CGFloat = 36

    private var isLarge: Bool { dynamicTypeSize.isAccessibilitySize }
    private var tileSize: CGFloat { min(tile, 56) }
    private let spacing = HV.Space.s + 2

    var body: some View {
        KeysRowLayout {
            VaultTile(secret: secret, size: tileSize)
        } words: {
            VStack(alignment: .leading, spacing: 2) {
                Text(secret.name)
                    .font(.hvBody)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(isLarge ? nil : 1)
                Text(secret.subtitle)
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(isLarge ? nil : 1)
                if isLarge { lastUsed }
            }
        } trailing: {
            lastUsed
        }
        .contentShape(Rectangle())
        // Every separator starts under the text. Left to itself the system takes a login's monogram, which is
        // text, as the start of the row and draws that one line further left than the rest.
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + (isLarge ? 0 : tileSize + spacing) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(secret.name), \(secret.subtitle). \(AccountWords.lastUsedLine(secret.lastAccessedAt))")
    }

    private var lastUsed: some View {
        Text(secret.lastAccessedAt == nil ? AccountWords.neverUsed : AccountWords.agoLine(seconds: Date().timeIntervalSince(secret.lastAccessedAt ?? Date())))
            .font(.hvCaption)
            .foregroundStyle(Palette.textTertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
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
    ] + grantRoutes

    /// Which keys may read each entry: Claude Code the first, nothing else. One route a name, so no entry in the
    /// previews or the snapshots asks for a grants list the canned server does not have.
    static let grantRoutes: [MockRoute] = ["github.com", "visa-4242", "amex-0005", "contact", "home", "stripe-restricted-key"].map { name in
        MockRoute.json(.get, "/api/secrets/\(name)/grants", #"{"grants":[{"id":"g1","api_key_id":"k1","created_at":"2026-10-24T10:00:00Z"}]}"#)
    }
}

#Preview("Vault") {
    PreviewHost(routes: VaultPreviewData.routes) { VaultItemsView() }
}

#Preview("Vault, empty") {
    PreviewHost(routes: [.json(.get, "/api/secrets", #"{"secrets":[]}"#)]) { VaultItemsView() }
}
#endif
