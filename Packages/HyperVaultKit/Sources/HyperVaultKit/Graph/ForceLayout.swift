import Foundation

// A small force-directed layout for graphs of up to a few hundred nodes: the
// Memory graph today, the Library's artifacts later. It knows nothing about
// what a node is. Everything it does is deterministic: the same nodes, edges
// and seed give the same picture, on every device and in every test run.

public struct ForcePoint: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = ForcePoint(x: 0, y: 0)

    public func distance(to other: ForcePoint) -> Double {
        ((x - other.x) * (x - other.x) + (y - other.y) * (y - other.y)).squareRoot()
    }
}

public struct ForceNode: Sendable, Hashable, Identifiable {
    public let id: String
    /// How heavy the node is: heavier nodes are bigger and push harder. Positive.
    public var weight: Double
    /// A fixed node does not move under the forces (a pinned or dragged node).
    public var isFixed: Bool
    /// Where the node starts, or sits when it is fixed. Nil lets the layout choose.
    public var position: ForcePoint?

    public init(id: String, weight: Double = 1, isFixed: Bool = false, position: ForcePoint? = nil) {
        self.id = id
        self.weight = weight.isFinite && weight > 0 ? weight : 1
        self.isFixed = isFixed
        self.position = position
    }
}

public struct ForceEdge: Sendable, Hashable {
    public let source: String
    public let target: String
    /// 1 is an ordinary link; a stronger one pulls its ends closer.
    public var strength: Double

    public init(source: String, target: String, strength: Double = 1) {
        self.source = source
        self.target = target
        self.strength = strength.isFinite && strength > 0 ? strength : 1
    }
}

public struct ForceConfiguration: Sendable, Equatable {
    /// Same seed, same layout.
    public var seed: UInt64 = 7
    /// The length a link settles at.
    public var linkDistance = 56.0
    public var linkStrength = 1.0
    /// How hard nodes push each other apart, and how far the push reaches.
    public var repulsion = 60.0
    public var repulsionRange = 700.0
    /// A pull towards the middle, so unconnected pieces do not drift away.
    public var gravity = 0.03
    public var collisionPadding = 3.0
    /// The share of speed lost every tick.
    public var velocityDecay = 0.4
    public var alphaDecay = 0.014
    public var alphaMin = 0.001
    public var maxSpeed = 80.0

    public init() {}

    /// The radius a node of `weight` takes up.
    public func radius(forWeight weight: Double) -> Double {
        5 + 2.2 * weight.squareRoot()
    }
}

public struct ForceBounds: Sendable, Equatable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }
    public var center: ForcePoint { ForcePoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2) }
}

/// A seeded generator (SplitMix64): the layout's only source of randomness.
struct ForceRandom: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 0..<1
    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    /// A tiny nudge, to pull apart two nodes that sit on the same spot.
    mutating func jiggle() -> Double {
        (unit() - 0.5) * 1e-3
    }
}

public struct ForceLayout: Sendable {
    public private(set) var nodes: [ForceNode]
    public private(set) var edges: [ForceEdge]
    public let configuration: ForceConfiguration
    /// The simulation's heat: 1 at the start, falling towards zero as it settles.
    public private(set) var alpha = 1.0
    /// Holding this above zero keeps the layout moving (a node being dragged).
    public var alphaTarget = 0.0

    private var xs: [Double] = []
    private var ys: [Double] = []
    private var vxs: [Double] = []
    private var vys: [Double] = []
    private var index: [String: Int] = [:]
    private var links: [(source: Int, target: Int, strength: Double)] = []
    private var degrees: [Int] = []
    private var random: ForceRandom

    public init(nodes: [ForceNode], edges: [ForceEdge] = [], configuration: ForceConfiguration = ForceConfiguration()) {
        self.nodes = []
        self.edges = []
        self.configuration = configuration
        self.random = ForceRandom(seed: configuration.seed)
        load(nodes: nodes, edges: edges, keepingPositions: false)
    }

    // MARK: Reading

    public var isSettled: Bool { alpha < configuration.alphaMin && alphaTarget <= 0 }

    /// Positions in node order.
    public var points: [ForcePoint] {
        (0..<nodes.count).map { ForcePoint(x: xs[$0], y: ys[$0]) }
    }

    public var positions: [String: ForcePoint] {
        Dictionary(uniqueKeysWithValues: nodes.indices.map { (nodes[$0].id, ForcePoint(x: xs[$0], y: ys[$0])) })
    }

    public func point(for id: String) -> ForcePoint? {
        guard let i = index[id] else { return nil }
        return ForcePoint(x: xs[i], y: ys[i])
    }

    public func degree(of id: String) -> Int {
        guard let i = index[id] else { return 0 }
        return degrees[i]
    }

    public var bounds: ForceBounds? {
        guard !nodes.isEmpty else { return nil }
        return ForceBounds(minX: xs.min() ?? 0, minY: ys.min() ?? 0, maxX: xs.max() ?? 0, maxY: ys.max() ?? 0)
    }

