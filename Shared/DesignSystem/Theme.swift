import SwiftUI
import UIKit

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

    /// A colour that follows light and dark mode.
    init(light: Color, dark: Color) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }

    /// The colour for text or a glyph that sits on a tint of itself (a tag, an icon badge): the same
    /// colour in dark mode, and a fifth darker in light mode, where a tint of the colour is nearly white
    /// and the plain hue would fall under 4.5:1.
    func hvInk() -> Color {
        Color(uiColor: UIColor { traits in
            let resolved = UIColor(self).resolvedColor(with: traits)
            guard traits.userInterfaceStyle != .dark else { return resolved }
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return resolved }
            return UIColor(red: red * 0.8, green: green * 0.8, blue: blue * 0.8, alpha: alpha)
        })
    }
}

/// The HyperVault palette. Dark is the home look (a near-black blue with glass
/// chrome, as on the web); light is the same product in daylight.
enum Palette {
    static let background = Color(light: Color(hex: 0xF4F6FA), dark: Color(hex: 0x0B0F14))
    static let surface = Color(light: .white, dark: Color(hex: 0x121820))
    static let surfaceRaised = Color(light: Color(hex: 0xEDF1F6), dark: Color(hex: 0x1A222D))
    static let border = Color(light: Color(hex: 0xDDE3EB), dark: Color(hex: 0x243041))
    static let hairline = Color(light: Color(hex: 0xE8ECF2), dark: Color(hex: 0x1B2431))

    static let textPrimary = Color(light: Color(hex: 0x0B0F14), dark: Color(hex: 0xE8EEF5))
    // Both grey tiers are text: 4.5:1 or better on the background, on paper and on raised paper in either look.
    static let textSecondary = Color(light: Color(hex: 0x4A5568), dark: Color(hex: 0xA0ACBD))
    static let textTertiary = Color(light: Color(hex: 0x5F6B7D), dark: Color(hex: 0x8390A2))

    /// The block a loading placeholder is drawn in: clearly there on the page, quiet beside real content.
    static let skeleton = Color(light: Color(hex: 0xD9DFE8), dark: Color(hex: 0x273244))

    // The accents. Each is the shade that reads as text and glyph on the page in its look: a deep one in
    // light mode, a bright one in dark. Anything that carries white text uses `softGradient` instead.
    static let violet = Color(light: Color(hex: 0x6D28D9), dark: Color(hex: 0xA78BFA))
    static let blue = Color(light: Color(hex: 0x2563EB), dark: Color(hex: 0x60A5FA))
    static let sky = Color(light: Color(hex: 0x0369A1), dark: Color(hex: 0x38BDF8))
    static let cyan = Color(light: Color(hex: 0x0E7490), dark: Color(hex: 0x22D3EE))
    static let mint = Color(light: Color(hex: 0x047857), dark: Color(hex: 0x10B981))
    static let amber = Color(light: Color(hex: 0xB45309), dark: Color(hex: 0xF59E0B))
    static let coral = Color(light: Color(hex: 0xC2410C), dark: Color(hex: 0xF97316))
    static let rose = Color(light: Color(hex: 0xBE123C), dark: Color(hex: 0xFB7185))

    static let success = mint
    static let warning = amber
    static let danger = Color(light: Color(hex: 0xDC2626), dark: Color(hex: 0xEF4444))

    /// The mark's gradient, violet through blue to cyan. Bright in both looks; it is for the mark and for
    /// decoration, never behind text.
    static let brandGradient = LinearGradient(
        colors: [Color(hex: 0x8B5CF6), Color(hex: 0x3B82F6), Color(hex: 0x22D3EE)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// The fill for anything that carries white text or a white glyph: the primary button, the person's
    /// own chat bubbles, the send button. White on either end is 5:1 or better, in both looks.
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

/// The accents a person can pick in Settings.
enum AccentChoice: String, CaseIterable, Identifiable, Codable {
    case blue, violet, mint, coral, rose

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blue: return "Blue"
        case .violet: return "Violet"
        case .mint: return "Mint"
        case .coral: return "Coral"
        case .rose: return "Rose"
        }
    }

    var color: Color {
        switch self {
        case .blue: return Palette.blue
        case .violet: return Palette.violet
        case .mint: return Palette.mint
        case .coral: return Palette.coral
        case .rose: return Palette.rose
        }
    }
}

enum AppearanceChoice: String, CaseIterable, Identifiable, Codable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
