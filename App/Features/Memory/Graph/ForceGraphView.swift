import HyperVaultKit
import SwiftUI

/// Where the graph is looking: how big it is drawn and how far it is moved.
struct ForceGraphCamera: Equatable {
    var scale: CGFloat = 1
    var translation: CGSize = .zero
    /// Set once someone pinches or pans, so the picture stops re-framing itself.
    var userMoved = false

    func screen(_ point: ForcePoint) -> CGPoint {
        CGPoint(x: CGFloat(point.x) * scale + translation.width, y: CGFloat(point.y) * scale + translation.height)
    }

    func world(_ point: CGPoint) -> ForcePoint {
        ForcePoint(x: Double((point.x - translation.width) / scale), y: Double((point.y - translation.height) / scale))
    }
}

/// The height the legend takes, so the picture is framed below it however many rows it wraps to.
private struct ForceGraphLegendHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private enum ForceGraphDrag: Equatable {
    case undecided
    case pan
    case node(String)
}

/// A force-directed graph you can pinch, pan and drag nodes about in. Tap a
/// node to see what it is; tap it again, or its Open button, to go there.
/// Drawing is a single Canvas; the layout (ForceLayout, in the Kit) settles
/// ahead of the first frame and then eases into place unless Reduce Motion is on.
struct ForceGraphView: View {
    let nodes: [ForceGraphNode]
    let edges: [ForceGraphEdge]
    var legend: [ForceGraphLegendItem] = []
    /// Most nodes that get a permanent label; the best connected win.
    var hubLabelCount = 6
    var onOpen: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model = ForceGraphModel()
    @State private var camera = ForceGraphCamera()
    @State private var selection: String?
    @State private var drag: ForceGraphDrag = .undecided
    @State private var dragStart: CGSize = .zero
    @State private var pinchStart: ForceGraphCamera?
    @State private var viewSize: CGSize = .zero
    @State private var legendHeight: CGFloat = 0
    @State private var cameraTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                canvas
                    .contentShape(Rectangle())
                    .gesture(dragGesture)
                    .simultaneousGesture(pinchGesture(in: proxy.size))
                    // The picture is read as its nodes (each a button that opens it). This is scoped to the picture: put
                    // on the whole view it would replace the zoom and fit buttons and the legend, and nothing but a
                    // pinch could reach them.
                    .accessibilityChildren {
                        ForEach(nodes) { node in
                            Button(node.label) { onOpen(node.id) }
                                .accessibilityHint("\(model.degree(of: node.id)) connections. Opens it.")
                        }
                    }
                VStack(spacing: 0) {
                    if !legend.isEmpty { legendBar }
                    Spacer(minLength: 0)
                    if let node = selectedNode { callout(for: node) }
                }
                .padding(HV.Space.s)
                controlsIfIdle
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .onAppear {
                viewSize = proxy.size
                model.update(nodes: nodes, edges: edges, reduceMotion: reduceMotion)
                fit(animated: false)
            }
            .onChange(of: proxy.size) { _, size in
                viewSize = size
                if !camera.userMoved { fit(animated: false) }
            }
        }
        .clipped()
        .onChange(of: nodes) { _, _ in refresh() }
        .onChange(of: edges) { _, _ in refresh() }
        .onChange(of: model.points) { _, _ in
            // While the layout is still moving the frame follows it, so the graph never outgrows the screen.
            if !camera.userMoved, model.isSimulating { follow() }
        }
        .onChange(of: model.isSimulating) { _, running in
            if !running, !camera.userMoved { fit(animated: true) }
        }
        .onChange(of: legendHeight) { _, _ in
            if !camera.userMoved { fit(animated: false) }
        }
        .onDisappear { model.stop() }
    }

    // MARK: Drawing

    private var canvas: some View {
        let points = model.points
        let camera = self.camera
        let selection = self.selection
        let focus: Set<String> = selection.map { model.neighbours(of: $0).union([$0]) } ?? []
        let hubs = hubIDs
        let drawn = model.nodes
        let drawnEdges = model.edges
        let keepOut = labelKeepOut
        return Canvas { context, size in
            ForceGraphRenderer.draw(
                into: &context, size: size, nodes: drawn, edges: drawnEdges, points: points,
                camera: camera, selection: selection, focus: focus, hubs: hubs, keepOut: keepOut
            )
        }
    }

    /// What sits on top of the picture and must not be written over: the legend, the buttons, the callout.
    private var labelKeepOut: [CGRect] {
        var areas: [CGRect] = []
        if !legend.isEmpty {
            areas.append(CGRect(x: 0, y: 0, width: viewSize.width, height: legendHeight + HV.Space.s * 2))
        }
        if selection == nil {
            // Three 44pt buttons and their rules, with the screen's margin round them.
            let width = 44 + HV.Space.s * 2
            let height = 3 * 44 + 2 + HV.Space.s * 2
            areas.append(CGRect(x: viewSize.width - width, y: viewSize.height - height, width: width, height: height))
        } else {
            areas.append(CGRect(x: 0, y: viewSize.height - 88, width: viewSize.width, height: 88))
        }
        return areas
    }

    private var hubIDs: Set<String> {
        let ranked = model.nodes
            .map { ($0.id, model.degree(of: $0.id)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(hubLabelCount)
        return Set(ranked.map { $0.0 })
    }

    // MARK: Chrome

    private var legendBar: some View {
        MemoryFlowLayout(spacing: 6) {
            ForEach(legend) { item in
                HStack(spacing: 5) {
                    ForceGraphShapeView(shape: item.shape, color: item.color)
                        .frame(width: 9, height: 9)
                    Text(item.title)
                        .font(.system(.caption2, weight: .semibold))
                        .foregroundStyle(Palette.textSecondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .hvGlass(in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: ForceGraphLegendHeightKey.self, value: proxy.size.height)
            }
        }
        .onPreferenceChange(ForceGraphLegendHeightKey.self) { legendHeight = $0 }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var controlsIfIdle: some View {
        if selection == nil { controls }
    }

    private var controls: some View {
        VStack(spacing: 0) {
            controlButton("plus", label: "Zoom in") { zoom(by: 1.4) }
            Divider().frame(width: 28)
            controlButton("minus", label: "Zoom out") { zoom(by: 1 / 1.4) }
            Divider().frame(width: 28)
            controlButton("arrow.up.left.and.down.right.magnifyingglass", label: "Fit the whole graph") {
                camera.userMoved = false
                fit(animated: true)
            }
        }
        .hvGlass(radius: 22)
        .fixedSize()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(HV.Space.s)
    }

    private func controlButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var selectedNode: ForceGraphNode? {
        guard let selection else { return nil }
        return model.nodes.first { $0.id == selection }
    }

    private func callout(for node: ForceGraphNode) -> some View {
        HStack(spacing: HV.Space.s) {
            ForceGraphShapeView(shape: node.shape, color: node.color)
                .frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.label)
                    .font(.hvHeadline)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                let links = model.degree(of: node.id)
                Text([node.detail, links == 1 ? "1 connection" : "\(links) connections"].compactMap { $0 }.joined(separator: " \u{00B7} "))
                    .font(.hvCaption)
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer(minLength: HV.Space.xs)
            Button {
                Haptics.tap()
                onOpen(node.id)
            } label: {
                Text("Open")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, HV.Space.m)
                    .frame(minHeight: 44)
                    .background(Palette.softGradient, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, HV.Space.m)
        .padding(.vertical, HV.Space.xs)
        .hvGlass(radius: 24)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .frame(maxWidth: 520)
    }

    // MARK: Camera

    private func refresh() {
        model.update(nodes: nodes, edges: edges, reduceMotion: reduceMotion)
        if let selection, !nodes.contains(where: { $0.id == selection }) { self.selection = nil }
        if !camera.userMoved { fit(animated: false) }
    }

    /// The camera that puts the whole graph in the open part of the screen: below the legend, clear of
    /// the buttons, with room under the lowest node for its name.
    private func fittedCamera() -> ForceGraphCamera? {
        guard viewSize.width > 0, viewSize.height > 0, let bounds = model.bounds else { return nil }
        let top: CGFloat = legend.isEmpty ? 32 : (legendHeight > 0 ? legendHeight + HV.Space.s * 2 + 24 : 84)
        let bottom: CGFloat = 56
        let leading: CGFloat = 36
        let trailing: CGFloat = 68
        let width = max(CGFloat(bounds.width), 1)
        let height = max(CGFloat(bounds.height), 1)
        let availableWidth = max(viewSize.width - leading - trailing, 60)
        let availableHeight = max(viewSize.height - top - bottom, 60)
        let scale = max(min(availableWidth / width, availableHeight / height, 2.2), 0.05)
        let center = bounds.center
        return ForceGraphCamera(
            scale: scale,
            translation: CGSize(
                width: leading + availableWidth / 2 - CGFloat(center.x) * scale,
                height: top + availableHeight / 2 - CGFloat(center.y) * scale
            ),
            userMoved: false
        )
    }

    private func fit(animated: Bool) {
        guard let fitted = fittedCamera() else { return }
        if animated {
            animate(to: fitted)
        } else {
            cameraTask?.cancel()
            camera = fitted
        }
    }

    /// One step towards the framing, taken as the layout moves. Easing keeps the picture from twitching.
    private func follow() {
        guard let fitted = fittedCamera() else { return }
        cameraTask?.cancel()
        guard !reduceMotion else {
            camera = fitted
            return
        }
        let ease: CGFloat = 0.3
        camera = ForceGraphCamera(
            scale: camera.scale + (fitted.scale - camera.scale) * ease,
            translation: CGSize(
                width: camera.translation.width + (fitted.translation.width - camera.translation.width) * ease,
                height: camera.translation.height + (fitted.translation.height - camera.translation.height) * ease
            ),
            userMoved: false
        )
    }

    /// Eases the camera to a new framing. A Canvas does not animate by itself, so the steps are taken here.
    private func animate(to target: ForceGraphCamera) {
        cameraTask?.cancel()
        guard !reduceMotion else {
            camera = target
            return
        }
        let start = camera
        cameraTask = Task { @MainActor in
            let steps = 16
            for step in 1...steps {
                if Task.isCancelled { return }
                let t = Double(step) / Double(steps)
                let eased = CGFloat(1 - pow(1 - t, 3))
                camera = ForceGraphCamera(
                    scale: start.scale + (target.scale - start.scale) * eased,
                    translation: CGSize(
                        width: start.translation.width + (target.translation.width - start.translation.width) * eased,
                        height: start.translation.height + (target.translation.height - start.translation.height) * eased
                    ),
                    userMoved: target.userMoved
                )
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            camera = target
        }
    }

    private func zoom(by factor: CGFloat) {
        let anchor = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let next = min(max(camera.scale * factor, 0.2), 6)
        let world = camera.world(anchor)
        var moved = camera
        moved.scale = next
        moved.translation = CGSize(width: anchor.x - CGFloat(world.x) * next, height: anchor.y - CGFloat(world.y) * next)
        moved.userMoved = true
        animate(to: moved)
    }

    // MARK: Gestures

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in dragChanged(value) }
            .onEnded { value in dragEnded(value) }
    }

    private func pinchGesture(in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                cameraTask?.cancel()
                let start = pinchStart ?? camera
                if pinchStart == nil { pinchStart = camera }
                let next = min(max(start.scale * value.magnification, 0.2), 6)
                let anchor = CGPoint(x: value.startAnchor.x * size.width, y: value.startAnchor.y * size.height)
                let world = start.world(anchor)
                camera = ForceGraphCamera(
                    scale: next,
                    translation: CGSize(width: anchor.x - CGFloat(world.x) * next, height: anchor.y - CGFloat(world.y) * next),
                    userMoved: true
                )
            }
            .onEnded { _ in pinchStart = nil }
    }

    private func dragChanged(_ value: DragGesture.Value) {
        cameraTask?.cancel()
        let moved = hypot(value.translation.width, value.translation.height)
        if drag == .undecided {
            dragStart = camera.translation
            if let id = hitNode(at: value.startLocation) {
                drag = .node(id)
            } else {
                drag = .pan
            }
        }
        switch drag {
        case .node(let id):
            if moved > 6 {
                camera.userMoved = true
                model.drag(id, to: camera.world(value.location))
            }
        case .pan:
            if moved > 3 {
                camera.translation = CGSize(width: dragStart.width + value.translation.width, height: dragStart.height + value.translation.height)
                camera.userMoved = true
            }
        case .undecided:
            break
        }
    }

    private func dragEnded(_ value: DragGesture.Value) {
        let moved = hypot(value.translation.width, value.translation.height)
        switch drag {
        case .node(let id):
            if moved > 6 {
                model.endDrag(id)
            } else {
                tapped(id)
            }
        case .pan:
            if moved <= 6, selection != nil {
                HV.Motion.animate(.easeOut(duration: 0.15)) { selection = nil }
            }
        case .undecided:
            break
        }
        drag = .undecided
    }

    private func tapped(_ id: String) {
        Haptics.select()
        if selection == id {
            onOpen(id)
        } else {
            HV.Motion.animate(.easeOut(duration: 0.18)) { selection = id }
        }
    }

    /// The node under a finger: the nearest one within a thumb's reach.
    private func hitNode(at location: CGPoint) -> String? {
        let points = model.points
        var best: (id: String, distance: CGFloat)?
        for (index, node) in model.nodes.enumerated() where index < points.count {
            let center = camera.screen(points[index])
            let reach = max(ForceGraphRenderer.radius(for: node, scale: camera.scale), 22)
            let distance = hypot(center.x - location.x, center.y - location.y)
            if distance <= reach, distance < (best?.distance ?? .infinity) { best = (node.id, distance) }
        }
        return best?.id
    }
}

/// Draws the graph into a Canvas.
enum ForceGraphRenderer {
    static func radius(for node: ForceGraphNode, scale: CGFloat) -> CGFloat {
        let base = 4.5 + 2.4 * CGFloat(node.weight).squareRoot()
        return base * min(max(scale.squareRoot(), 0.75), 1.6)
    }

    /// How far in from the edge of the canvas a name may go.
    private static let labelMargin = CGSize(width: 12, height: 8)
    /// The selected node's name goes first and is always drawn.
    private static let selectedPriority = 1000

    /// Links, then nodes, then names. A name goes where nothing is in the way (see `ForceLabelPlacer`) and
    /// sits on a soft backing of the page's own color, so a link that passes under it does not cut the text.
    static func draw(
        into context: inout GraphicsContext, size: CGSize, nodes: [ForceGraphNode], edges: [ForceGraphEdge],
        points: [ForcePoint], camera: ForceGraphCamera, selection: String?, focus: Set<String>, hubs: Set<String>,
        keepOut: [CGRect] = []
    ) {
        guard points.count == nodes.count else { return }
        var index: [String: Int] = [:]
        for (i, node) in nodes.enumerated() { index[node.id] = i }
        let dimmed = selection != nil
        let canvas = CGRect(origin: .zero, size: size)

        // Links sit under everything, strong enough to follow with the eye in both looks.
        var segments: [ForceLabelPlacer.Segment] = []
        var degree: [String: Int] = [:]
        for edge in edges {
            guard let a = index[edge.source], let b = index[edge.target] else { continue }
            degree[edge.source, default: 0] += 1
            degree[edge.target, default: 0] += 1
            let from = camera.screen(points[a])
            let to = camera.screen(points[b])
            let involved = !dimmed || (focus.contains(edge.source) && focus.contains(edge.target) && (edge.source == selection || edge.target == selection))
            var path = Path()
            path.move(to: from)
            path.addLine(to: to)
            let opacity: Double = involved ? (edge.isStrong ? 0.95 : 0.7) : 0.1
            let style = StrokeStyle(lineWidth: edge.isStrong ? 1.8 : 1.1, lineCap: .round)
            context.stroke(path, with: .color(Palette.textSecondary.opacity(opacity)), style: style)
            let segment = ForceLabelPlacer.Segment(from: from, to: to)
            if involved, ForceLabelPlacer.intersects(segment, canvas) { segments.append(segment) }
        }

        // Nodes, each with a ring of page color so the links seem to stop at it.
        var obstacles: [ForceLabelPlacer.Obstacle] = []
        var reaches: [String: CGFloat] = [:]
        for (i, node) in nodes.enumerated() {
            let center = camera.screen(points[i])
            if center.x < -30 || center.y < -30 || center.x > size.width + 30 || center.y > size.height + 30 { continue }
            let r = radius(for: node, scale: camera.scale)
            let faded = dimmed && !focus.contains(node.id)
            let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
            let shape = shapePath(node.shape, in: rect)
            context.stroke(shape, with: .color(Palette.background), lineWidth: 3)
            context.fill(shape, with: .color(node.color.opacity(faded ? 0.25 : 1)))
            var reach = r
            if node.id == selection {
                let ring = shapePath(node.shape, in: rect.insetBy(dx: -4, dy: -4))
                context.stroke(ring, with: .color(Palette.textPrimary), lineWidth: 2)
                reach += 5
            }
            reaches[node.id] = reach
            obstacles.append(ForceLabelPlacer.Obstacle(id: node.id, rect: CGRect(x: center.x - reach, y: center.y - reach, width: reach * 2, height: reach * 2)))
        }

        // Names: the selected node and its neighbours first, then the best connected (the better connected
        // first among them, so the busiest nodes get the room), then (zoomed in) everything. One that has
        // nowhere clear to go is left out.
        let showAll = camera.scale > 1.7
        var requests: [ForceLabelPlacer.Request] = []
        var resolved: [String: GraphicsContext.ResolvedText] = [:]
        for (i, node) in nodes.enumerated() {
            let links = min(degree[node.id] ?? 0, 99)
            let priority: Int
            if node.id == selection {
                priority = Self.selectedPriority
            } else if dimmed {
                guard focus.contains(node.id) else { continue }
                priority = 500 + links
            } else if hubs.contains(node.id) {
                priority = 200 + links
            } else if showAll {
                priority = links
            } else {
                continue
            }
            let center = camera.screen(points[i])
            guard canvas.contains(center), let reach = reaches[node.id] else { continue }
            let text = Text(truncated(node.label))
                .font(.system(size: 11, weight: priority >= 500 ? .semibold : .medium))
                .foregroundStyle(Palette.textPrimary)
            let label = context.resolve(text)
            resolved[node.id] = label
            requests.append(ForceLabelPlacer.Request(
                id: node.id, center: center, radius: reach,
                size: label.measure(in: CGSize(width: 220, height: 40)), priority: priority, isRequired: priority == Self.selectedPriority
            ))
        }
        let placements = ForceLabelPlacer.place(
            requests, nodes: obstacles, links: segments,
            options: ForceLabelPlacer.Options(bounds: canvas.insetBy(dx: labelMargin.width, dy: labelMargin.height), keepOut: keepOut)
        )
        for placement in placements {
            guard let label = resolved[placement.id] else { continue }
            let backing = placement.frame.insetBy(dx: -4, dy: -2)
            context.fill(Path(roundedRect: backing, cornerRadius: 5), with: .color(Palette.background.opacity(0.9)))
            context.draw(label, at: CGPoint(x: placement.frame.midX, y: placement.frame.midY), anchor: .center)
        }
    }

    private static func truncated(_ label: String) -> String {
        label.count > 26 ? String(label.prefix(25)) + "\u{2026}" : label
    }

    static func shapePath(_ shape: ForceGraphNode.Shape, in rect: CGRect) -> Path {
        switch shape {
        case .circle:
            return Path(ellipseIn: rect)
        case .square:
            return Path(roundedRect: rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.08), cornerRadius: rect.width * 0.2)
        case .diamond:
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.08))
            path.addLine(to: CGPoint(x: rect.maxX + rect.width * 0.08, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY + rect.height * 0.08))
            path.addLine(to: CGPoint(x: rect.minX - rect.width * 0.08, y: rect.midY))
            path.closeSubpath()
            return path
        }
    }
}

/// A node's shape as a small view, for the legend and the callout.
struct ForceGraphShapeView: View {
    let shape: ForceGraphNode.Shape
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ForceGraphRenderer.shapePath(shape, in: CGRect(origin: .zero, size: proxy.size).insetBy(dx: 1, dy: 1))
                .fill(color)
        }
        .accessibilityHidden(true)
    }
}
