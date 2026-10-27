import SwiftUI

/// Slow, quiet colour behind the first screens and the canvas. It never
/// competes with content, and it holds still for people who ask the system to
/// reduce motion.
struct AuroraBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var intensity: Double = 1

    var body: some View {
        ZStack {
            Palette.background
            if reduceMotion {
                blobs(at: 0)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { context in
                    blobs(at: context.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private var strength: Double {
        0.34 * intensity
    }

    private func blobs(at time: Double) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            ZStack {
                Circle()
                    .fill(Palette.violet.opacity(strength))
                    .frame(width: width * 0.95)
                    .blur(radius: 90)
                    .offset(x: -width * 0.32 + sin(time / 9) * 36, y: -height * 0.30 + cos(time / 11) * 28)
                Circle()
                    .fill(Palette.blue.opacity(strength * 0.9))
                    .frame(width: width * 0.85)
                    .blur(radius: 90)
                    .offset(x: width * 0.34 + cos(time / 10) * 32, y: -height * 0.18 + sin(time / 13) * 30)
                Circle()
                    .fill(Palette.cyan.opacity(strength * 0.7))
                    .frame(width: width * 0.8)
                    .blur(radius: 100)
                    .offset(x: width * 0.12 + sin(time / 12) * 30, y: height * 0.42 + cos(time / 8) * 26)
            }
            .frame(width: width, height: height)
        }
    }
}

extension View {
    /// The standard screen backdrop: flat paper.
    func hvScreenBackground() -> some View {
        background(Palette.background.ignoresSafeArea())
    }

    /// Keeps content to a readable column on iPad and in landscape.
    func hvReadableWidth() -> some View {
        frame(maxWidth: HV.readableWidth)
            .frame(maxWidth: .infinity)
    }
}
