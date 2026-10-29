import HyperVaultKit
import SwiftUI

/// What a page is connected to: other pages and memories, found by the server
/// or added by hand. Shows each with its name, connects to another thing found
/// by name, and removes a connection.
@MainActor
@Observable
final class ArtifactConnectionsModel {
    private(set) var phase: ArtifactLoad<[ArtifactLinkedItem]> = .loading
    private(set) var results: [KeptItem] = []
    private(set) var searching = false
    private(set) var pending = false
    private(set) var error: String?

    private let client: HVClient
    private let slug: String
    private let rowID: @MainActor () async -> String?
    /// The most connections looked up by name at once.
    private static let lookupLimit = 30

    init(client: HVClient, slug: String, rowID: @escaping @MainActor () async -> String?) {
        self.client = client
        self.slug = slug
        self.rowID = rowID
    }

    func load() async {
        guard let id = await rowID() else {
            phase = .failed("Connections are for pages in your own library.")
            return
        }
        do {
            let edges = try await client.send(.artifactEdges)
            let pages = Array(edges.edges(touching: id).prefix(Self.lookupLimit))
            let memories = Array(edges.bridges(touching: id).prefix(Self.lookupLimit))
            let items = await resolve(pages: pages, memories: memories, from: id)
            phase = .loaded(items)
        } catch {
            phase = .failed(ArtifactErrors.message(error))
        }
    }

    /// Looks up the other end of each edge by name. One that cannot be read is shown as what it is.
    private func resolve(pages: [ArtifactEdge], memories: [ArtifactMemoryBridge], from id: String) async -> [ArtifactLinkedItem] {
        let client = client
        return await withTaskGroup(of: ArtifactLinkedItem?.self) { group in
            for edge in pages {
                guard let other = edge.other(from: id) else { continue }
                group.addTask {
                    let card = try? await client.send(.card(kind: .file, id: other))
                    let target = card.flatMap { $0.slug }.map { ArtifactLinkedItem.Target.page(slug: $0) }
                    return ArtifactLinkedItem(
                        id: edge.id, name: card?.name ?? "A page", kind: card?.kind ?? .page,
                        target: target, isAuto: edge.isAuto
                    )
                }
            }
            for bridge in memories {
                group.addTask {
                    let card = try? await client.send(.card(kind: .memory, id: bridge.memoryId))
                    return ArtifactLinkedItem(
                        id: bridge.id, name: card?.name ?? "A memory", kind: .memory,
                        target: .memory(id: bridge.memoryId), isAuto: bridge.isAuto
                    )
                }
            }
            var items: [ArtifactLinkedItem] = []
            for await item in group { if let item { items.append(item) } }
            return items.sorted { lhs, rhs in
                if lhs.isAuto != rhs.isAuto { return !lhs.isAuto }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }

    /// Finds things to connect to by name: pages, files, groups and memories, not this page.
    func search(_ text: String) async {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            results = []
            return
        }
        searching = true
        defer { searching = false }
        do {
            let list = try await client.send(.yours(filter: .all, query: query, limit: 20))
            guard !Task.isCancelled else { return }
            results = list.results.filter { $0.kind != .key && $0.slug != slug }
        } catch {
            if !Task.isCancelled { results = [] }
        }
    }

    func connect(to item: KeptItem) async -> String? {
        pending = true
        error = nil
        defer { pending = false }
        do {
            let done = try await client.send(.connectArtifact(source: slug, target: item.id))
            await load()
            return done.message
        } catch {
            self.error = ArtifactErrors.message(error)
            return nil
        }
    }

    func remove(_ item: ArtifactLinkedItem) async -> Bool {
        guard case .loaded(let current) = phase else { return false }
        error = nil
        phase = .loaded(current.filter { $0.id != item.id })
        do {
            _ = try await client.send(.disconnect(edge: item.id))
            return true
        } catch {
            phase = .loaded(current)
            self.error = ArtifactErrors.message(error)
            return false
        }
    }
}

struct ArtifactConnectionsSheet: View {
    let detail: ArtifactDetailModel

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @State private var model: ArtifactConnectionsModel
    @State private var query = ""
    @State private var removing: ArtifactLinkedItem?

