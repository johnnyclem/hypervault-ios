import HyperVaultKit
import SwiftUI

/// The Graph mode: memories and the links between them, with the pages they
/// are bridged to, as a force-directed map.
struct MemoryGraphScreen: View {
    let list: MemoryListModel

    @Environment(AppModel.self) private var app
    @State private var model: MemoryGraphModel

    init(list: MemoryListModel) {
        self.list = list
        _model = State(initialValue: MemoryGraphModel(env: list.env))
    }

    var body: some View {
        let graph = model.graph(for: list.items)
        Group {
            if list.items.isEmpty {
                switch list.phase {
                case .loading: HVLoadingState()
                case .failed(let message): HVErrorState(message: message) { Task { await list.load() } }
                case .loaded:
                    HVEmptyState(
                        symbol: "point.3.connected.trianglepath.dotted",
                        title: "Nothing to map yet",
                        message: "Memories, and the links between them, show up here as you keep things."
                    )
                }
            } else if model.isReadingLinks {
                // Another branch's own links are on their way: main's would be the wrong map.
                HVLoadingState()
            } else {
                VStack(spacing: 0) {
                    ForceGraphView(
                        nodes: forceNodes(for: graph),
                        edges: forceEdges(for: graph),
                        legend: legend(for: graph),
                        onOpen: { open($0, in: graph) }
                    )
                    caption(for: graph)
                }
            }
        }
        .task(id: list.branch) { await model.load(branch: list.branch) }
    }

    // MARK: Mapping memories onto the generic graph

    private func forceNodes(for graph: MemoryGraph) -> [ForceGraphNode] {
        let sources = Dictionary(list.items.map { ($0.id, $0.source) }, uniquingKeysWith: { first, _ in first })
        return graph.nodes.map { node in
            switch node.kind {
            case .memory:
                return ForceGraphNode(
                    id: node.id, label: node.title,
                    color: MemoryStyle.graphTint(forSource: sources[node.id] ?? "manual"),
                    shape: .circle, weight: 1 + min(Double(node.degree), 8) * 0.7, detail: "Memory"
                )
            case .artifact:
                return ForceGraphNode(
                    id: node.id, label: node.title, color: Palette.rose,
                    shape: .diamond, weight: 1.6 + min(Double(node.degree), 6) * 0.5, detail: "Page"
                )
            }
        }
    }

    private func forceEdges(for graph: MemoryGraph) -> [ForceGraphEdge] {
        graph.edges.map { ForceGraphEdge(source: $0.source, target: $0.target, isStrong: $0.isManual) }
    }

    private func legend(for graph: MemoryGraph) -> [ForceGraphLegendItem] {
        var seen: [String] = []
        let sources = Dictionary(list.items.map { ($0.id, $0.source) }, uniquingKeysWith: { first, _ in first })
        for node in graph.nodes where node.kind == .memory {
            let source = sources[node.id] ?? "manual"
            if !seen.contains(source) { seen.append(source) }
        }
        var items = seen.map { ForceGraphLegendItem(title: MemorySource.label($0), color: MemoryStyle.graphTint(forSource: $0)) }
        if graph.nodes.contains(where: { $0.kind == .artifact }) {
            items.append(ForceGraphLegendItem(title: "Page", color: Palette.rose, shape: .diamond))
        }
        return items
    }

    private func open(_ id: String, in graph: MemoryGraph) {
        guard let node = graph.node(id) else { return }
        switch node.kind {
        case .memory:
            app.router.push(.memory(id: id))
        case .artifact:
            if let slug = node.slug { app.router.push(.artifact(slug: slug)) }
        }
    }

    private func caption(for graph: MemoryGraph) -> some View {
        var parts = ["\(graph.memoryTotal) \(graph.memoryTotal == 1 ? "memory" : "memories")"]
        parts.append("\(graph.edges.count) \(graph.edges.count == 1 ? "link" : "links")")
        if graph.isCapped { parts.append("the \(graph.nodes.count) best connected are shown") }
        if graph.edges.isEmpty { parts = ["No links yet. They form as you keep related memories."] }
        if let note = model.linkNote { parts.append(note) }
        return Text(parts.joined(separator: " \u{00B7} "))
            .font(.hvCaption)
            .foregroundStyle(Palette.textTertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, HV.Space.m)
            .padding(.vertical, HV.Space.xs)
            .frame(maxWidth: .infinity)
    }
}
