import Foundation

// The StyleKit: the look the app wears, as data. The server resolves the person's web theme (`profiles.theme`, a style id
// from lib/themes.ts) into an accessible kit (the CSS cascade applied, translucent colours flattened over the page, every
// text colour clamped to WCAG 4.5:1 on the surfaces it is drawn on) and sends it with `GET /api/dashboard-theme` as
// `{ theme, kit }`. This file is the client's reading of that wire format, version 1 (docs/stylekit.md on the server):
//
//   * snake_case keys, spelled out below (`CodingKeys`), so decode these with `keys: .verbatim`;
//   * every colour is an opaque `#rrggbb` (anything else refuses the kit), and all 14 are required;
//   * unknown keys are ignored, an unknown `font.design` is `system` and an unknown `backdrop.kind` is `plain`, an unknown
//     `adjusted` entry is dropped; an unknown `appearance`, a missing colour, or a `schema_version` other than 1 refuses
//     the kit and the app keeps its own default look;
//   * the app re-checks the accessibility floors itself (`StyleKitContract`), because it never draws a screen it was told
//     is readable by a server it cannot audit.
//
// Pure value types, Foundation only, so all of it is tested on Linux.

// MARK: Vocabulary

/// The one appearance a kit defines. A worn theme pins the app to it (the web lets the theme beat the OS setting too).
public enum StyleAppearance: String, Sendable, Codable, Equatable {
    case light, dark
}

/// A SwiftUI font design, never a family name: nothing the server says can make the app look up a font.
public enum StyleFontDesign: String, Sendable, Codable, Equatable {
    case system, serif, mono
}

/// How much atmosphere the page behind the content has.
public enum StyleBackdropKind: String, Sendable, Codable, Equatable {
    case plain, glow, lines, dots
}

/// The 14 colour roles of wire format v1, with the wire's own spelling as the raw value.
public enum StyleColorRole: String, Sendable, Codable, Equatable, Hashable, CaseIterable, CodingKey {
    case background, foreground, card, muted
    case mutedForeground = "muted_foreground"
    case primary, accent, destructive, success, warning
    /// The fill behind a label: the theme's own primary, kept as designed.
    case action
    /// The label on `action`, fixed up by the server to read on it (the theme's own, else black or white).
    case actionForeground = "action_foreground"
    case border, ring
}

// MARK: Colours

/// The 14 opaque colours of a kit. `primary` is ink (text, glyphs, tint: the server moved it until it reads on the
/// surfaces); `action` is the fill behind a label and `actionForeground` is that label.
public struct StyleKitColors: Sendable, Equatable {
    public var background: RGB
    public var foreground: RGB
    public var card: RGB
    public var muted: RGB
    public var mutedForeground: RGB
    public var primary: RGB
    public var accent: RGB
    public var destructive: RGB
    public var success: RGB
    public var warning: RGB
    public var action: RGB
    public var actionForeground: RGB
    public var border: RGB
    public var ring: RGB

    public init(
        background: RGB, foreground: RGB, card: RGB, muted: RGB, mutedForeground: RGB, primary: RGB, accent: RGB,
        destructive: RGB, success: RGB, warning: RGB, action: RGB, actionForeground: RGB, border: RGB, ring: RGB
    ) {
        self.background = background
        self.foreground = foreground
        self.card = card
        self.muted = muted
        self.mutedForeground = mutedForeground
        self.primary = primary
        self.accent = accent
        self.destructive = destructive
        self.success = success
        self.warning = warning
        self.action = action
        self.actionForeground = actionForeground
        self.border = border
        self.ring = ring
    }

    public subscript(role: StyleColorRole) -> RGB {
        get {
            switch role {
            case .background: return background
            case .foreground: return foreground
            case .card: return card
            case .muted: return muted
            case .mutedForeground: return mutedForeground
            case .primary: return primary
            case .accent: return accent
            case .destructive: return destructive
            case .success: return success
            case .warning: return warning
            case .action: return action
            case .actionForeground: return actionForeground
            case .border: return border
            case .ring: return ring
            }
        }
        set {
            switch role {
            case .background: background = newValue
            case .foreground: foreground = newValue
            case .card: card = newValue
            case .muted: muted = newValue
            case .mutedForeground: mutedForeground = newValue
            case .primary: primary = newValue
            case .accent: accent = newValue
            case .destructive: destructive = newValue
            case .success: success = newValue
            case .warning: warning = newValue
            case .action: action = newValue
            case .actionForeground: actionForeground = newValue
            case .border: border = newValue
            case .ring: ring = newValue
            }
        }
    }

