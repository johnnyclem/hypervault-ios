import Foundation

/// The four hues the app draws that the web has no token for, so no kit carries them: the memory violet and the three
/// model-family tones in Chat (coral, cyan, rose). The app keeps its own values for them, one for each look, and this
/// moves one along its own hue, lighter or darker, only when a kit's surfaces would leave it short of the floors the stock
/// look holds them to. A kit whose surfaces they already read on gets them back byte for byte.
public struct StyleKitHues: Sendable, Equatable {
    public var memory: RGB
    public var coral: RGB
    public var cyan: RGB
    public var rose: RGB

    public init(memory: RGB, coral: RGB, cyan: RGB, rose: RGB) {
        self.memory = memory
        self.coral = coral
        self.cyan = cyan
        self.rose = rose
    }

    /// `HV.Tint.fill`: the share of its own colour a tag's fill shows. An app test holds the two equal.
    public static let tintFill = 0.10
    /// The least a hue may contrast with its own tag fill. A chosen low, not the stock look's bar: the stock look holds
    /// tag text at 4.5:1 over its own fill (`DesignContrastTests`), and the four hues here are held to 3.5 because they
    /// cannot always reach more on a kit's surfaces without leaving their colour (the stock light look's own lowest tag
    /// pair is 3.88:1, coral on raised paper). The kit's own colours (`muted_foreground`, `accent`, `success`,
    /// `warning`) are not checked as tag text at all: the shared contract (docs/stylekit.md 5.5) holds them as ink on
    /// the surfaces, not on their own tint. Over the 38 served kits 62 of the 456 such pairs are under 4.5:1 and the
    /// lowest is 3.88:1 (swiss-minimalist's accent on raised paper); `testTheKitsOwnTagTextIsRecordedNotHeldAtFourAndAHalf`
    /// pins that, so a worn kit can sit below the stock look's bar and nothing here claims otherwise.
    static let tagFloor = 3.5

    /// The app's own values: `HVTokens.appColors["memory"]` and the dark slot of `ChatAgentTone` for the dark look,
    /// `HVTokens.lightColors["memory"]` and the 700 shades for the light one. An app test holds them to those.
    public static func stock(_ appearance: StyleAppearance) -> StyleKitHues {
        switch appearance {
        case .dark: return StyleKitHues(memory: RGB(hex: 0xA78BFA), coral: RGB(hex: 0xF97316), cyan: RGB(hex: 0x22D3EE), rose: RGB(hex: 0xFB7185))
        case .light: return StyleKitHues(memory: RGB(hex: 0x6D28D9), coral: RGB(hex: 0xC2410C), cyan: RGB(hex: 0x0E7490), rose: RGB(hex: 0xBE123C))
        }
    }

    /// What a hue must hold on a kit's three surfaces: text at 4.5:1 on the page and on paper and 4.0:1 on raised paper
    /// (where the stock look records its own lows), and, as a tag's text over its own 10% fill, 3.5:1 on all three (the
    /// stock light look's own lowest tag pair is 3.88:1, coral on raised paper). The result is `ratio / floor` at its
    /// tightest pair; 1 or more passes.
    static func margin(_ colour: RGB, on colors: StyleKitColors) -> Double {
        var worst = Double.infinity
        for (index, surface) in colors.surfaces.enumerated() {
            worst = min(worst, colour.contrast(with: surface) / (index == 2 ? 4.0 : 4.5))
            worst = min(worst, colour.contrast(with: colour.composited(over: surface, alpha: tintFill)) / tagFloor)
        }
        return worst
    }

    /// The nearest colour of `colour`'s hue and saturation that passes, trying lighter first on a dark kit and darker
    /// first on a light one, then the other way (0.5% steps of lightness); the kit's own text colour when neither side
    /// gets there, which the kit's floors guarantee reads on every surface.
    static func settle(_ colour: RGB, on kit: StyleKit) -> RGB {
        if margin(colour, on: kit.colors) >= 1 { return colour }
        let (hue, saturation, start) = colour.hsl
        let sides: [Double] = kit.appearance == .dark ? [0.005, -0.005] : [-0.005, 0.005]
        for step in sides {
            var lightness = start
            while true {
                lightness = min(max(lightness + step, 0), 1)
                let candidate = RGB(hue: hue, saturation: saturation, lightness: lightness)
                if margin(candidate, on: kit.colors) >= 1 { return candidate }
                if lightness == 0 || lightness == 1 { break }
            }
        }
        return kit.colors.foreground
    }

    /// The app's hues for this kit's appearance, moved only as far as its surfaces need.
    public static func resolve(for kit: StyleKit) -> StyleKitHues {
        let stock = stock(kit.appearance)
        return StyleKitHues(
            memory: settle(stock.memory, on: kit), coral: settle(stock.coral, on: kit),
            cyan: settle(stock.cyan, on: kit), rose: settle(stock.rose, on: kit)
        )
    }
}

extension StyleKit {
    /// The memory violet and the model-family tones for this kit.
    public var hues: StyleKitHues { StyleKitHues.resolve(for: self) }
}
