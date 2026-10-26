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
    @State private var cameraTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                canvas
                    .contentShape(Rectangle())
                    .gesture(dragGesture)
                    .simultaneousGesture(pinchGesture(in: proxy.size))
                    .accessibilityHidden(true)
                VStack(spacing: 0) {
                    if !legend.isEmpty { legendBar }
                    Spacer(minLength: 0)
                    if let node = selectedNode { callout(for: node) }
                }
                .padding(HV.Space.s)
                controls
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
        .onChange(of: model.isSimulating) { _, running in
            if !running, !camera.userMoved { fit(animated: true) }
        }
        .onDisappear { model.stop() }
        .accessibilityChildren {
            ForEach(nodes) { node in
                Button(node.label) { onOpen(node.id) }
                    .accessibilityHint("\(model.degree(of: node.id)) connections. Opens it.")
            }
        }
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
        return Canvas { context, size in
            ForceGraphRenderer.draw(
                into: &context, size: size, nodes: drawn, edges: drawnEdges, points: points,
                camera: camera, selection: selection, focus: focus, hubs: hubs
            )
        }
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
                        .font(.system(.caption2, design: .rounded, weight: .semibold))
                        .foregroundStyle(Palette.textSecondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
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
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
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

    private func fit(animated: Bool) {
        guard viewSize.width > 0, viewSize.height > 0, let bounds = model.bounds else { return }
        let padding: CGFloat = 44
        let width = max(CGFloat(bounds.width), 1)
        let height = max(CGFloat(bounds.height), 1)
        let scale = min((viewSize.width - padding * 2) / width, (viewSize.height - padding * 2 - 60) / height, 2.2)
        let center = bounds.center
        let fitted = ForceGraphCamera(
            scale: max(scale, 0.05),
            translation: CGSize(
                width: viewSize.width / 2 - CGFloat(center.x) * max(scale, 0.05),
                height: viewSize.height / 2 - CGFloat(center.y) * max(scale, 0.05) - 10
            ),
            userMoved: false
        )
        if animated {
            animate(to: fitted)
        } else {
            cameraTask?.cancel()
            camera = fitted
        }
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
                withAnimation(.easeOut(duration: 0.15)) { selection = nil }
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
            withAnimation(.easeOut(duration: 0.18)) { selection = id }
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

    static func draw(
        into context: inout GraphicsContext, size: CGSize, nodes: [ForceGraphNode], edges: [ForceGraphEdge],
        points: [ForcePoint], camera: ForceGraphCamera, selection: String?, focus: Set<String>, hubs: Set<String>
    ) {
        guard points.count == nodes.count else { return }
        var index: [String: Int] = [:]
        for (i, node) in nodes.enumerated() { index[node.id] = i }
        let dimmed = selection != nil

        for edge in edges {
            guard let a = index[edge.source], let b = index[edge.target] else { continue }
            let involved = !dimmed || (focus.contains(edge.source) && focus.contains(edge.target) && (edge.source == selection || edge.target == selection))
            var path = Path()
            path.move(to: camera.screen(points[a]))
            path.addLine(to: camera.screen(points[b]))
            let opacity: Double = involved ? (edge.isStrong ? 0.75 : 0.45) : 0.08
            let style = StrokeStyle(lineWidth: edge.isStrong ? 1.6 : 0.9, lineCap: .round)
            context.stroke(path, with: .color(Palette.textSecondary.opacity(opacity)), style: style)
        }

        for (i, node) in nodes.enumerated() {
            let center = camera.screen(points[i])
            if center.x < -30 || center.y < -30 || center.x > size.width + 30 || center.y > size.height + 30 { continue }
            let r = radius(for: node, scale: camera.scale)
            let faded = dimmed && !focus.contains(node.id)
            let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
            let shape = shapePath(node.shape, in: rect)
            context.fill(shape, with: .color(node.color.opacity(faded ? 0.22 : 0.95)))
            if node.id == selection {
                let ring = shapePath(node.shape, in: rect.insetBy(dx: -4, dy: -4))
                context.stroke(ring, with: .color(Palette.textPrimary), lineWidth: 2)
            }
        }

        let showAll = camera.scale > 1.7
        for (i, node) in nodes.enumerated() {
            let isFocus = node.id == selection || (dimmed && focus.contains(node.id))
            guard isFocus || hubs.contains(node.id) || showAll else { continue }
            if dimmed, !focus.contains(node.id) { continue }
            let center = camera.screen(points[i])
            if center.x < 0 || center.y < 0 || center.x > size.width || center.y > size.height { continue }
            let r = radius(for: node, scale: camera.scale)
            let text = Text(truncated(node.label))
                .font(.system(size: 11, weight: isFocus ? .semibold : .medium, design: .rounded))
                .foregroundStyle(Palette.textPrimary)
            context.draw(text, at: CGPoint(x: center.x, y: center.y + r + 3), anchor: .top)
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