    /// The three surfaces text sits on: the page, paper, and raised paper.
    public var surfaces: [RGB] { [background, card, muted] }
}

extension StyleKitColors: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: StyleColorRole.self)
        func colour(_ role: StyleColorRole) throws -> RGB {
            guard let text = try c.decodeIfPresent(String.self, forKey: role) else {
                throw StyleKitRejection.malformed("colors.\(role.rawValue) is missing")
            }
            guard let parsed = RGB(parsing: text) else {
                throw StyleKitRejection.malformed("colors.\(role.rawValue) is not an opaque #rrggbb colour: \(text)")
            }
            return parsed
        }
        self.init(
            background: try colour(.background), foreground: try colour(.foreground), card: try colour(.card), muted: try colour(.muted),
            mutedForeground: try colour(.mutedForeground), primary: try colour(.primary), accent: try colour(.accent),
            destructive: try colour(.destructive), success: try colour(.success), warning: try colour(.warning),
            action: try colour(.action), actionForeground: try colour(.actionForeground), border: try colour(.border), ring: try colour(.ring)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: StyleColorRole.self)
        for role in StyleColorRole.allCases { try c.encode(self[role], forKey: role) }
    }
}

// MARK: The kit

/// Why a kit was not worn. The app keeps its own default look and says the theme cannot be shown.
public enum StyleKitRejection: Error, Sendable, Equatable {
    /// `schema_version` is not the major this build reads (a newer server, or no version at all).
    case unsupportedSchema(Int?)
    /// A required key is missing or unreadable, `appearance` is a word this build does not know, or a colour is not
    /// an opaque `#rrggbb`.
    case malformed(String)
    /// The colours do not hold the accessibility floors (`StyleKitContract`); the label names the first pair that fails.
    case illegible(String)
}

/// One theme, resolved: `kit` in `GET /api/dashboard-theme`.
public struct StyleKit: Sendable, Equatable {
    /// The only major this build reads. A higher one is refused rather than half understood.
    public static let supportedSchemaVersion = 1
    /// `radius.base` when the kit does not say (the stock `--radius`, 0.75rem).
    public static let defaultRadius = 12.0
    /// The largest `radius.base` the app believes; a larger number is a mistake, not a design.
    public static let maxRadius = 48.0

    /// The style id (`newsprint`).
    public var id: String
    public var name: String
    public var appearance: StyleAppearance
    public var colors: StyleKitColors
    /// `--radius` in points.
    public var radius: Double
    public var font: StyleFontDesign
    public var backdrop: StyleBackdropKind
    /// The roles the server moved for accessibility, in the server's order. Unknown roles are dropped.
    public var adjusted: [StyleColorRole]

    public init(
        id: String, name: String? = nil, appearance: StyleAppearance, colors: StyleKitColors,
        radius: Double = StyleKit.defaultRadius, font: StyleFontDesign = .system, backdrop: StyleBackdropKind = .plain,
        adjusted: [StyleColorRole] = []
    ) {
        self.id = id
        self.name = name ?? id
        self.appearance = appearance
        self.colors = colors
        self.radius = radius
        self.font = font
        self.backdrop = backdrop
        self.adjusted = adjusted
    }

    /// The radii the app draws, from `radius`: the web's `rounded-xl`, `2xl` and `3xl` are `--radius` plus 4, 8 and 16
    /// (12, 16, 20 and 28 in the stock look, `HVTokens.RadiusPx`).
    public var radiusXL: Double { radius + 4 }
    public var radius2XL: Double { radius + 8 }
    public var radius3XL: Double { radius + 16 }

    /// Whether a colour the person can see as a colour of the theme moved: the line "some colours are adjusted so text
    /// stays easy to read" is true then. A nudged error red or a flipped button label is not worth a line.
    public var hasNoticeableAdjustments: Bool {
        adjusted.contains { [.foreground, .mutedForeground, .primary, .accent].contains($0) }
    }
}

