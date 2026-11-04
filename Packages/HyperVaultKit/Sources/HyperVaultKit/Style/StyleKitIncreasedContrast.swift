import Foundation

/// What a kit looks like when the person has turned on Increase Contrast (Settings > Accessibility > Display & Text Size).
///
/// The server sends one palette per theme, held to 4.5:1 (docs/stylekit.md 5.5), and no Increase Contrast set: only HyperVault
/// Light declares one on the web, and a 7:1 clamp for the rest is on the server's list of things it may do later (section 12).
/// The phone should not wait for that, so the app derives the set itself, from the kit it was sent, and never refuses a kit for
/// it: this is a best effort on top of a palette that already holds the shared floors.
///
///   * Ink (`foreground`, `muted_foreground`, `primary`, `accent`, `destructive`, `success`, `warning`) moves along its own hue
///     and saturation, away from the surfaces, until it reads 7:1 on the surfaces the shared contract holds it to.
///   * Surfaces never move, as on the server.
///   * `action` is the fill as the theme designed it; its label is the theme's own when that reads 7:1, else black or white,
///     whichever reads better.
///   * `border` and `ring` are the edges the app draws at 60% and 50% (`Palette.border`, a focused field): they are moved until
///     the edge as it is drawn is 3:1 against the page and paper.
///
/// A colour that already clears its bar comes back byte for byte, and no colour ever gets less contrast than it had, so the
/// result holds everything the standard set holds. A colour that cannot reach its bar (a mid-tone page that neither black nor
/// white reads 7:1 on) is the best the search found, never a failure. Pure arithmetic on `RGB`, so it is tested on Linux.
public enum StyleKitIncreasedContrast {
    /// The ratio text is moved to; the web's `prefers-contrast: more` block asks for 7:1 (AAA) for body text.
    public static let inkFloor = 7.0
    /// The ratio an edge is moved to, as drawn.
    public static let edgeFloor = 3.0
    /// How much of `border` the app draws (`Palette.border`).
    public static let borderStrength = 0.6
    /// How much of `ring` a focused field draws (`hvFieldChrome`).
    public static let ringStrength = 0.5

    /// The kit's colours under Increase Contrast.
    public static func colors(for kit: StyleKit) -> StyleKitColors {
        let base = kit.colors
        var out = base
        let towardDark = prefersDarker(base.surfaces)

        for (role, surfaces, _) in StyleKitContract.ink {
            let on = surfaces.map { base[$0] }
            out[role] = lift(base[role], floor: inkFloor, towardDark: towardDark) { ink in
                on.map { ink.contrast(with: $0) }.min() ?? inkFloor
            }
        }

        if base.actionForeground.contrast(with: base.action) < inkFloor {
            let better = base.action.legibleLabel
            if better.contrast(with: base.action) > base.actionForeground.contrast(with: base.action) {
                out.actionForeground = better
            }
        }

        let edges = [base.background, base.card]
        out.border = lift(base.border, floor: edgeFloor, towardDark: towardDark) { edge in
            edges.map { edge.composited(over: $0, alpha: borderStrength).contrast(with: $0) }.min() ?? edgeFloor
        }
        out.ring = lift(base.ring, floor: edgeFloor, towardDark: towardDark) { edge in
            edges.map { edge.composited(over: $0, alpha: ringStrength).contrast(with: $0) }.min() ?? edgeFloor
        }
        return out
    }

    /// The app's own four hues (memory, coral, cyan, rose) under Increase Contrast: ink on the kit's three surfaces, like the
    /// kit's own ink. `hues` is what the standard set wears.
    public static func hues(for kit: StyleKit, from hues: StyleKitHues) -> StyleKitHues {
        let surfaces = kit.colors.surfaces
        let towardDark = prefersDarker(surfaces)
        func ink(_ colour: RGB) -> RGB {
            lift(colour, floor: inkFloor, towardDark: towardDark) { candidate in
                surfaces.map { candidate.contrast(with: $0) }.min() ?? inkFloor
            }
        }
        return StyleKitHues(memory: ink(hues.memory), coral: ink(hues.coral), cyan: ink(hues.cyan), rose: ink(hues.rose))
    }

    /// Whether ink on these surfaces should get darker (they are light on the whole) or lighter. 0.179 is where black and white
    /// are equally far from a surface, the server's own threshold for its clamp (docs/stylekit.md 5.6).
    static func prefersDarker(_ surfaces: [RGB]) -> Bool {
        guard !surfaces.isEmpty else { return false }
        return surfaces.map(\.luminance).reduce(0, +) / Double(surfaces.count) > 0.179
    }

    /// `colour` when it scores `floor` already; else the nearest colour of its hue and saturation that does, trying
    /// `towardDark` first and the other way second, in steps of half a percent of lightness; else the best-scoring colour seen,
    /// which is where the search was heading (black or white).
    static func lift(_ colour: RGB, floor: Double, towardDark: Bool, score: (RGB) -> Double) -> RGB {
        let slack = StyleKitContract.tolerance
        var best = colour
        var bestScore = score(colour)
        if bestScore + slack >= floor { return colour }
        let (hue, saturation, start) = colour.hsl
        for step in towardDark ? [-0.005, 0.005] : [0.005, -0.005] {
            var lightness = start
            while true {
                lightness = min(max(lightness + step, 0), 1)
                let candidate = RGB(hue: hue, saturation: saturation, lightness: lightness)
                let candidateScore = score(candidate)
                if candidateScore + slack >= floor { return candidate }
                if candidateScore > bestScore {
                    best = candidate
                    bestScore = candidateScore
                }
                if lightness == 0 || lightness == 1 { break }
            }
        }
        return best
    }
}

extension StyleKit {
    /// The colours to draw when Increase Contrast is on (`StyleKitIncreasedContrast`).
    public var highContrast: StyleKitColors { StyleKitIncreasedContrast.colors(for: self) }

    /// The memory violet and the model-family tones under Increase Contrast, from the standard set `hues`.
    public var highContrastHues: StyleKitHues { StyleKitIncreasedContrast.hues(for: self, from: hues) }
}
