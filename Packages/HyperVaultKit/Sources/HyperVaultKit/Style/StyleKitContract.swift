import Foundation

/// The accessibility floors a kit must hold before the app wears it. The server clamps to the same numbers before it
/// sends a kit (lib/stylekit.ts `FLOORS`); the app checks them again, so a server it cannot audit, a stale cache or a
/// future preset that slips through can never put unreadable text on a screen. A kit that fails any pair is refused and
/// the app keeps its default look.
///
/// All ratios are WCAG 2.x on the opaque values the kit carries.
public enum StyleKitContract {
    /// Slack for floating point: the server judges the same formula in JavaScript, whose `pow` may differ from this
    /// platform's by an ulp, and a colour the server's bisection settled exactly on 4.5 must not be refused for it.
    public static let tolerance = 1e-6

    /// One pair the app draws: `foreground` on `background`, held to `floor`.
    public struct Pair: Sendable, Equatable {
        public let label: String
        public let foreground: RGB
        public let background: RGB
        public let floor: Double

        public var ratio: Double { foreground.contrast(with: background) }
        public var holds: Bool { ratio + StyleKitContract.tolerance >= floor }
    }

    /// Ink: a colour drawn as text, a glyph or a tint, and the surfaces it must read on. The same table as the server.
    static let ink: [(role: StyleColorRole, surfaces: [StyleColorRole], floor: Double)] = [
        (.foreground, [.background, .card, .muted], 4.5),
        (.mutedForeground, [.background, .card, .muted], 4.5),
        (.primary, [.background, .card], 4.5),
        (.accent, [.background, .card, .muted], 4.5),
        (.destructive, [.background, .card], 4.5),
        (.success, [.background, .card, .muted], 4.5),
        (.warning, [.background, .card, .muted], 4.5),
    ]

    /// Every pair of `kit`, in a fixed order.
    public static func pairs(for kit: StyleKit) -> [Pair] {
        let colors = kit.colors
        var pairs: [Pair] = []
        for (role, surfaces, floor) in ink {
            for surface in surfaces {
                pairs.append(Pair(label: "\(role.rawValue) on \(surface.rawValue)", foreground: colors[role], background: colors[surface], floor: floor))
            }
        }
        // The label on a filled button or a bubble.
        pairs.append(Pair(label: "action_foreground on action", foreground: colors.actionForeground, background: colors.action, floor: 4.5))
        // The app pins itself to the kit's appearance, and plain `Text`, a `Form` row, a navigation title and the
        // keyboard take the system's label for it: black on a light page, white on a dark one. Those must read too, so a
        // kit whose `appearance` does not fit its own page is refused. (Paper and raised paper only need to be
        // legible for large, bold or secondary text, as in the stock look.)
        let label: RGB = kit.appearance == .light ? .black : .white
        pairs.append(Pair(label: "system label on background", foreground: label, background: colors.background, floor: 4.5))
        pairs.append(Pair(label: "system label on card", foreground: label, background: colors.card, floor: 3.0))
        pairs.append(Pair(label: "system label on muted", foreground: label, background: colors.muted, floor: 3.0))
        return pairs
    }
}

extension StyleKit {
    /// The pairs that fall short of their floor; empty for a kit the app may wear.
    public var violations: [StyleKitContract.Pair] {
        StyleKitContract.pairs(for: self).filter { !$0.holds }
    }

    /// The reason this kit may not be worn, or nil when it holds every floor.
    public var rejection: StyleKitRejection? {
        violations.first.map { StyleKitRejection.illegible("\($0.label) is \(String(format: "%.2f", $0.ratio)):1, needs \($0.floor):1") }
    }
}