    /// The fastest any node is moving: near zero once the layout has settled.
    public var peakSpeed: Double {
        var peak = 0.0
        for i in nodes.indices { peak = max(peak, (vxs[i] * vxs[i] + vys[i] * vys[i]).squareRoot()) }
        return peak
    }

    // MARK: Stepping

    /// One step of the simulation.
    public mutating func tick() {
        let count = nodes.count
        guard count > 0 else {
            alpha = 0
            return
        }
        alpha += (alphaTarget - alpha) * configuration.alphaDecay

        applyLinks()
        applyRepulsion()
        for i in 0..<count {
            vxs[i] -= xs[i] * configuration.gravity * alpha
            vys[i] -= ys[i] * configuration.gravity * alpha
        }
        integrate()
        resolveCollisions()
    }

    /// Steps until the layout settles or `maxTicks` is reached. Returns how many steps it took.
    @discardableResult
    public mutating func run(maxTicks: Int = 600) -> Int {
        if nodes.isEmpty {
            alpha = 0
            return 0
        }
        var ticks = 0
        while ticks < maxTicks && !isSettled {
            tick()
            ticks += 1
        }
        return ticks
    }

    /// Warms the layout up again, for a drag or a change to the graph.
    public mutating func reheat(_ heat: Double = 0.4) {
        alpha = max(alpha, min(max(heat, 0), 1))
    }

    // MARK: Pinning

    /// Holds a node at a point (a finger on it).
    public mutating func pin(_ id: String, at point: ForcePoint) {
        guard let i = index[id], point.x.isFinite, point.y.isFinite else { return }
        nodes[i].isFixed = true
        nodes[i].position = point
        xs[i] = point.x
        ys[i] = point.y
        vxs[i] = 0
        vys[i] = 0
    }

    /// Lets a node move under the forces again.
    public mutating func release(_ id: String) {
        guard let i = index[id] else { return }
        nodes[i].isFixed = false
    }

    // MARK: Changing the graph

    /// Swaps in a new set of nodes and edges. Nodes that were there stay where
    /// they are, and new ones start beside a neighbour they link to, so the
    /// picture changes by growing rather than by being redrawn.
    public mutating func update(nodes newNodes: [ForceNode], edges newEdges: [ForceEdge]) {
        load(nodes: newNodes, edges: newEdges, keepingPositions: true)
        reheat(0.3)
    }

    // MARK: Internals

    private mutating func load(nodes newNodes: [ForceNode], edges newEdges: [ForceEdge], keepingPositions: Bool) {
        let previous: [String: (x: Double, y: Double, vx: Double, vy: Double)] = keepingPositions
            ? Dictionary(uniqueKeysWithValues: nodes.indices.map { (nodes[$0].id, (xs[$0], ys[$0], vxs[$0], vys[$0])) })
            : [:]

        // One node per id: the first wins.
        var seen = Set<String>()
        let unique = newNodes.filter { seen.insert($0.id).inserted }
        nodes = unique
        index = Dictionary(uniqueKeysWithValues: unique.enumerated().map { ($1.id, $0) })

        // Edges between nodes that exist; no loops, no repeats.
        var pairs = Set<String>()
        var kept: [ForceEdge] = []
        for edge in newEdges {
            guard edge.source != edge.target, index[edge.source] != nil, index[edge.target] != nil else { continue }
            let key = edge.source < edge.target ? "\(edge.source)\u{0}\(edge.target)" : "\(edge.target)\u{0}\(edge.source)"
            if pairs.insert(key).inserted { kept.append(edge) }
        }
        edges = kept
        links = kept.compactMap { edge in
            guard let s = index[edge.source], let t = index[edge.target] else { return nil }
            return (s, t, edge.strength)
        }
        degrees = Array(repeating: 0, count: unique.count)
        for link in links {
            degrees[link.source] += 1
            degrees[link.target] += 1
        }

        let count = unique.count
        xs = Array(repeating: 0, count: count)
        ys = Array(repeating: 0, count: count)
        vxs = Array(repeating: 0, count: count)
        vys = Array(repeating: 0, count: count)

        // Neighbours by index, to place newcomers beside someone they link to.
        var neighbours = Array(repeating: [Int](), count: count)
        for link in links {
            neighbours[link.source].append(link.target)
            neighbours[link.target].append(link.source)
        }
        let goldenAngle = Double.pi * (3 - 5.0.squareRoot())
        let phase = Double(configuration.seed % 360) * Double.pi / 180

        var placed = Array(repeating: false, count: count)
        for (i, node) in unique.enumerated() {
            if let position = node.position, position.x.isFinite, position.y.isFinite {
                xs[i] = position.x
                ys[i] = position.y
                placed[i] = true
            } else if let old = previous[node.id] {
                xs[i] = old.x
                ys[i] = old.y
                vxs[i] = old.vx
                vys[i] = old.vy
                placed[i] = true
            }
        }
        for i in 0..<count where !placed[i] {
            let anchors = neighbours[i].filter { placed[$0] }
            if keepingPositions, !anchors.isEmpty {
                let mx = anchors.map { xs[$0] }.reduce(0, +) / Double(anchors.count)
                let my = anchors.map { ys[$0] }.reduce(0, +) / Double(anchors.count)
                let angle = random.unit() * 2 * Double.pi
                xs[i] = mx + cos(angle) * configuration.linkDistance * 0.6
                ys[i] = my + sin(angle) * configuration.linkDistance * 0.6
            } else {
                // A sunflower spiral: even coverage with nothing random in it.
                let radius = 12 * (0.5 + Double(i)).squareRoot()
                let angle = Double(i) * goldenAngle + phase
                xs[i] = radius * cos(angle)
                ys[i] = radius * sin(angle)
            }
            placed[i] = true
        }
        for i in 0..<count where nodes[i].isFixed { vxs[i] = 0; vys[i] = 0 }
    }

