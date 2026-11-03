import HyperVaultKit
import Observation
import SwiftUI
import UIKit

// The look this process is wearing, and every colour, radius and font design that depends on it.
//
// `Palette` and `HVColor` are the one door the screens use for colour (about 1,200 references), and `HV.Radius` for the
// card, surface and sheet corners. They used to be constants; they are now computed from `StyleRuntime.shared`, so a screen
// that reads one inside its `body` is re-drawn when the look changes, and no call site had to change.
//
// Stock is the default, and it is exactly what the asset catalog and `HVTokens` always said: a process that never calls
// `apply` (the Share extension and the widgets, which compile this file and keep the stock look in v1) draws the same pixels
// it drew before this file existed. Only the app calls `apply`, from `StyleKitStore`, with a kit that has already passed
// `StyleKit.violations`.

// MARK: Colours from the Kit

extension Color {
    /// An opaque sRGB colour from the Kit's `RGB`.
    init(rgb: RGB) {
        self.init(.sRGB, red: Double(rgb.red) / 255, green: Double(rgb.green) / 255, blue: Double(rgb.blue) / 255, opacity: 1)
    }
}

extension UIColor {
    convenience init(rgb: RGB) {
        self.init(red: CGFloat(rgb.red) / 255, green: CGFloat(rgb.green) / 255, blue: CGFloat(rgb.blue) / 255, alpha: 1)
    }

    /// `normal`, or `high` while Increase Contrast is on (the trait the system sets from Settings > Accessibility). A colour
    /// that is the same in both is a plain one.
    static func hvDynamic(normal: RGB, high: RGB) -> UIColor {
        guard normal != high else { return UIColor(rgb: normal) }
        return UIColor { traits in UIColor(rgb: traits.accessibilityContrast == .high ? high : normal) }
    }
}

// MARK: The colours

/// Every colour `HVColor` and `Palette` hand out, for one look. `stock` is the asset catalog as it always was. A kit's
/// colours are built once, when it is applied, so a body that reads a colour twice is handed the same value twice and
/// SwiftUI has nothing to re-diff. It is a class so that reading `Palette.textPrimary` copies one reference and not
/// thirty colours.
final class PaletteColors: Sendable {
    let background: Color
    let foreground: Color
    let card: Color
    let cardForeground: Color
    let muted: Color
    let mutedForeground: Color
    let primary: Color
    let primaryForeground: Color
    let secondary: Color
    let secondaryForeground: Color
    let accent: Color
    let accentForeground: Color
    let border: Color
    let ring: Color
    let destructive: Color
    /// `HVColor.emerald400`: success text and the success tint.
    let success: Color
    /// `HVColor.amber400`: warning text and the warning tint.
    let warning: Color
    /// The memory violet, and the three model-family tones `ChatAgentTone` draws (the web has no token for them).
    let memory: Color
    let coral: Color
    let cyan: Color
    let rose: Color
    /// The flat fill under a label, and the label on it (`Palette.action`, `Palette.onAction`).
    let action: Color
    let onAction: Color
    /// The label on the destructive fill (`Palette.onDestructive`).
    let onDestructive: Color
    /// `border` at the three strengths the screens use (60%, 70%, 50%).
    let borderEdge: Color
    let controlEdge: Color
    let dividerLine: Color

    /// The asset catalog, exactly as before. White is `primary-foreground` in both stock looks (tokens.json), and it is the
    /// label the app has always put on `action` and on `destructive`.
    private init() {
        background = Color("background")
        foreground = Color("foreground")
        card = Color("card")
        cardForeground = Color("card-foreground")
        muted = Color("muted")
        mutedForeground = Color("muted-foreground")
        primary = Color("primary")
        primaryForeground = Color("primary-foreground")
        secondary = Color("secondary")
        secondaryForeground = Color("secondary-foreground")
        accent = Color("accent")
        accentForeground = Color("accent-foreground")
        border = Color("border")
        ring = Color("ring")
        destructive = Color("destructive")
        success = Color("emerald-400")
        warning = Color("amber-400")
        memory = Color("memory")
        coral = Color(dark: 0xF97316, light: 0xC2410C)
        cyan = Color(dark: 0x22D3EE, light: 0x0E7490)
        rose = Color(dark: 0xFB7185, light: 0xBE123C)
        action = Color("action")
        onAction = Color.white
        onDestructive = Color.white
        borderEdge = Color("border").opacity(0.6)
        controlEdge = Color("border").opacity(0.7)
        dividerLine = Color("border").opacity(0.5)
    }

