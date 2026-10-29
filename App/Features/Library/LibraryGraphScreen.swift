import HyperVaultKit
import SwiftUI

/// The Library's graph mode: every page beside every memory, and the links among them (a page's connections, made by hand
/// or found by the server, a memory's links, and the pages a memory is bridged to). The person can leave a type out, leave
/// out what has no links, and find a node by name; the Memory tab's map draws the memories alone.
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
            content.overlay(alignment: .top) {
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
        VStack(spacing: HV.Space.xxs) {
            HStack(spacing: HV.Space.xs) {
                HVIcon("magnifyingglass").foregroundStyle(Palette.textTertiary)
                TextField("Find a page or memory", text: Binding(get: { model.query }, set: { model.query = $0 }), prompt: Text.hvPrompt("Find a page or memory"))
                    .accessibilityIdentifier("library.graph.search")
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                if !model.query.isEmpty {
                    Button { model.query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Palette.textTertiary)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear the search")
                }
            }
            .padding(.horizontal, HV.Space.m)
            .frame(minHeight: 44)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
            .padding(.horizontal, HV.Space.m)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: HV.Space.hair) {
                    ForEach(model.graph.types) { type in
                        HVFilterPill(title: type.name, count: type.count, isSelected: !model.hiddenTypes.contains(type.name)) {
                            model.toggle(type: type.name)
                        }
                        .accessibilityIdentifier("library.graph.type.\(type.name)")
                        .accessibilityHint(model.hiddenTypes.contains(type.name) ? "Shows them on the map" : "Leaves them off the map")
                    }
                    Button {
                        Haptics.select()
                        model.setHideUnlinked(!model.hideUnlinked)
                    } label: {
                        HVChip(title: "Hide unlinked", symbol: "eye.slash", isSelected: model.hideUnlinked)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Hide unlinked")
                    .accessibilityAddTraits(model.hideUnlinked ? .isSelected : [])
                    .accessibilityIdentifier("library.graph.unlinked")
                    .padding(.leading, HV.Space.xs)
                }
                .padding(.horizontal, HV.Space.m)
            }
        }
        .padding(.top, HV.Space.xs)
    }

    /// What the search found: the best connected first. Tapping one opens it, as a tap on its node does. It is laid over the
    /// map and scrolls inside a height of its own, so a few matches at a large text size do not push the map away.
    @ViewBuilder private var results: some View {
        let found = model.matches
        ScrollView {
            VStack(spacing: 0) {
                if found.isEmpty {
                    Text("Nothing on the map has that in its name.")
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, HV.Space.m)
                        .padding(.vertical, HV.Space.s)
                }
                ForEach(found) { node in
                    Button { open(node.id) } label: {
                        HStack(spacing: HV.Space.s) {
                            Image(systemName: node.kind == .memory ? HVSymbol.memory : "doc.text")
                                .foregroundStyle(LibraryGraphStyle.tint(forType: node.type))
                                .hvIconSlot(22)
                                .accessibilityHidden(true)
                            Text(node.title)
                                .font(.hvSubheadline)
                                .foregroundStyle(Palette.textPrimary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: HV.Space.xs)
                            Text(LibraryGraphStyle.detail(for: node))
                                .font(.hvCaption)
                                .foregroundStyle(Palette.textTertiary)
                        }
                        .padding(.horizontal, HV.Space.m)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(node.title), \(LibraryGraphStyle.detail(for: node))")
                    .accessibilityHint("Opens it")
                }
            }
        }
        .frame(maxHeight: 260)
        .fixedSize(horizontal: false, vertical: true)
        .background(Palette.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.border).frame(height: 1) }
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