    private mutating func applyLinks() {
        for link in links {
            let s = link.source
            let t = link.target
            var dx = xs[t] + vxs[t] - xs[s] - vxs[s]
            var dy = ys[t] + vys[t] - ys[s] - vys[s]
            if dx == 0 { dx = random.jiggle() }
            if dy == 0 { dy = random.jiggle() }
            let length = (dx * dx + dy * dy).squareRoot()
            // Like d3: a link between two well-connected nodes pulls less than one to a leaf.
            let share = configuration.linkStrength * link.strength / Double(max(1, min(degrees[s], degrees[t])))
            let pull = (length - configuration.linkDistance) / length * alpha * share
            dx *= pull
            dy *= pull
            // The better connected end gives way less.
            let ds = Double(max(degrees[s], 1))
            let dt = Double(max(degrees[t], 1))
            let bias = ds / (ds + dt)
            vxs[t] -= dx * bias
            vys[t] -= dy * bias
            vxs[s] += dx * (1 - bias)
            vys[s] += dy * (1 - bias)
        }
    }

    private mutating func applyRepulsion() {
        let count = nodes.count
        guard count > 1 else { return }
        let range2 = configuration.repulsionRange * configuration.repulsionRange
        for i in 0..<(count - 1) {
            for j in (i + 1)..<count {
                var dx = xs[j] - xs[i]
                var dy = ys[j] - ys[i]
                if dx == 0 { dx = random.jiggle() }
                if dy == 0 { dy = random.jiggle() }
                let d2 = dx * dx + dy * dy
                if d2 > range2 { continue }
                let distance = max(d2, 36).squareRoot()
                // A push that fades with 1/distance keeps far-apart groups apart.
                let push = configuration.repulsion * alpha / distance * (nodes[i].weight * nodes[j].weight).squareRoot()
                let fx = dx / distance * push
                let fy = dy / distance * push
                vxs[i] -= fx
                vys[i] -= fy
                vxs[j] += fx
                vys[j] += fy
            }
        }
    }

    private mutating func integrate() {
        let keep = 1 - configuration.velocityDecay
        let limit = configuration.maxSpeed
        for i in nodes.indices {
            if nodes[i].isFixed {
                vxs[i] = 0
                vys[i] = 0
                if let position = nodes[i].position {
                    xs[i] = position.x
                    ys[i] = position.y
                }
                continue
            }
            var vx = vxs[i] * keep
            var vy = vys[i] * keep
            let speed = (vx * vx + vy * vy).squareRoot()
            if speed > limit {
                vx *= limit / speed
                vy *= limit / speed
            }
            var x = xs[i] + vx
            var y = ys[i] + vy
            if !x.isFinite || !y.isFinite || !vx.isFinite || !vy.isFinite {
                x = 0
                y = 0
                vx = 0
                vy = 0
            }
            xs[i] = max(-1e6, min(1e6, x))
            ys[i] = max(-1e6, min(1e6, y))
            vxs[i] = vx
            vys[i] = vy
        }
    }

    /// Nodes may not sit on top of each other.
    private mutating func resolveCollisions() {
        let count = nodes.count
        guard count > 1 else { return }
        let radii = nodes.map { configuration.radius(forWeight: $0.weight) + configuration.collisionPadding }
        for i in 0..<(count - 1) {
            for j in (i + 1)..<count {
                var dx = xs[j] - xs[i]
                var dy = ys[j] - ys[i]
                let reach = radii[i] + radii[j]
                if abs(dx) > reach || abs(dy) > reach { continue }
                if dx == 0 { dx = random.jiggle() }
                if dy == 0 { dy = random.jiggle() }
                let distance = (dx * dx + dy * dy).squareRoot()
                guard distance < reach else { continue }
                let overlap = (reach - distance) / distance * 0.5
                let ox = dx * overlap
                let oy = dy * overlap
                switch (nodes[i].isFixed, nodes[j].isFixed) {
                case (false, false):
                    xs[i] -= ox; ys[i] -= oy
                    xs[j] += ox; ys[j] += oy
                case (true, false):
                    xs[j] += ox * 2; ys[j] += oy * 2
                case (false, true):
                    xs[i] -= ox * 2; ys[i] -= oy * 2
                case (true, true):
                    break
                }
            }
        }
    }
}
