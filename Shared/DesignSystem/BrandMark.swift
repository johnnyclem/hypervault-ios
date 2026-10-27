import SwiftUI

/// The in-app mark, as the web draws it: a capital H in the monospace face on a solid `primary` tile (brand book 8).
/// It is live text and no logo is redrawn here; the gradient H of the app icon is the icon's alone. The corners keep
/// the web's 8pt in 32 (a quarter of the side) at any size, and there is no glow.
struct BrandMark: View {
    var size: CGFloat = 64

    var body: some View {
        Text("H")
            .font(.system(size: size * 0.4, weight: .semibold, design: .monospaced))
            .foregroundStyle(HVColor.primaryForeground)
            .frame(width: size, height: size)
            .background(HVColor.primary, in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
            .accessibilityHidden(true)
    }
}
