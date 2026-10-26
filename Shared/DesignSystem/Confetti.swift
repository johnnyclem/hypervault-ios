import SwiftUI

/// A short burst of colour for a moment worth marking: the first thing a person keeps. It plays
/// once, never loops, and does not play at all when the system is set to reduce motion.
struct ConfettiBurst: View {
    private struct Piece: Identifiable {
        let id: Int
        let angle: Double
        let speed: Double
        let spin: Double
        let size: CGFloat
        let color: Color
        let isCircle: Bool
    }

    var duration: TimeInterval = 1.6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    @State private var pieces: [Piece] = []

    var body: some View {
        Group {
            if reduceMotion {
                Color.clear
            } else {
                TimelineView(.animation) { context in
                    let t = min(1, context.date.timeIntervalSince(start) / duration)
                    Canvas { canvas, size in
                        let origin = CGPoint(x: size.width / 2, y: size.height * 0.42)
                        for piece in pieces {
                            let distance = piece.speed * easeOut(t) * min(size.width, size.height) * 0.7
                            let gravity = t * t * size.height * 0.35
                            let x = origin.x + cos(piece.angle) * distance
                            let y = origin.y + sin(piece.angle) * distance + gravity
                            var layer = canvas
                            layer.translateBy(x: x, y: y)
                            layer.rotate(by: .radians(piece.spin * t * 6))
                            let rect = CGRect(x: -piece.size / 2, y: -piece.size / 3, width: piece.size, height: piece.size * 0.66)
                            let path = piece.isCircle ? Path(ellipseIn: rect) : Path(roundedRect: rect, cornerRadius: 1.5)
                            layer.opacity = 1 - max(0, (t - 0.65) / 0.35)
                            layer.fill(path, with: .color(piece.color))
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            start = Date()
            let palette: [Color] = [Palette.violet, Palette.blue, Palette.cyan, Palette.mint, Palette.amber, Palette.rose]
            pieces = (0..<70).map { index in
                Piece(
                    id: index,
                    angle: Double.random(in: -Double.pi * 0.95 ... -Double.pi * 0.05),
                    speed: Double.random(in: 0.25...1),
                    spin: Double.random(in: -1...1),
                    size: CGFloat.random(in: 6...11),
                    color: palette[index % palette.count],
                    isCircle: index % 3 == 0
                )
            }
        }
    }

    private func easeOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
}