    static let stock = PaletteColors()

    /// A kit's colours. Each role is the kit's colour, or a colour that becomes the Increase Contrast one when the trait is
    /// on (`StyleKit.highContrast`). The kit has no `card-foreground`, `secondary` or `accent-foreground`: they are the
    /// colours the stock look uses them as (nothing draws them but the design-system page), and the label on a fill the kit
    /// carries no label for (`primary` in the brand mark, `accent`, the destructive red) is black or white, whichever reads
    /// better on it.
    init(_ kit: StyleKit) {
        let normal = kit.colors, high = kit.highContrast
        let hues = kit.hues, highHues = kit.highContrastHues
        func color(_ normal: RGB, _ high: RGB) -> Color {
            guard normal != high else { return Color(rgb: normal) }
            return Color(UIColor.hvDynamic(normal: normal, high: high))
        }
        func role(_ role: StyleColorRole) -> Color { color(normal[role], high[role]) }

        background = role(.background)
        foreground = role(.foreground)
        card = role(.card)
        cardForeground = role(.foreground)
        muted = role(.muted)
        mutedForeground = role(.mutedForeground)
        primary = role(.primary)
        primaryForeground = color(normal.primary.legibleLabel, high.primary.legibleLabel)
        secondary = role(.mutedForeground)
        secondaryForeground = role(.background)
        accent = role(.accent)
        accentForeground = color(normal.accent.legibleLabel, high.accent.legibleLabel)
        border = role(.border)
        ring = role(.ring)
        destructive = role(.destructive)
        success = role(.success)
        warning = role(.warning)
        memory = color(hues.memory, highHues.memory)
        coral = color(hues.coral, highHues.coral)
        cyan = color(hues.cyan, highHues.cyan)
        rose = color(hues.rose, highHues.rose)
        action = role(.action)
        onAction = role(.actionForeground)
        onDestructive = color(normal.destructive.legibleLabel, high.destructive.legibleLabel)
        let edge = role(.border)
        borderEdge = edge.opacity(0.6)
        controlEdge = edge.opacity(0.7)
        dividerLine = edge.opacity(0.5)
    }
}

// MARK: The runtime

/// The look this process is wearing. One per process: the app, the Share extension and the widgets each have their own, and
/// each starts stock. Nonisolated and lock-protected, so `Palette` can be read from anywhere (the contrast tests read it
/// off the main actor); observable, so a view body that read a colour is re-evaluated when the look changes.
///
/// Observation, not the environment, carries the change: reading `snapshot` inside a `body` registers the body with the
/// registrar, and `apply` tells it. A `ButtonStyle`, a `ViewModifier` and a `UIViewRepresentable` are made inside some view's
/// body (`.buttonStyle(.hvPrimary)`, `.hvGlass()`), so each one carries a `StyleStamp` (the `revision` when it was made): the
/// view that makes it is then re-evaluated, and the style or modifier it hands down is a different value, which is what makes
/// SwiftUI run its own body again. Nothing relies on Observation reaching inside a style's `makeBody`.
final class StyleRuntime: Observable, @unchecked Sendable {
    static let shared = StyleRuntime()

    /// The corner radii that follow the kit's `radius.base` (the web's `--radius`; `rounded-xl`, `2xl` and `3xl` are that plus
    /// 4, 8 and 16). The control radii (8 and 6) are not the kit's.
    struct Radii: Sendable, Equatable {
        var card: CGFloat
        var surface: CGFloat
        var sheet: CGFloat

        static let stock = Radii(card: HVTokens.RadiusPx.radiusXl, surface: HVTokens.RadiusPx.radius2xl, sheet: HVTokens.RadiusPx.radius3xl)
    }

    /// What the UIKit chrome needs, in the Kit's own values so the snapshot stays `Sendable`: the window's tint, and the tab
    /// bar's quiet and selected item colours, each with its Increase Contrast twin. The tab bar reads like the stock one
    /// (`HVTabBarStyle`): the selected item is the page's own text in a dark look and `primary` in a light one.
    struct WindowInk: Sendable, Equatable {
        var tint: RGB
        var tintHigh: RGB
        var quiet: RGB
        var quietHigh: RGB
        var selected: RGB
        var selectedHigh: RGB
    }

