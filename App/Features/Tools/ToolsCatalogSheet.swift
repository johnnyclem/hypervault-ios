import HyperVaultKit
import SwiftUI

/// The catalog: the official MCP registry (remote servers only), searchable,
/// with the ones HyperVault suggests first. Results are checked for life after
/// they appear, so an address that no longer answers sinks to the bottom.
@MainActor
@Observable
final class ToolsCatalogModel {
    enum Phase: Equatable { case loading, loaded, failed(String) }

    private(set) var phase: Phase = .loading
    private(set) var results: [McpRegistryEntry] = []
    private(set) var suggested: [McpRegistryEntry] = []
    /// Addresses a quick add is working on.
    private(set) var adding: Set<String> = []
    var query = ""

    @ObservationIgnored private let client: HVClient
    @ObservationIgnored private var probing: Task<Void, Never>?
    @ObservationIgnored private var knownDead: Set<String> = []

    init(client: HVClient) {
        self.client = client
    }

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Runs for the current query: waits for typing to pause, asks, then checks the answers' addresses.
    func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
        }
        probing?.cancel()
        do {
            let found = try await client.send(.searchMcpRegistry(query: text))
            if Task.isCancelled { return }
            results = McpRegistryEntry.applying([], to: found.servers, knownDead: knownDead)
            suggested = found.suggested
            phase = .loaded
            probe(results)
        } catch {
            if Task.isCancelled { return }
            if case .cancelled = (error as? HVError) ?? .transport("") { return }
            if results.isEmpty { phase = .failed((error as? HVError)?.userMessage ?? error.localizedDescription) }
        }
    }

    private func probe(_ entries: [McpRegistryEntry]) {
        let urls = entries.prefix(McpRegistryEntry.livenessBatchSize).map(\.url)
        guard !urls.isEmpty else { return }
        let client = self.client
        probing = Task { [weak self] in
            guard let answer = try? await client.send(.probeMcpLiveness(urls: urls)), !Task.isCancelled else { return }
            guard let self else { return }
            for verdict in answer.results {
                let key = McpServer.normalize(verdict.url)
                if verdict.state == .dead { self.knownDead.insert(key) }
                if verdict.state == .alive { self.knownDead.remove(key) }
            }
            HV.Motion.animate(.easeInOut(duration: 0.25)) {
                self.results = McpRegistryEntry.applying(answer.results, to: self.results, knownDead: self.knownDead)
            }
        }
    }

    enum QuickAdd {
        case added
        case needsSignIn
        case refused(String)
    }

    /// Connects a catalog entry in one tap. A server that wants a login is
    /// handed back, to continue in the add sheet.
    func quickAdd(_ entry: McpRegistryEntry, into model: ToolsModel) async -> QuickAdd {
        if model.isAlreadyAdded(url: entry.url) { return .refused("That server is already added.") }
        if model.isFull { return .refused("Limit of \(model.maxServers) MCP servers reached.") }
        adding.insert(entry.url)
        defer { adding.remove(entry.url) }
        do {
            let answer = try await client.send(.addMcpServer(McpAddRequest(url: entry.url, name: entry.name, registryId: entry.registryId)))
            model.didAdd(answer.server, message: answer.message)
            Haptics.success()
            return .added
        } catch let error as HVError where error.isMcpAuthRequired {
            return .needsSignIn
        } catch {
            Haptics.failure()
            return .refused((error as? HVError)?.userMessage ?? error.localizedDescription)
        }
    }
}

