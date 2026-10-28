import HyperVaultKit
import SwiftUI

/// The Vault pane: what is saved once so the agents you allow can use it. The list shows each entry's name and a
/// masked line (a username, `Visa •••• 4242`); a value is encrypted when it is saved and is never shown again, here
/// or anywhere. The native version of the web's Vault pane.
struct VaultItemsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(AppModel.self) private var app

    @State private var model: VaultItemsModel?
    @State private var adding = false
    /// The entry whose page is up. The page follows the entry by its id, so a rename does not close it.
    @State private var opened: VaultSecret?
    @State private var unlocking = false

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                HVLoadingState(message: VaultCopy.loadingLine).frame(maxHeight: .infinity)
            }
        }
        .hvScreenBackground()
        .navigationTitle(AccountPane.vault.label)
        .keysLargeTitle()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { startAdding() } label: { Image(systemName: "plus") }
                    .disabled(model == nil || model?.isFull == true)
                    .accessibilityLabel(VaultScreenCopy.addTitle)
            }
        }
        .task {
            if model == nil { model = VaultItemsModel(client: env.client, rest: env.keysRest, userID: env.user.id) }
            await model?.load()
        }
        .sheet(isPresented: $adding) {
            if let model {
                VaultAddItemSheet(model: model)
                    // Large, so the keyboard does not cover the form.
                    .presentationDetents([.large])
            }
        }
        .sheet(item: $opened) { secret in
            if let model {
                NavigationStack { VaultItemDetailView(name: secret.name, model: model) }
                    // Half height to see what it is, full height to work with it.
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    /// Adding is the one place a secret is typed, so Settings' lock (when it is on) is asked first.
    private func startAdding() {
        guard !unlocking else { return }
        unlocking = true
        Task {
            defer { unlocking = false }
            if await KeysBiometricGate.confirm(reason: VaultScreenCopy.addTitle) { adding = true }
        }
    }

    @ViewBuilder
    private func content(_ model: VaultItemsModel) -> some View {
        switch model.phase {
        case .loading:
            HVLoadingState(message: VaultCopy.loadingLine).frame(maxHeight: .infinity)
        case .failed(let message):
            HVErrorState(message: message) { Task { await model.load() } }.frame(maxHeight: .infinity)
        case .loaded:
            list(model)
        }
    }

    private func list(_ model: VaultItemsModel) -> some View {
        @Bindable var model = model
        return List {
            // The pane's description, then the filters: the first thing on the page after its title.
            Section {
                Text(AccountPane.vault.descriptionLine ?? "")
                    .font(.hvCallout)
                    .foregroundStyle(Palette.textSecondary)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: HV.Space.m, bottom: HV.Space.xs, trailing: HV.Space.m))
                if let message = model.refreshError {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.danger)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: HV.Space.m, bottom: HV.Space.xs, trailing: HV.Space.m))
                }
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
                        .listRowSeparator(.hidden)
                } footer: {
                    note(model)
                }
            } else {
                Section {
                    ForEach(shown) { secret in
                        // A button, not a navigation link: the page is a sheet. In a list it highlights as a row does.
                        Button { opened = secret } label: {
                            VaultRow(secret: secret, showsChevron: true)
                        }
                        .accessibilityLabel(VaultRow.spokenLabel(for: secret))
                        .accessibilityIdentifier("vault.row.\(secret.name)")
                    }
                } footer: {
                    note(model)
                }
                .hvListRow()
            }
        }
        .scrollContentBackground(.hidden)
        .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search")
        .refreshable { await model.load() }
    }

    /// What stays visible beside what is hidden, said once, under the entries (brand book rule 4): the web's own line.
    /// When the account is full, the server's refusal comes first, since the Add button is off and nothing else says why.
    private func note(_ model: VaultItemsModel) -> some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            if let limit = VaultLimits.entryLimitProblem(count: model.secrets.count) {
                Text(limit).foregroundStyle(Palette.danger)
            }
            Label(HVCopy.landingVaultLockLine, systemImage: "lock.fill")
        }
        .font(.hvFootnote)
        .foregroundStyle(Palette.textSecondary)
    }

    private func filters(_ model: VaultItemsModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: HV.Space.hair) {
                pill("All", category: nil, model: model)
                ForEach(VaultCategory.allCases) { category in
                    pill(category.label, category: category, model: model)
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
        .accessibilityLabel("Show")
    }

    /// A filter and its count. The count is always there, 0 included: "its 0 already says so".
    private func pill(_ title: String, category: VaultCategory?, model: VaultItemsModel) -> some View {
        HVFilterPill(title: title, count: model.count(in: category), isSelected: model.filter == category) {
            model.filter = category
        }
    }

    @ViewBuilder
    private func empty(_ model: VaultItemsModel) -> some View {
        if !model.query.isEmpty {
            HVEmptyState(symbol: "magnifyingglass", title: "Nothing called that", message: "Try part of a name, a username or a card's last four digits.")
        } else {
            VStack(spacing: HV.Space.s) {
                HVEmptyBox(message: model.filter?.emptyLine ?? VaultScreenCopy.emptyVaultLine)
                if !model.isFull {
                    Button("Add", action: startAdding).buttonStyle(.hvGhost)
                }
            }
        }
    }
}

// MARK: Row

struct VaultRow: View {
    let secret: VaultSecret
    /// The mark of a row that opens something without being a navigation link.
    var showsChevron = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isLarge: Bool { dynamicTypeSize.isAccessibilitySize }
    /// The tile is 36pt, whatever the text size (handoff 4.3).
    private let tileSize: CGFloat = 36
    private let spacing = HV.Space.s + 2

    /// What VoiceOver reads for the row: the name, the hint with a card's mask as "ending in 4242", and when an agent last
    /// read it ("Never used", "Last used 2 days ago").
    static func spokenLabel(for secret: VaultSecret) -> String {
        "\(secret.name), \(secret.spokenSubtitle). \(VaultCopy.rowLastUsedLine(secret.lastAccessedAt))"
    }

    var body: some View {
        HStack(spacing: HV.Space.xs) {
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
                    // Under the hint at every width: beside it, "Last used 2 months ago" leaves a name no room.
                    Text(VaultCopy.rowLastUsedLine(secret.lastAccessedAt))
                        .font(.hvCaption)
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(isLarge ? nil : 1)
                }
            }
            if showsChevron { KeysChevron() }
        }
        .contentShape(Rectangle())
        // Every separator starts under the text. Left to itself the system takes a login's monogram, which is
        // text, as the start of the row and draws that one line further left than the rest.
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + (isLarge ? 0 : tileSize + spacing) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.spokenLabel(for: secret))
    }
}

#if DEBUG
#Preview("Vault") {
    PreviewHost(routes: VaultPreviewData.routes) { VaultItemsView() }
}

#Preview("Vault, empty") {
    PreviewHost(routes: [.json(.get, "/api/secrets", #"{"secrets":[]}"#)]) { VaultItemsView() }
}
#endif
