import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// Where the names go on a force graph. It works in screen points and knows nothing about drawing:
// the caller says where each node is, how big its name is, and what else is on the screen, and gets
// back a frame for every name that has a clear place. A name that has none is left out, because a
// name on top of another node or cut off at the edge of the screen says less than no name.

public enum ForceLabelPlacer {
    /// A name that wants a place.
    public struct Request: Sendable {
        public var id: String
        /// The centre of the node it names.
        public var center: CGPoint
        /// How far the node reaches from its centre, ring included.
        public var radius: CGFloat
        /// The size of the text on its own.
        public var size: CGSize
        /// Higher goes first and wins a contested place.
        public var priority: Int
        /// A name that is drawn even when it has to overlap something (the selected node's).
        public var isRequired: Bool

        public init(id: String, center: CGPoint, radius: CGFloat, size: CGSize, priority: Int = 0, isRequired: Bool = false) {
            self.id = id
            self.center = center
            self.radius = radius
            self.size = size
            self.priority = priority
            self.isRequired = isRequired
        }
    }

    /// A node as something a name must not cover.
    public struct Obstacle: Sendable {
        public var id: String
        public var rect: CGRect

        public init(id: String, rect: CGRect) {
            self.id = id
            self.rect = rect
        }
    }

    /// A link, as the line it is drawn along.
    public struct Segment: Sendable {
        public var from: CGPoint
        public var to: CGPoint

        public init(from: CGPoint, to: CGPoint) {
            self.from = from
            self.to = to
        }
    }

    public struct Options: Sendable {
        /// Names stay inside this rectangle.
        public var bounds: CGRect
        /// Places that belong to something else (a legend, a row of buttons).
        public var keepOut: [CGRect]
        /// Space between a node and its name.
        public var gap: CGFloat
        /// Room kept clear around the text, which is also where a backing for it is drawn.
        public var padding: CGSize
        /// Room kept clear around every other node.
        public var nodePadding: CGFloat
        /// A name that would have this many links running through it, or more, is left out.
        public var crossingLimit: Int

        public init(
            bounds: CGRect, keepOut: [CGRect] = [], gap: CGFloat = 3, padding: CGSize = CGSize(width: 4, height: 2),
            nodePadding: CGFloat = 3, crossingLimit: Int = 3
        ) {
            self.bounds = bounds
            self.keepOut = keepOut
            self.gap = gap
            self.padding = padding
            self.nodePadding = nodePadding
            self.crossingLimit = crossingLimit
        }
    }

    public enum Side: Sendable, CaseIterable {
        case below, above, trailing, leading
    }

    public struct Placement: Sendable {
        public var id: String
        /// Where the text goes.
        public var frame: CGRect
        public var side: Side
    }

    /// Places the names, the highest priority first. The result is in that order.
    public static func place(_ requests: [Request], nodes: [Obstacle], links: [Segment], options: Options) -> [Placement] {
        let ordered = requests.enumerated()
            .sorted { $0.element.priority != $1.element.priority ? $0.element.priority > $1.element.priority : $0.offset < $1.offset }
            .map(\.element)
        let wide = options.bounds
        let blocks = nodes.map { Obstacle(id: $0.id, rect: $0.rect.insetBy(dx: -options.nodePadding, dy: -options.nodePadding)) }

        var placed: [Placement] = []
        var taken: [CGRect] = []
        for request in ordered {
            var best: (placement: Placement, score: Int)?
            for (index, side) in Side.allCases.enumerated() {
                guard let frame = candidate(for: request, side: side, options: options) else { continue }
                let padded = frame.insetBy(dx: -options.padding.width, dy: -options.padding.height)
                guard wide.contains(padded) else { continue }
                if taken.contains(where: { $0.intersects(padded) }) { continue }
                if options.keepOut.contains(where: { $0.intersects(padded) }) { continue }
                if blocks.contains(where: { $0.id != request.id && $0.rect.intersects(padded) }) { continue }
                let crossings = links.reduce(0) { $0 + (intersects($1, padded) ? 1 : 0) }
                if crossings >= options.crossingLimit, !request.isRequired { continue }
                let score = crossings * 100 + index
                if best == nil || score < best!.score {
                    best = (Placement(id: request.id, frame: frame, side: side), score)
                }
            }
            if let best {
                placed.append(best.placement)
                taken.append(best.placement.frame.insetBy(dx: -options.padding.width, dy: -options.padding.height))
            } else if request.isRequired {
                // Overlapping is better than a selected node with no name.
                let fallback = clamped(
                    candidate(for: request, side: .below, options: options, clampX: false) ?? .zero,
                    into: wide, padding: options.padding
                )
                placed.append(Placement(id: request.id, frame: fallback, side: .below))
                taken.append(fallback.insetBy(dx: -options.padding.width, dy: -options.padding.height))
            }
        }
        return placed
    }

    // MARK: Geometry

    /// The text's frame on one side of its node, slid along the node to stay inside the bounds, or nil
    /// when sliding would leave the node standing off to one side of its own name.
    static func candidate(for request: Request, side: Side, options: Options, clampX: Bool = true) -> CGRect? {
        let width = request.size.width
        let height = request.size.height
        let reach = request.radius + options.gap
        let center = request.center
        switch side {
        case .below, .above:
            var x = center.x - width / 2
            if clampX {
                let low = options.bounds.minX + options.padding.width
                let high = options.bounds.maxX - options.padding.width - width
                guard low <= high else { return nil }
                x = min(max(x, low), high)
                // The node has to stay over the name, not past the end of it.
                let hold = min(width / 4, 14)
                guard center.x >= x + hold, center.x <= x + width - hold else { return nil }
            }
            let y = side == .below ? center.y + reach : center.y - reach - height
            return CGRect(x: x, y: y, width: width, height: height)
        case .trailing:
            return CGRect(x: center.x + reach, y: center.y - height / 2, width: width, height: height)
        case .leading:
            return CGRect(x: center.x - reach - width, y: center.y - height / 2, width: width, height: height)
        }
    }

    private static func clamped(_ frame: CGRect, into bounds: CGRect, padding: CGSize) -> CGRect {
        var out = frame
        out.origin.x = min(max(out.origin.x, bounds.minX + padding.width), max(bounds.maxX - padding.width - out.width, bounds.minX + padding.width))
        out.origin.y = min(max(out.origin.y, bounds.minY + padding.height), max(bounds.maxY - padding.height - out.height, bounds.minY + padding.height))
        return out
    }

    /// Whether a line passes through a rectangle (Liang-Barsky).
    public static func intersects(_ segment: Segment, _ rect: CGRect) -> Bool {
        let x0 = Double(segment.from.x), y0 = Double(segment.from.y)
        let dx = Double(segment.to.x) - x0, dy = Double(segment.to.y) - y0
        var enter = 0.0, leave = 1.0
        func clip(_ p: Double, _ q: Double) -> Bool {
            if p == 0 { return q >= 0 }
            let t = q / p
            if p < 0 {
                if t > leave { return false }
                enter = max(enter, t)
            } else {
                if t < enter { return false }
                leave = min(leave, t)
            }
            return true
        }
        return clip(-dx, x0 - Double(rect.minX)) && clip(dx, Double(rect.maxX) - x0)
            && clip(-dy, y0 - Double(rect.minY)) && clip(dy, Double(rect.maxY) - y0)
    }
}