    struct Snapshot: Sendable {
        var colors = PaletteColors.stock
        var radii = Radii.stock
        /// The theme worn, or nil for the stock look.
        var themeID: String?
        /// The one appearance a worn theme pins the app to; nil is the system's (stock).
        var appearance: StyleAppearance?
        var font: StyleFontDesign = .system
        /// The page behind the content. Stock is the glow `AuroraBackground` always drew.
        var backdrop: StyleBackdropKind = .glow
        var window: WindowInk?
        /// Bumps on every `apply`, so a value that captured it differs from one made before.
        var revision = 0

        var isThemed: Bool { appearance != nil }
    }

    private let registrar = ObservationRegistrar()
    private let lock = NSLock()
    private var current = Snapshot()

    /// The look being worn. Reading it inside a body registers the dependency.
    var snapshot: Snapshot {
        registrar.access(self, keyPath: \.snapshot)
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    var colors: PaletteColors { snapshot.colors }
    var radii: Radii { snapshot.radii }
    var revision: Int { snapshot.revision }

    /// Wears `kit`, or the stock look for nil. The kit has passed `StyleKit.violations` (`DashboardThemeState` guarantees it).
    /// A test that wears a kit resets with `apply(nil)` when it is done: the runtime is the process's.
    func apply(_ kit: StyleKit?) {
        var next = Snapshot()
        if let kit {
            let normal = kit.colors, high = kit.highContrast
            next.colors = PaletteColors(kit)
            next.radii = Radii(card: CGFloat(kit.radiusXL), surface: CGFloat(kit.radius2XL), sheet: CGFloat(kit.radius3XL))
            next.themeID = kit.id
            next.appearance = kit.appearance
            next.font = kit.font
            next.backdrop = kit.backdrop
            let selected: StyleColorRole = kit.appearance == .dark ? .foreground : .primary
            next.window = WindowInk(
                tint: normal.primary, tintHigh: high.primary,
                quiet: normal.mutedForeground, quietHigh: high.mutedForeground,
                selected: normal[selected], selectedHigh: high[selected]
            )
        }
        registrar.withMutation(of: self, keyPath: \.snapshot) {
            lock.lock()
            defer { lock.unlock() }
            next.revision = current.revision + 1
            current = next
        }
    }
}

/// The look a style, a modifier or a representable was made in. `ButtonStyle`, `ViewModifier` and `UIViewRepresentable` are
/// values the view that uses them makes in its own `body` (`.buttonStyle(.hvPrimary)`, `.hvGlass()`), where reading the
/// runtime is tracked; a value that carries the stamp is a different value after the look changes, so SwiftUI runs its
/// `makeBody`, `body` or `updateUIView` again. Declare `let look = StyleStamp()` in any such type whose body reads `Palette`,
/// `HVColor` or `HV.Radius`.
struct StyleStamp: Equatable, Sendable {
    let revision = StyleRuntime.shared.revision
}

extension StyleRuntime {
    /// `muted-foreground` for the UIKit views that hold their own colour (a placeholder label): the asset in the stock look,
    /// and in a worn one the theme's, with its Increase Contrast twin. `UIColor(Color)` would fix a dynamic colour to the
    /// traits it was converted in, so UIKit gets its own.
    var uiMutedForeground: UIColor {
        if let ink = snapshot.window { return UIColor.hvDynamic(normal: ink.quiet, high: ink.quietHigh) }
        return UIColor(named: "muted-foreground") ?? .secondaryLabel
    }
}

extension StyleAppearance {
    /// The window's interface style for this appearance.
    var userInterfaceStyle: UIUserInterfaceStyle { self == .dark ? .dark : .light }

    var colorScheme: ColorScheme { self == .dark ? .dark : .light }
}

extension StyleFontDesign {
    /// The SwiftUI design to lay over the system font, or nil to leave the text as it is.
    var swiftUIDesign: Font.Design? {
        switch self {
        case .system: return nil
        case .serif: return .serif
        case .mono: return .monospaced
        }
    }
}
