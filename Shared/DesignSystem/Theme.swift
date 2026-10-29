import SwiftUI
import UIKit

/// Layout constants. Everything on screen sits on a 4-point grid, with the two values the web uses beside it (6 and 24).
enum HV {
    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let s: CGFloat = 12
        static let m: CGFloat = 16
        static let l: CGFloat = 20
        static let xl: CGFloat = 28
        static let xxl: CGFloat = 40
        /// 6: between the pills of a row, the web's gap-1.5.
        static let hair: CGFloat = 6
        /// 24: between the groups of a pane, the web's gap-6.
        static let wide: CGFloat = 24
    }

    /// Corner radii. The role names are the web's (handoff 2.5); the ones that come from the stock tokens read
    /// `HVTokens`. Every shape that uses one is `.continuous`. `s` and `m` are the app's older sizes and match nothing
    /// on the web: new code names the role it is drawing, and a screen that still uses them moves when it is next touched.
    enum Radius {
        /// 8, `rounded-lg`: buttons and inputs.
        static let control: CGFloat = 8
        /// 6, `rounded-md`: small buttons.
        static let smallControl: CGFloat = 6
        /// 16, `radius-xl`: the card, the neutral tile and the code panel.
        static let card = HVTokens.RadiusPx.radiusXl
        /// 20, `radius-2xl`: pane surfaces, the list, add-type tiles and the empty state.
        static let surface = HVTokens.RadiusPx.radius2xl
        /// 28, `radius-3xl`: the sheet, which the system draws. For reference; nothing sets it.
        static let sheet = HVTokens.RadiusPx.radius3xl
        /// 5, `rounded-[5px]`: the card-brand tile.
        static let brandTile: CGFloat = 5

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

    /// One colour that is `dark` in the dark look and `light` in the light look, for a shade the web has no token for.
    /// (The tokens are colour sets; these are not, so the pair is made here.)
    init(dark: UInt32, light: UInt32) {
        func component(_ hex: UInt32, _ shift: UInt32) -> CGFloat { CGFloat((hex >> shift) & 0xff) / 255 }
        self.init(UIColor { traits in
            let hex = traits.userInterfaceStyle == .light ? light : dark
            return UIColor(red: component(hex, 16), green: component(hex, 8), blue: component(hex, 0), alpha: 1)
        })
    }
}

/// The HyperVault palette. Dark is the stock look from the web's tokens; light is the same roles with the iOS
/// guide's mirror values. Every member is a colour set in `HVColor`, so a screen never branches on the colour scheme
/// and both looks keep the same hierarchy. The names are the app's own and stay as they are; the tokens they stand
/// for are named in each comment.
///
/// Contrast (WCAG, held by `DesignContrastTests`): `textPrimary` is 13.7:1 or better on the page, paper and raised
/// paper, and the grey text is 5.4:1 or better. Every accent below is 4.5:1 or better on all three, except `blue` as
/// text on raised paper (4.36) and `danger` as text on raised paper (4.26). White on `blue` is 3.68:1, which holds
/// bold text only; anything that carries body-size white text is filled with `softGradient` instead. `blue` over its own
/// 14% tint is 4.08:1 on paper, so small text on a tint of `blue` is `sky`.
enum Palette {
    /// The page: `background`.
    static let background = HVColor.background
    /// Paper, for cards and grouped lists: `card`.
    static let surface = HVColor.card
    /// Raised paper, for fields, tiles and the selected pill: `muted`.
    static let surfaceRaised = HVColor.muted
    /// A 1pt edge on a surface (a card, a list, a tile): `border` at 60%, as the web draws them. At full strength it
    /// is 1.34:1 on paper, and the web never uses it so.
    static let border = HVColor.border.opacity(0.6)
    /// A 1pt edge on a control (a secondary button, an input): `border` at 70%.
    static let controlBorder = HVColor.border.opacity(0.7)
    /// Between rows: `border` at 50%.
    static let divider = HVColor.border.opacity(0.5)
    static let hairline = divider

    /// Body text and row names: `foreground`.
    static let textPrimary = HVColor.foreground
    /// Hints, descriptions, counts and labels: `muted-foreground`. The web has one grey, so the second tier is the
    /// same colour, and it stays at full strength (at 85% it would be 4.29:1 on raised paper).
    static let textSecondary = HVColor.mutedForeground
    static let textTertiary = HVColor.mutedForeground

    /// The block a loading placeholder is drawn in: `border`, clearly there on the page and quiet beside content.
    static let skeleton = HVColor.border

    // The accents. The stock ones are the web's tokens and follow the appearance. Violet is the memory kind (a colour
    // set, so it follows too). Cyan, coral and rose are decorative and have no token: each is its dark shade (the
    // 400s) and, in the light look, the 700 the other accents mirror to (emerald, amber and violet are 700 there), so
    // that they hold 4.5:1 as text and glyph on the light page and on paper, as they do in the dark.
    static let violet = HVColor.memory
    /// The web's `primary`, which is also the accent colour of the app.
    static let blue = HVColor.primary
    /// The web's `accent`: tinted text on raised paper, where `blue` falls under 4.5:1.
    static let sky = HVColor.accent
    static let cyan = Color(dark: 0x22D3EE, light: 0x0E7490)
    /// Emerald-400, the Agent keys chips' success shade.
    static let mint = HVColor.emerald400
    /// Amber-400, the Agent keys chips' warning shade.
    static let amber = HVColor.amber400
    static let coral = Color(dark: 0xF97316, light: 0xC2410C)
    static let rose = Color(dark: 0xFB7185, light: 0xBE123C)

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

/// Type. Text styles, so everything scales with Dynamic Type, in the system face (SF Pro), which is what the web's
/// sans stack resolves to. Monospace marks what is typed or matched exactly (a name, a key prefix, a card number);
/// it is not a style. Roles are in handoff 2.4: a pane heading is `hvTitle3`, a sheet title `hvHeadline`, a section
/// heading `HVSectionHeader`, a description `hvSubheadline`, a row name `hvBody`, a hint `hvFootnote`.
extension Font {
    static let hvHero = Font.system(.largeTitle, weight: .bold)
    static let hvTitle = Font.system(.title2, weight: .semibold)
    static let hvTitle3 = Font.system(.title3, weight: .semibold)
    static let hvHeadline = Font.system(.headline, weight: .semibold)
    /// The label of a filled button: bold, which is what lets white on `primary` (3.68:1) pass.
    static let hvButton = Font.system(.headline, weight: .bold)
    static let hvBody = Font.system(.body)
    static let hvCallout = Font.system(.callout)
    static let hvSubheadline = Font.system(.subheadline)
    static let hvFootnote = Font.system(.footnote)
    static let hvCaption = Font.system(.caption)
    static let hvMono = Font.system(.footnote, design: .monospaced)
    /// Code in `HVCodePanel` and nowhere else: the web's 11px mono.
    static let hvCode = Font.caption.monospaced()
}