struct ToolsCatalogSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    let model: ToolsModel
    let client: HVClient
    @State private var catalog: ToolsCatalogModel
    @State private var candidate: ToolsCandidate?

    init(model: ToolsModel, client: HVClient) {
        self.model = model
        self.client = client
        _catalog = State(initialValue: ToolsCatalogModel(client: client))
    }

    var body: some View {
        NavigationStack {
            content
                .hvScreenBackground()
                .navigationTitle("Catalog")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                }
                .searchable(text: $catalog.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search the MCP registry")
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .task(id: catalog.query) { await catalog.search() }
                .sheet(item: $candidate) { candidate in
                    ToolsAddServerSheet(candidate: candidate, client: client, model: model)
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch catalog.phase {
        case .loading:
            ScrollView { HVListSkeleton() }
        case .failed(let message):
            HVErrorState(message: message) { Task { await catalog.search() } }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            list
        }
    }

    private var list: some View {
        List {
            if !catalog.suggested.isEmpty, !catalog.isSearching {
                Section(header: HVSectionHeader(title: "Suggested")) {
                    ForEach(catalog.suggested) { entry in row(entry) }
                }
                .hvListRow()
            }
            Section(header: HVSectionHeader(title: catalog.isSearching ? "Matches" : "From the MCP registry"),
                    footer: footer) {
                if catalog.results.isEmpty {
                    emptyResults
                }
                ForEach(catalog.results) { entry in row(entry) }
            }
            .hvListRow()
        }
        .scrollContentBackground(.hidden)
        .refreshable { await catalog.search() }
    }

    private var footer: some View {
        Text("These are the registry's own descriptions. Look at what a server can do before you add it, and only add the ones you trust.")
            .hvSectionNote()
    }

    private var emptyResults: some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            Text(catalog.isSearching ? "Nothing remote matched" : "The registry has nothing to show right now")
                .font(.hvHeadline)
            Text("The registry may be unavailable, or the server you want may not offer a web address. You can still add one by its address.")
                .font(.hvFootnote)
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(.vertical, HV.Space.xs)
    }

    private func row(_ entry: McpRegistryEntry) -> some View {
        ToolsCatalogRow(
            entry: entry,
            isAdded: model.isAlreadyAdded(url: entry.url),
            isAdding: catalog.adding.contains(entry.url),
            onOpen: { candidate = ToolsCandidate(entry) },
            onAdd: {
                Task {
                    switch await catalog.quickAdd(entry, into: model) {
                    case .added: break
                    case .needsSignIn: candidate = ToolsCandidate(entry)
                    case .refused(let sentence): app.toasts.show(sentence, style: .error)
                    }
                }
            }
        )
    }
}

struct ToolsCatalogRow: View {
    let entry: McpRegistryEntry
    let isAdded: Bool
    let isAdding: Bool
    var onOpen: () -> Void
    var onAdd: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: HV.Space.s) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: HV.Space.s + 2) {
                    HVIconBadge(symbol: "globe", tint: entry.dead ? Palette.textTertiary : Palette.sky)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: HV.Space.xs) {
                            Text(entry.displayName)
                                .font(.hvBody)
                                .foregroundStyle(entry.dead ? Palette.textSecondary : Palette.textPrimary)
                                .lineLimit(2)
                            if entry.dead { HVTag(text: "Unreachable", tint: Palette.danger) }
                        }
                        Text(entry.description.isEmpty ? entry.url : entry.description)
                            .font(.hvFootnote)
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        HVTag(text: entry.transportLabel)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows what this server offers")

            addControl
        }
        .frame(minHeight: 44)
        // Without this the list measures the separator from the "Added" label on the one row that has it,
        // and draws a stub under it. Every row's separator starts at its title instead, past the icon.
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + Self.titleColumn }
    }

    /// The icon badge and the gap after it: where a row's title begins.
    private static let titleColumn: CGFloat = 36 + HV.Space.s + 2

    @ViewBuilder
    private var addControl: some View {
        if isAdded {
            // The same capsule as "Add", in mint and not tappable, so every row ends the same way.
            HStack(spacing: 4) {
                HVIcon("checkmark").font(.system(size: 11, weight: .bold))
                Text("Added")
            }
            .font(.system(.footnote, weight: .semibold))
            .foregroundStyle(Palette.mint)
            .padding(.horizontal, HV.Space.m)
            .frame(minHeight: 44)
            .background(Palette.mint.opacity(0.14), in: Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(entry.displayName) is added")
        } else if isAdding {
            ProgressView().frame(width: 44, height: 44)
        } else {
            Button(action: onAdd) {
                Text("Add")
                    .font(.system(.footnote, weight: .semibold))
                    .padding(.horizontal, HV.Space.m)
                    .frame(minHeight: 44)
                    .background(Palette.blue.opacity(0.14), in: Capsule())
                    .foregroundStyle(Palette.sky)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add \(entry.displayName)")
        }
    }
}

#if DEBUG
#Preview("Catalog") {
    PreviewHost(routes: ToolsFixtures.routes, embedInNavigation: false) {
        ToolsModelHost { model, client in ToolsCatalogSheet(model: model, client: client) }
    }
}
#endif
