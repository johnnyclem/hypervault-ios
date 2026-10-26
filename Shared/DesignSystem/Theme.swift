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
    static let textSecondary = Color(light: Color(hex: 0x566274), dark: Color(hex: 0x8B97A8))
    static let textTertiary = Color(light: Color(hex: 0x8793A4), dark: Color(hex: 0x5F6B7D))

    static let violet = Color(hex: 0x8B5CF6)
    static let blue = Color(hex: 0x3B82F6)
    static let sky = Color(hex: 0x38BDF8)
    static let cyan = Color(hex: 0x22D3EE)
    static let mint = Color(hex: 0x10B981)
    static let amber = Color(hex: 0xF59E0B)
    static let coral = Color(hex: 0xF97316)
    static let rose = Color(hex: 0xF43F5E)

    static let success = mint
    static let warning = amber
    static let danger = Color(light: Color(hex: 0xDC2626), dark: Color(hex: 0xEF4444))

    /// The mark's gradient, violet through blue to cyan.
    static let brandGradient = LinearGradient(
        colors: [violet, blue, cyan],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// A calmer two-stop gradient for fills.
    static let softGradient = LinearGradient(
        colors: [blue, sky],
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
