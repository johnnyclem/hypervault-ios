import HyperVaultKit
import SwiftUI

/// What the Library's graph holds and what the person has chosen to leave out of it. The web draws one map for the Library
/// and one for Memory (`vault-graph.tsx`); this one starts from the pages, so a vault of pages and no memories still has
/// something to show.
@MainActor
@Observable
final class LibraryGraphModel {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var graph = LibraryGraph.empty
    private(set) var hiddenTypes: Set<String> = []
    private(set) var hideUnlinked = false
    /// The table could not be read, so the pages are the 50 last used (the ordinary route names those by row id).
    private(set) var pagesAreFewer = false
    /// The vault holds more pages than the map reads, and these are the newest.
    private(set) var pagesTruncated = false
    /// The memories could not be read, so only pages are drawn.
    private(set) var memoriesUnavailable = false
    /// The memories read were as many as the server sends, so older ones may be missing.
    private(set) var memoriesTruncated = false
    /// The links could not be read, so what is drawn has none.
    private(set) var linksUnavailable = false
    var query = ""

    /// What `GET /api/memories` sends at most.
    static let memoryLimit = 200
    /// A map read this recently is not read again when the screen reappears (a person coming back from a page).
    private static let freshFor: TimeInterval = 60

    @ObservationIgnored private let env: AppEnvironment
    @ObservationIgnored private var pages: [LibraryGraphPage] = []
    @ObservationIgnored private var memories: [MemoryItem] = []
    @ObservationIgnored private var connections = LibraryConnections()
    @ObservationIgnored private var loadedAt: Date?

    init(env: AppEnvironment) {
        self.env = env
    }

    /// The nodes whose name has what was typed in it.
    var matches: [LibraryGraph.Node] { graph.matches(query) }

    /// Reads the pages, the memories and the links. Run again when the screen comes back, it leaves a map read in the last
    /// minute as it is, and a failed read leaves the map that is on the screen on it. `force` is the Try again button.
    func load(force: Bool = false) async {
        if !force, phase == .loaded, let loadedAt, Date().timeIntervalSince(loadedAt) < Self.freshFor { return }
        if case .failed = phase { phase = .loading }
        let client = env.client
        let rest = env.keysRest
        let userID = env.user.id
        async let pageRows = attempt { try await LibraryGraphRow.pages(rest: rest, userID: userID) }
        async let memoryRows = attempt { try await client.send(.memoryList()).memories }
        async let edgeRows = attempt { try await client.send(.libraryConnections) }

        var pagesResult = await pageRows
        let memoriesResult = await memoryRows
        let edgesResult = await edgeRows
        var fewer = false
        if case .failure(let error) = pagesResult, !MemoryErrors.isCancelled(error) {
            // The table could not be read: the 50 pages last used still have their row ids from the ordinary route.
            let recent = await attempt { try await Self.recentPages(client) }
            if case .success(let loaded) = recent {
                pagesResult = .success(LibraryGraphPages(pages: loaded))
                fewer = true
            }
        }
        // A run that was cancelled (the person went on to another screen) changes nothing.
        guard !Task.isCancelled else { return }

        var firstError: Error?
        switch pagesResult {
        case .success(let read):
            pages = read.pages
            pagesTruncated = read.isTruncated
        case .failure(let error):
            firstError = error
        }
        switch memoriesResult {
        case .success(let loaded):
            memories = loaded
            memoriesUnavailable = false
            memoriesTruncated = loaded.count >= Self.memoryLimit
        case .failure(let error):
            memoriesUnavailable = true
            firstError = firstError ?? error
        }
        switch edgesResult {
        case .success(let loaded):
            connections = loaded
            linksUnavailable = false
        case .failure:
            linksUnavailable = true
        }
        pagesAreFewer = fewer

        // Nothing at all to draw, and something could not be read: that is an error, not an empty vault.
        if pages.isEmpty, memories.isEmpty, let firstError {
            if phase != .loaded {
                phase = .failed((firstError as? HVError)?.userMessage ?? firstError.localizedDescription)
            }
            return
        }
        rebuild()
        phase = .loaded
        loadedAt = Date()
    }

    func setHideUnlinked(_ on: Bool) {
        guard on != hideUnlinked else { return }
        hideUnlinked = on
        rebuild()
    }

    /// Shows or hides every node of this type.
    func toggle(type: String) {
        if hiddenTypes.contains(type) { hiddenTypes.remove(type) } else { hiddenTypes.insert(type) }
        rebuild()
    }

    func showEverything() {
        hiddenTypes = []
        hideUnlinked = false
        rebuild()
    }

    private func rebuild() {
        graph = LibraryGraphBuilder.build(
            pages: pages, memories: memories,
            pageLinks: connections.pageLinks, memoryLinks: connections.memoryLinks, bridges: connections.bridges,
            hiddenTypes: hiddenTypes, hideUnlinked: hideUnlinked
        )
    }

    /// The pages `/api/yours` can name by row id: the 50 last used, groups left out.
    nonisolated private static func recentPages(_ client: HVClient) async throws -> [LibraryGraphPage] {
        let list = try await client.send(.yours(filter: .file, limit: 50))
        return list.results.compactMap { item in
            guard item.kind != .group, let slug = item.slug else { return nil }
            return LibraryGraphPage(id: item.id, slug: slug, title: item.name)
        }
    }
}

private func attempt<T: Sendable>(_ work: @Sendable () async throws -> T) async -> Result<T, Error> {
    do {
        return .success(try await work())
    } catch {
        return .failure(error)
    }
}

/// How the graph colours its nodes: four hues that sit well apart, and the rest in grey. A memory is `KeptKind.memory`'s
/// violet and a page of no named type (html) is `KeptKind.page`'s blue, so the map reads as the rest of the app does;
/// writing (markdown, notes, text) is mint and a report is amber, the other two of the four `KeptKind` draws a graph
/// in. Every other type (react, game, pdf, image) is `Palette.textSecondary`. The legend and the type pills name each
/// type in words, so colour is never the only way to tell them apart.
enum LibraryGraphStyle {
    static func tint(forType type: String) -> Color {
        switch type {
        case LibraryGraphType.memory: return KeptKind.memory.tint
        case "markdown", "note", "text": return Palette.mint
        case "report": return Palette.amber
        case "react", "jsx", "tsx", "game", "pdf", "image": return Palette.textSecondary
        default: return KeptKind.page.tint
        }
    }

    static func shape(for node: LibraryGraph.Node) -> ForceGraphNode.Shape {
        node.kind == .memory ? .circle : .diamond
    }

    /// The word the node shows when it is selected.
    static func detail(for node: LibraryGraph.Node) -> String {
        node.kind == .memory ? "Memory" : ArtifactTypeName.name(type: node.type)
    }

    static func weight(for node: LibraryGraph.Node) -> Double {
        switch node.kind {
        case .memory: return 1 + min(Double(node.degree), 8) * 0.7
        case .page: return 1.6 + min(Double(node.degree), 6) * 0.5
        }
    }
}
