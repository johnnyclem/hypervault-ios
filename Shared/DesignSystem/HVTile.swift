import SwiftUI

/// The neutral tile that leads a row: 36pt, `radius-xl`, `muted` at 60% inside a `border` edge at 60%, its content in
/// `muted-foreground`. It is decoration, so it is hidden from VoiceOver; the row's words say what it is (handoff 4.3).
/// A card with a known brand uses `HVCardBrandTile` in its place.
struct HVTile<Content: View>: View {
    var size: CGFloat = 36
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: HV.Radius.card, style: .continuous)
        content()
            .foregroundStyle(HVColor.mutedForeground)
            .frame(width: size, height: size)
            .background(HVColor.muted.opacity(0.6), in: shape)
            .overlay(shape.strokeBorder(Palette.border, lineWidth: 1))
            .accessibilityHidden(true)
    }
}

extension HVTile where Content == Text {
    /// An SF Symbol (`HVSymbol` names the ones the handoff uses), at the size the web draws its icons (16 in 36).
    init(symbol: String, size: CGFloat = 36) {
        self.init(size: size) {
            Text(Image(systemName: symbol)).font(.system(size: size * 0.44))
        }
    }

    /// A login's monogram: the first letter or digit of its name, in `foreground`.
    init(monogram: String, size: CGFloat = 36) {
        self.init(size: size) {
            Text(monogram).font(.system(.subheadline, weight: .semibold)).foregroundStyle(HVColor.foreground)
        }
    }
}

#Preview("Tiles") {
    HStack(spacing: HV.Space.s) {
        HVTile(symbol: HVSymbol.card)
        HVTile(symbol: HVSymbol.contact)
        HVTile(symbol: HVSymbol.address)
        HVTile(symbol: HVSymbol.key)
        HVTile(monogram: "G")
    }
    .padding(HV.Space.m)
    .hvScreenBackground()
}
