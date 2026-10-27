import SwiftUI

/// Layout constants. Everything on screen sits on this 4-point grid.
enum HV {
    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let s: CGFloat = 12
        static let m: CGFloat = 16
        static let l: CGFloat = 20
        static let xl: CGFloat = 28
        static let xxl: CGFloat = 40
    }

    enum Radius {
        static let s: CGFloat = 10
        static let m: CGFloat = 14
        static let l: CGFloat = 20
        static let xl: CGFloat = 28
    }

    /// The width content stops growing at on iPad and landscape.
    static let readableWidth: CGFloat = 640
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: opacity
        )
    }
}

/// The HyperVault palette: the web's stock look, which is dark only (handoff 2.2). Every member is one value built
/// from the stock tokens in `HVColor`, so nothing here follows the colour scheme and a screen never branches on it.
/// The names are the app's own and stay as they are; the tokens they stand for are named in each comment.
///
/// Contrast (WCAG, held by `DesignContrastTests`): `textPrimary` is 13.7:1 or better on the page, paper and raised
/// paper, and the grey text is 5.4:1 or better. Every accent below is 4.5:1 or better on all three, except `blue` as
/// text on raised paper (4.36) and `danger` as text on raised paper (4.26). White on `blue` is 3.68:1, which holds
/// bold text only; anything that carries body-size white text is filled with `softGradient` instead.
enum Palette {
    /// The page: `background`.
    static let background = HVColor.background
    /// Paper, for cards and grouped lists: `card`.
    static let surface = HVColor.card
    /// Raised paper, for fields, tiles and the selected pill: `muted`.
    static let surfaceRaised = HVColor.muted
    /// A 1pt edge: `border`.
    static let border = HVColor.border
    /// Between rows: `border` at 50%, the web's divider.
    static let hairline = HVColor.border.opacity(0.5)

    /// Body text and row names: `foreground`.
    static let textPrimary = HVColor.foreground
    /// Hints, descriptions, counts and labels: `muted-foreground`. The web has one grey, so the second tier is the
    /// same colour, and it stays at full strength (at 85% it would be 4.29:1 on raised paper).
    static let textSecondary = HVColor.mutedForeground
    static let textTertiary = HVColor.mutedForeground

    /// The block a loading placeholder is drawn in: `border`, clearly there on the page and quiet beside content.
    static let skeleton = HVColor.border

    // The accents. The stock ones are the web's tokens; violet, cyan, coral and rose are the app's own decorative
    // tints (the web has no token for them) and stay as single dark values.
    static let violet = Color(hex: 0xA78BFA)
    /// The web's `primary`, which is also the accent colour of the app.
    static let blue = HVColor.primary
    /// The web's `accent`: tinted text on raised paper, where `blue` falls under 4.5:1.
    static let sky = HVColor.accent
    static let cyan = Color(hex: 0x22D3EE)
    /// Emerald-400, the Agent keys chips' success shade.
    static let mint = HVColor.emerald400
    /// Amber-400, the Agent keys chips' warning shade.
    static let amber = HVColor.amber400
    static let coral = Color(hex: 0xF97316)
    static let rose = Color(hex: 0xFB7185)

    static let success = mint
    static let warning = amber
    /// The web's `destructive`.
    static let danger = HVColor.destructive

    /// The mark's gradient, violet through blue to cyan. It is for the mark and for decoration, never behind text.
    static let brandGradient = LinearGradient(
        colors: [Color(hex: 0x8B5CF6), Color(hex: 0x3B82F6), Color(hex: 0x22D3EE)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// The fill for anything that carries white text or a white glyph: the primary button, the person's
    /// own chat bubbles, the send button. White on either end is 5.1:1 or better.
    static let softGradient = LinearGradient(
        colors: [Color(hex: 0x2563EB), Color(hex: 0x0369A1)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// The brand gradient in shades that hold a white initial: for avatars.
    static let avatarGradient = LinearGradient(
        colors: [Color(hex: 0x6D28D9), Color(hex: 0x2563EB), Color(hex: 0x0E7490)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

/// Type. Text styles, so everything scales with Dynamic Type; rounded for the
/// few moments that should feel warm.
extension Font {
    static let hvHero = Font.system(.largeTitle, design: .rounded, weight: .bold)
    static let hvTitle = Font.system(.title2, design: .rounded, weight: .semibold)
    static let hvTitle3 = Font.system(.title3, design: .rounded, weight: .semibold)
    static let hvHeadline = Font.system(.headline, weight: .semibold)
    static let hvBody = Font.system(.body)
    static let hvCallout = Font.system(.callout)
    static let hvSubheadline = Font.system(.subheadline)
    static let hvFootnote = Font.system(.footnote)
    static let hvCaption = Font.system(.caption)
    static let hvMono = Font.system(.footnote, design: .monospaced)
}
