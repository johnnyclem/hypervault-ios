import HyperVaultKit
import SwiftUI

/// The Library's graph mode: every page beside every memory, and the links among them (a page's connections, made by hand
/// or found by the server, a memory's links, and the pages a memory is bridged to). The person can leave a type out, leave
/// out what has no links, and find a node by name; the Memory tab's map has the same controls (`GraphControls`) over the
/// memories and the pages they are bridged to.
struct LibraryGraphScreen: View {
    @Environment(AppModel.self) private var app
    @State private var model: LibraryGraphModel

    init(env: AppEnvironment) {
        _model = State(initialValue: LibraryGraphModel(env: env))
    }

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                HVLoadingState()
            case .failed(let message):
                HVErrorState(message: message) { Task { await model.load(force: true) } }
            case .loaded:
                if model.graph.total == 0 {
                    HVEmptyState(
                        symbol: "point.3.connected.trianglepath.dotted",
                        title: "Nothing to map yet",
                        message: "Pages and memories, and the links between them, show up here as you keep things."
                    )
                } else {
                    loaded
                }
            }
        }
        .task { await model.load() }
    }

    private var loaded: some View {
        VStack(spacing: 0) {
            controls
            // What the search finds is laid over the map, not put above it: at a large text size the rows would take the
            // map's room, and the map would vanish while someone searches.
            // (One view to lay it over: `content` has the map and its caption as two, and a modifier on it would be put on
            // each, drawing the rows twice.)
            VStack(spacing: 0) { content }.overlay(alignment: .top) {
                if !model.query.trimmingCharacters(in: .whitespaces).isEmpty { results }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if model.graph.nodes.isEmpty {
            HVEmptyState(
                symbol: "line.3.horizontal.decrease.circle",
                title: "Nothing to show",
                message: emptyMessage
            )
            .frame(maxHeight: .infinity)
            Button("Show everything") { model.showEverything() }
                .buttonStyle(.hvGhost)
                .padding(.bottom, HV.Space.m)
        } else {
            ForceGraphView(
                nodes: forceNodes,
                edges: forceEdges,
                legend: legend,
                isCovered: app.router.sheet != nil,
                onOpen: open
            )
            caption
        }
    }

    /// Why a map with things in the vault has nothing on it.
    private var emptyMessage: String {
        if model.linksUnavailable && model.hideUnlinked {
            return "The links could not be read, so nothing shows as linked. Try again in a moment."
        }
        if model.hideUnlinked {
            return model.hiddenTypes.isEmpty
                ? "Nothing has a link yet. Links form as you keep related pages and memories."
                : "Nothing left has a link. Show a type again above, or show everything."
        }
        return "Every type is hidden. Show one again above."
    }

    // MARK: Controls

    private var controls: some View {
        GraphControls(
            searchTitle: "Find a page or memory",
            query: Binding(get: { model.query }, set: { model.query = $0 }),
            identifierPrefix: "library.graph",
            types: model.graph.types.map { GraphFilterType(name: $0.name, count: $0.count) },
            hiddenTypes: model.hiddenTypes,
            hideUnlinked: model.hideUnlinked,
            onToggleType: { model.toggle(type: $0) },
            onToggleUnlinked: { model.setHideUnlinked(!model.hideUnlinked) }
        )
    }

    /// What the search found: the best connected first. Tapping one opens it, as a tap on its node does.
    private var results: some View {
        GraphSearchResults(
            results: model.matches.map { node in
                GraphSearchResult(
                    id: node.id, title: node.title, detail: LibraryGraphStyle.detail(for: node),
                    symbol: node.kind == .memory ? HVSymbol.memory : "doc.text",
                    tint: LibraryGraphStyle.tint(forType: node.type)
                )
            },
            onOpen: { open($0) }
        )
    }

    // MARK: The graph

    private var forceNodes: [ForceGraphNode] {
        model.graph.nodes.map { node in
            ForceGraphNode(
                id: node.id, label: node.title, color: LibraryGraphStyle.tint(forType: node.type),
                shape: LibraryGraphStyle.shape(for: node), weight: LibraryGraphStyle.weight(for: node),
                detail: LibraryGraphStyle.detail(for: node)
            )
        }
    }

    private var forceEdges: [ForceGraphEdge] {
        model.graph.edges.map { ForceGraphEdge(source: $0.source, target: $0.target, isStrong: $0.isManual) }
    }

    /// One entry for each type on the map: a circle for memories, a diamond for pages.
    private var legend: [ForceGraphLegendItem] {
        var seen: [String] = []
        for node in model.graph.nodes where !seen.contains(node.type) { seen.append(node.type) }
        return seen.map {
            ForceGraphLegendItem(
                title: $0, color: LibraryGraphStyle.tint(forType: $0), shape: $0 == LibraryGraphType.memory ? .circle : .diamond
            )
        }
    }

    private func open(_ id: String) {
        guard let node = model.graph.node(id) else { return }
        switch node.kind {
        case .memory:
            app.router.push(.memory(id: id))
        case .page:
            if let slug = node.slug { app.router.push(.artifact(slug: slug)) }
        }
    }

    private var caption: some View {
        let graph = model.graph
        let pages = graph.nodes.filter { $0.kind == .page }.count
        let memories = graph.nodes.count - pages
        var parts: [String] = []
        if pages > 0 { parts.append("\(pages) \(pages == 1 ? "page" : "pages")") }
        if memories > 0 { parts.append("\(memories) \(memories == 1 ? "memory" : "memories")") }
        parts.append("\(graph.edges.count) \(graph.edges.count == 1 ? "link" : "links")")
        if graph.isCapped { parts.append("the \(graph.nodes.count) best connected of \(graph.eligible) are shown") }
        if model.pagesTruncated { parts.append("newest \(LibraryGraphRow.limit) pages") }
        if model.memoriesTruncated { parts.append("newest \(LibraryGraphModel.memoryLimit) memories") }
        if model.pagesAreFewer { parts.append("only the pages you opened last are mapped") }
        if model.memoriesUnavailable { parts.append("memories could not be read") }
        if model.linksUnavailable {
            parts.append("links could not be read")
        } else if graph.edges.isEmpty {
            parts.append("none of these is linked yet")
        }
        return Text(parts.joined(separator: " \u{00B7} "))
            .font(.hvCaption)
            .foregroundStyle(Palette.textTertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, HV.Space.m)
            .padding(.vertical, HV.Space.xs)
            .frame(maxWidth: .infinity)
    }
}