extension StyleKit: Codable {
    enum Keys: String, CodingKey {
        case schemaVersion = "schema_version"
        case id, name, appearance, colors, radius, font, backdrop, adjusted
    }
    enum RadiusKeys: String, CodingKey { case base }
    enum FontKeys: String, CodingKey { case design }
    enum BackdropKeys: String, CodingKey { case kind }

    /// Throws only `StyleKitRejection`. Reading is structural: the accessibility floors are `violations`, so that a
    /// kit that decodes can still be inspected, and the store checks both before it wears anything.
    public init(from decoder: Decoder) throws {
        do {
            let c = try decoder.container(keyedBy: Keys.self)
            guard let version = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) else {
                throw StyleKitRejection.unsupportedSchema(nil)
            }
            guard version == Self.supportedSchemaVersion else { throw StyleKitRejection.unsupportedSchema(version) }

            guard let id = try c.decodeIfPresent(String.self, forKey: .id), !id.isEmpty else {
                throw StyleKitRejection.malformed("id is missing")
            }
            guard let appearanceWord = try c.decodeIfPresent(String.self, forKey: .appearance) else {
                throw StyleKitRejection.malformed("appearance is missing")
            }
            guard let appearance = StyleAppearance(rawValue: appearanceWord) else {
                throw StyleKitRejection.malformed("appearance is not light or dark: \(appearanceWord)")
            }
            let colors = try c.decode(StyleKitColors.self, forKey: .colors)

            // Everything below is optional and decorative: a value this build cannot read is the neutral one.
            let name = (try? c.decodeIfPresent(String.self, forKey: .name)).flatMap { $0.isEmpty ? nil : $0 }
            var radius = Self.defaultRadius
            if let nested = try? c.nestedContainer(keyedBy: RadiusKeys.self, forKey: .radius),
               let base = try? nested.decodeIfPresent(Double.self, forKey: .base), base.isFinite {
                radius = min(max(base, 0), Self.maxRadius)
            }
            var font = StyleFontDesign.system
            if let nested = try? c.nestedContainer(keyedBy: FontKeys.self, forKey: .font),
               let word = try? nested.decodeIfPresent(String.self, forKey: .design) {
                font = StyleFontDesign(rawValue: word) ?? .system
            }
            var backdrop = StyleBackdropKind.plain
            if let nested = try? c.nestedContainer(keyedBy: BackdropKeys.self, forKey: .backdrop),
               let word = try? nested.decodeIfPresent(String.self, forKey: .kind) {
                backdrop = StyleBackdropKind(rawValue: word) ?? .plain
            }
            let words = (try? c.decodeIfPresent([String].self, forKey: .adjusted)) ?? []

            self.init(
                id: id, name: name, appearance: appearance, colors: colors, radius: radius, font: font, backdrop: backdrop,
                adjusted: words.compactMap(StyleColorRole.init(rawValue:))
            )
        } catch let rejection as StyleKitRejection {
            throw rejection
        } catch let error as DecodingError {
            throw StyleKitRejection.malformed(Self.describe(error))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(Self.supportedSchemaVersion, forKey: .schemaVersion)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(appearance, forKey: .appearance)
        try c.encode(colors, forKey: .colors)
        var radiusContainer = c.nestedContainer(keyedBy: RadiusKeys.self, forKey: .radius)
        try radiusContainer.encode(radius, forKey: .base)
        var fontContainer = c.nestedContainer(keyedBy: FontKeys.self, forKey: .font)
        try fontContainer.encode(font, forKey: .design)
        var backdropContainer = c.nestedContainer(keyedBy: BackdropKeys.self, forKey: .backdrop)
        try backdropContainer.encode(backdrop, forKey: .kind)
        try c.encode(adjusted, forKey: .adjusted)
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let context):
            return "\((context.codingPath + [key]).map(\.stringValue).joined(separator: ".")) is missing"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return "\(context.codingPath.map(\.stringValue).joined(separator: ".")): \(context.debugDescription)"
        @unknown default:
            return "\(error)"
        }
    }
}
