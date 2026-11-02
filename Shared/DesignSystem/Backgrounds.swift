import SwiftUI

/// The web's ambient wash: `primary` at 8% and `accent` at 5%, "restrained, not playful" (style guide 7). It follows the
/// web's `.hv-memory-glow` in its two colours and strengths and in being static, two soft radial gradients, but it sits
/// at the app's own positions and not the web's. Nothing in it moves or blurs, so it holds still for everyone, Reduce
/// Motion included, and costs one draw. It sits behind the first screens and the canvas and never competes with content.
struct AuroraBackground: View {
    var intensity: Double = 1

    var body: some View {
        ZStack {
            Palette.background
            // The gradients' radii follow the screen's width, as the blurred circles' sizes did.
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack {
                    RadialGradient(
                        colors: [HVColor.primary.opacity(0.08 * intensity), HVColor.primary.opacity(0)],
                        center: UnitPoint(x: 0.18, y: 0.20),
                        startRadius: 0,
                        endRadius: width * 0.95
                    )
                    RadialGradient(
                        colors: [HVColor.accent.opacity(0.05 * intensity), HVColor.accent.opacity(0)],
                        center: UnitPoint(x: 0.84, y: 0.32),
                        startRadius: 0,
                        endRadius: width * 0.85
                    )
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
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