    init(detail: ArtifactDetailModel) {
        self.detail = detail
        _model = State(initialValue: ArtifactConnectionsModel(
            client: detail.env.client, slug: detail.slug, rowID: { await detail.ensureRowID() }
        ))
    }

    var body: some View {
        NavigationStack {
            List {
                connectedSection
                connectSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .hvScreenBackground()
            .navigationTitle("Connections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog(
                removing.map { "Remove the connection to \($0.name)?" } ?? "",
                isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                titleVisibility: .visible, presenting: removing
            ) { item in
                Button("Remove connection", role: .destructive) { remove(item) }
            } message: { _ in
                Text("Both stay as they are. Only the link between them goes.")
            }
        }
        .task { await model.load() }
        .task(id: query) {
            // A pause in typing, then the search; typing again cancels this one.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await model.search(query)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: Sections

    private var connectedSection: some View {
        Section {
            switch model.phase {
            case .loading:
                HVLoadingState().listRowBackground(Color.clear)
            case .failed(let message):
                HVErrorState(message: message) { Task { await model.load() } }
                    .listRowBackground(Color.clear)
            case .loaded(let items):
                if items.isEmpty {
                    Text("Nothing is connected to this yet.")
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.textSecondary)
                }
                ForEach(items) { item in
                    Button { open(item) } label: { linkedRow(item) }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { removing = item } label: { Label("Remove", systemImage: "link.badge.minus") }
                        }
                        .accessibilityAction(named: "Remove connection") { removing = item }
                }
            }
            if let error = model.error { ArtifactErrorLine(message: error).listRowBackground(Color.clear) }
        } header: {
            HVSectionHeader(title: "Connected")
        }
        .hvListRow()
    }

    private func linkedRow(_ item: ArtifactLinkedItem) -> some View {
        HVRow(symbol: item.kind.symbol, tint: item.kind.tint, title: item.name, subtitle: item.kind.singular) {
            if item.isAuto { HVTag(text: "Found for you") }
        }
        .contentShape(Rectangle())
    }

    private var connectSection: some View {
        Section {
            HVLabeledField(title: "Find by name") {
                TextField("Find by name", text: $query, prompt: artifactPrompt("A page, file, group or memory"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .listRowSeparator(.hidden)
            if model.searching && model.results.isEmpty {
                HStack { ProgressView(); Text("Searching").font(.hvFootnote).foregroundStyle(Palette.textSecondary) }
            }
            ForEach(model.results) { item in
                Button {
                    connect(item)
                } label: {
                    HVRow(symbol: item.kind.symbol, tint: item.kind.tint, title: item.name, subtitle: item.kind.singular) {
                        Image(systemName: "plus.circle").foregroundStyle(.tint)
                    }
                }
                .buttonStyle(.plain)
                .disabled(model.pending)
                .accessibilityLabel("Connect to \(item.name)")
            }
        } header: {
            HVSectionHeader(title: "Connect to")
        } footer: {
            Text("A connection shows in the graph and tells your agents the two belong together.").hvSectionNote()
        }
        .hvListRow()
    }

    // MARK: Actions

    private func connect(_ item: KeptItem) {
        Task {
            if let message = await model.connect(to: item) {
                query = ""
                app.toasts.show(message, style: .success)
            } else {
                Haptics.failure()
            }
        }
    }

    private func remove(_ item: ArtifactLinkedItem) {
        Task {
            if await model.remove(item) { Haptics.success() } else { Haptics.failure() }
        }
    }

    private func open(_ item: ArtifactLinkedItem) {
        guard let target = item.target else { return }
        dismiss()
        switch target {
        case .page(let slug): app.router.push(.artifact(slug: slug))
        case .memory(let id): app.router.push(.memory(id: id))
        }
    }
}
