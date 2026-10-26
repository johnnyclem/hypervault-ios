import SwiftUI

/// The "H" of the app icon, drawn as a shape so it scales anywhere.
struct HMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        // Proportions come from the 1024-point icon.
        func box(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> CGRect {
            CGRect(
                x: rect.minX + rect.width * x0 / 1024,
                y: rect.minY + rect.height * y0 / 1024,
                width: rect.width * (x1 - x0) / 1024,
                height: rect.height * (y1 - y0) / 1024
            )
        }
        let corner = rect.width * 18 / 1024
        var path = Path()
        path.addRoundedRect(in: box(226, 140, 342, 884), cornerSize: CGSize(width: corner, height: corner))
        path.addRoundedRect(in: box(682, 140, 798, 884), cornerSize: CGSize(width: corner, height: corner))
        path.addRoundedRect(in: box(226, 456, 798, 570), cornerSize: CGSize(width: corner, height: corner))
        return path
    }
}

/// The app icon as a view: the H on the brand gradient.
struct BrandMark: View {
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(Palette.brandGradient)
            HMarkShape()
                .fill(.white)
                .padding(size * 0.02)
        }
        .frame(width: size, height: size)
        .shadow(color: Palette.blue.opacity(0.35), radius: size * 0.22, x: 0, y: size * 0.1)
        .accessibilityHidden(true)
    }
}

/// Just the H, for use inside other shapes and as a watermark.
struct BrandGlyph: View {
    var size: CGFloat = 28
    var body: some View {
        HMarkShape()
            .fill(Palette.brandGradient)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
