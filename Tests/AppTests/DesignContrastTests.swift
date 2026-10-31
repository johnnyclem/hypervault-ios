import SwiftUI
import UIKit
import XCTest
@testable import HyperVault

/// Contrast is not guaranteed by the tokens (handoff 2.1), so the pairs the app draws text in are held here at the
/// WCAG ratios: 4.5:1 for body text, 3:1 for the bold and large exceptions, each recorded where it is made. A colour
/// that drifts, or a new text colour on an old surface, fails here.
final class DesignContrastTests: XCTestCase {
    private func hex(_ token: String) throws -> UInt32 {
        try XCTUnwrap(HVTokens.stockColors[token] ?? HVTokens.appColors[token], "No colour called \(token).")
    }

    /// A `Color` resolved in the dark look. Decorative tints that are colour sets would otherwise follow the host.
    private func hex(of color: Color) -> UInt32 {
        DesignTokensTests.hex(of: UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)))
    }

    /// WCAG 2.x relative luminance of 0xRRGGBB.
    private func luminance(_ value: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let c = Double((value >> shift) & 0xFF) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }

    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (light, dark) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (light + 0.05) / (dark + 0.05)
    }

    /// `tint` laid over `surface` at `alpha`, as 0xRRGGBB: what a tag's fill looks like on the paper it sits on.
    private func composite(_ tint: UInt32, over surface: UInt32, alpha: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let top = Double((tint >> shift) & 0xFF), under = Double((surface >> shift) & 0xFF)
            return UInt32((alpha * top + (1 - alpha) * under).rounded())
        }
        return channel(16) << 16 | channel(8) << 8 | channel(0)
    }

    private let surfaces = ["background", "card", "muted"]

    func testBodyTextIsAtLeastFourAndAHalfOnThePageOnPaperAndOnRaisedPaper() throws {
        for text in ["foreground", "muted-foreground", "accent", "emerald-400", "amber-400"] {
            for surface in surfaces {
                let ratio = contrast(try hex(text), try hex(surface))
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(text) on \(surface) is \(ratio):1.")
            }
        }
    }

    func testThePrimaryAndTheDestructiveColourAreTextOnThePageAndOnPaper() throws {
        for text in ["primary", "destructive"] {
            for surface in ["background", "card"] {
                let ratio = contrast(try hex(text), try hex(surface))
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(text) on \(surface) is \(ratio):1.")
            }
        }
    }

    /// Known lows, recorded so that they are chosen and not stumbled on: as text on raised paper (a field, a tile, the
    /// selected pill) these two fall a little under 4.5:1. Tinted text on raised paper uses `accent` (7.48:1).
    func testTheKnownLowsOnRaisedPaperAreWhatTheyWereRecordedAs() throws {
        let muted = try hex("muted")
        XCTAssertEqual(contrast(try hex("primary"), muted), 4.36, accuracy: 0.01)
        XCTAssertEqual(contrast(try hex("destructive"), muted), 4.26, accuracy: 0.01)
    }

    /// The handoff's recorded exception (2.1, 9): white on the web's `primary` is 3.68:1. That is under 4.5:1 for body
    /// text and over the 3:1 that bold text needs, so a label on the flat primary fill is bold (`HVPrimaryButtonStyle`)
    /// and nothing at body weight is put on it. The same holds for white on `destructive` (3.76:1).
    func testWhiteOnThePrimaryAndTheDestructiveFillIsTheDocumentedException() throws {
        let onPrimary = contrast(try hex("primary-foreground"), try hex("primary"))
        XCTAssertEqual(onPrimary, 3.68, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(onPrimary, 3.0)
        let onDestructive = contrast(try hex("primary-foreground"), try hex("destructive"))
        XCTAssertEqual(onDestructive, 3.76, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(onDestructive, 3.0)
    }

    /// `HVTag`: the colour as text over the same colour at 10% (the web's status chips), on each surface a tag sits on.
    func testTagTextIsAtLeastFourAndAHalfOverItsOwnFill() throws {
        let tagAlpha = HV.Tint.fill
        for tint in ["emerald-400", "amber-400", "muted-foreground", "accent"] {
            for surface in surfaces {
                let fill = composite(try hex(tint), over: try hex(surface), alpha: tagAlpha)
                let ratio = contrast(try hex(tint), fill)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "A \(tint) tag on \(surface) is \(ratio):1.")
            }
        }
        let decorative: [(String, Color)] = [
            ("violet", Palette.violet),
            // The three hues the palette has no token for are a model family's colour and live in `ChatAgentTone`.
            ("chat coral", ChatAgentTone.coral.color), ("chat cyan", ChatAgentTone.cyan.color), ("chat rose", ChatAgentTone.rose.color),
        ]
        for (name, tint) in decorative {
            for surface in surfaces {
                let fill = composite(hex(of: tint), over: try hex(surface), alpha: tagAlpha)
                let ratio = contrast(hex(of: tint), fill)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "A \(name) tag on \(surface) is \(ratio):1.")
            }
        }
    }

    /// Known lows, as for text on raised paper: a `primary` or `destructive` tag on paper is a little under 4.5:1
    /// (caption size, semibold). The words in a tag carry the meaning, and the colour only echoes it.
    func testThePrimaryAndDestructiveTagsOnPaperAreWhatTheyWereRecordedAs() throws {
        let card = try hex("card")
        for (token, recorded) in [("primary", 4.31), ("destructive", 4.35)] {
            let fill = composite(try hex(token), over: card, alpha: 0.10)
            XCTAssertEqual(contrast(try hex(token), fill), recorded, accuracy: 0.02, "A \(token) tag on card.")
        }
    }

    /// Small text on a `primary` tint (the Add capsule of the Tools catalog, the numbered step badges) is `accent`:
    /// `primary` over its own 14% fill is 4.08:1 on paper and 3.66:1 on raised paper, the same known low as above, here
    /// recorded where the fill is the tint and not the surface. The step the app draws is `HV.Tint.fill`; 12% and 14% are
    /// kept as the older steps (the import guide's step disc is still 14%).
    func testSmallTextOnAPrimaryTintIsAccentBecausePrimaryFallsShort() throws {
        let primary = try hex("primary"), accent = try hex("accent")
        for alpha in [HV.Tint.fill, 0.12, 0.14] {
            for surface in surfaces {
                let fill = composite(primary, over: try hex(surface), alpha: alpha)
                let ratio = contrast(accent, fill)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "Accent text on primary at \(alpha) over \(surface) is \(ratio):1.")
            }
        }
        let paper = composite(primary, over: try hex("card"), alpha: 0.14)
        XCTAssertEqual(contrast(primary, paper), 4.08, accuracy: 0.02, "Primary text on its own 14% tint over card.")
        let raised = composite(primary, over: try hex("muted"), alpha: 0.14)
        XCTAssertEqual(contrast(primary, raised), 3.66, accuracy: 0.02, "Primary text on its own 14% tint over muted.")
    }

    /// The light look (the iOS guide's mirror). Body text holds 4.5:1 on the page, on paper and on raised paper,
    /// except the four pairs recorded underneath, which fall short by a little and are chosen, not stumbled on.
    /// White on the light `primary` and `destructive` fills clears 4.5:1, unlike the dark look's bold-only exception.
    func testTheLightLookHoldsBodyTextExceptTheRecordedLows() throws {
        let light = HVTokens.lightColors
        func value(_ name: String) throws -> UInt32 { try XCTUnwrap(light[name]) }
        let surfaces = ["background", "card", "muted"]
        let lows: Set<String> = [
            "primary on muted", "destructive on background", "destructive on muted", "amber-400 on muted",
        ]
        for text in ["foreground", "muted-foreground", "accent", "emerald-400", "amber-400", "memory", "primary", "destructive"] {
            for surface in surfaces {
                let pair = "\(text) on \(surface)"
                let ratio = contrast(try value(text), try value(surface))
                if lows.contains(pair) { continue }
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(pair) is \(ratio):1 in the light look.")
            }
        }
        XCTAssertEqual(contrast(try value("primary"), try value("muted")), 4.43, accuracy: 0.02)
        XCTAssertEqual(contrast(try value("destructive"), try value("background")), 4.50, accuracy: 0.02)
        XCTAssertEqual(contrast(try value("destructive"), try value("muted")), 4.14, accuracy: 0.02)
        XCTAssertEqual(contrast(try value("amber-400"), try value("muted")), 4.31, accuracy: 0.02)
        XCTAssertGreaterThanOrEqual(contrast(try value("primary-foreground"), try value("primary")), 4.5)
        XCTAssertGreaterThanOrEqual(contrast(try value("primary-foreground"), try value("destructive")), 4.5)
        XCTAssertGreaterThanOrEqual(contrast(try value("accent-foreground"), try value("accent")), 4.5)
    }

    /// The decorative tints have a light shade of their own, the 700 that emerald, amber and violet mirror to, so they
    /// stay text and glyph in the light look: 4.5:1 on the page and on paper, and a little under on raised paper
    /// (orange-700 is 4.44:1 there), recorded here.
    func testTheDecorativeTintsHoldInTheLightLookToo() throws {
        let light = UITraitCollection(userInterfaceStyle: .light)
        func resolved(_ color: Color) -> UInt32 { DesignTokensTests.hex(of: UIColor(color).resolvedColor(with: light)) }
        let tints: [(String, Color, UInt32)] = [
            ("chat cyan", ChatAgentTone.cyan.color, 0x0E7490), ("chat coral", ChatAgentTone.coral.color, 0xC2410C),
            ("chat rose", ChatAgentTone.rose.color, 0xBE123C),
            ("violet", Palette.violet, try XCTUnwrap(HVTokens.lightColors["memory"])),
        ]
        for (name, tint, expected) in tints {
            DesignTokensTests.assertSame(resolved(tint), expected, "\(name) in the light look")
            for surface in ["background", "card"] {
                let ratio = contrast(resolved(tint), try XCTUnwrap(HVTokens.lightColors[surface]))
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(name) on \(surface) is \(ratio):1 in the light look.")
            }
            let onRaised = contrast(resolved(tint), try XCTUnwrap(HVTokens.lightColors["muted"]))
            XCTAssertGreaterThanOrEqual(onRaised, 4.4, "\(name) on muted is \(onRaised):1 in the light look.")
        }
    }

    /// The Memory map draws four hues that sit well apart (You blue, Chat violet, File mint, Agent amber) and the grey text
    /// role for the rest (Coding, Repository, Web, a source it does not know), which its legend and its callout name. The
    /// separate Repository orange that stood apart from Agent's amber is gone with the hue itself. Each colour is held at
    /// 3:1 as a graphic on the page and on paper in both looks.
    func testTheMemoryMapDrawsFourHuesAndGreyForTheRest() throws {
        let fourHues: [(String, Color)] = [
            ("manual", Palette.blue), ("chat", Palette.violet), ("agent", Palette.amber), ("file", Palette.mint),
        ]
        let greys = ["coding", "github", "web", "a source nothing knows"]
        let looks: [(String, UIUserInterfaceStyle)] = [("dark", .dark), ("light", .light)]
        for (look, style) in looks {
            let traits = UITraitCollection(userInterfaceStyle: style)
            func resolved(_ color: Color) -> UInt32 { DesignTokensTests.hex(of: UIColor(color).resolvedColor(with: traits)) }
            func surface(_ name: String) throws -> UInt32 {
                if style == .dark { return try hex(name) }
                return try XCTUnwrap(HVTokens.lightColors[name])
            }
            for (source, expected) in fourHues {
                XCTAssertEqual(resolved(MemoryStyle.graphTint(forSource: source)), resolved(expected), "\(source) in the \(look) look")
            }
            for source in greys {
                XCTAssertEqual(resolved(MemoryStyle.graphTint(forSource: source)), resolved(Palette.textSecondary), "\(source) in the \(look) look")
            }
            for source in fourHues.map({ $0.0 }) + greys {
                for name in ["background", "card"] {
                    let ratio = contrast(resolved(MemoryStyle.graphTint(forSource: source)), try surface(name))
                    XCTAssertGreaterThanOrEqual(ratio, 3, "\(source) on \(name) is \(ratio):1 as a graphic in the \(look) look.")
                }
            }
        }
    }

    func testTextOnTheAccentFillIsBodyText() throws {
        XCTAssertGreaterThanOrEqual(contrast(try hex("accent-foreground"), try hex("accent")), 4.5)
    }

    /// `Palette.action` is the one flat fill under white text and white glyphs at body size (the person's chat bubble, the
    /// send buttons, the prominent icon button, the count in the Account menu). It is #2563EB in both looks, the web's
    /// light-look `primary`, and white on it is 5.17:1 in each: no bold needed, unlike the dark look's own `primary`
    /// (3.68:1), which is why it is a token of its own and not `primary`.
    func testWhiteOnTheActionFillIsBodyTextInBothLooks() throws {
        let light = HVTokens.lightColors
        let darkAction = try hex("action"), lightAction = try XCTUnwrap(light["action"])
        XCTAssertEqual(darkAction, 0x2563EB)
        XCTAssertEqual(lightAction, 0x2563EB)
        XCTAssertEqual(lightAction, try XCTUnwrap(light["primary"]), "In the light look `action` is the web's `primary`.")
        let white = try hex("primary-foreground"), lightWhite = try XCTUnwrap(light["primary-foreground"])
        XCTAssertEqual(white, 0xFFFFFF)
        XCTAssertEqual(lightWhite, 0xFFFFFF)
        let onDark = contrast(white, darkAction), onLight = contrast(lightWhite, lightAction)
        XCTAssertEqual(onDark, 5.17, accuracy: 0.01)
        XCTAssertEqual(onLight, 5.17, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(onDark, 4.5, "White on action in the dark look.")
        XCTAssertGreaterThanOrEqual(onLight, 4.5, "White on action in the light look.")
        // And the dark look's `primary` is the one that needs it: it only clears 3:1.
        XCTAssertLessThan(contrast(white, try hex("primary")), 4.5)
    }

    /// The tint ladder is one fill and one edge for a tag, a notice, a disc and a badge: the web's status chip, 10% with a
    /// 40% edge (`HV.Tint`). The tag test above reads the fill from the ladder, so a step up that sends the grey tag on
    /// raised paper under 4.5:1 fails there. Small text on a `primary` tint is `accent`, which holds at this step on
    /// every surface.
    func testTheTintLadderIsOneFillAndOneEdge() throws {
        XCTAssertEqual(HV.Tint.fill, 0.10, accuracy: 0.0001)
        XCTAssertEqual(HV.Tint.border, 0.40, accuracy: 0.0001)
        let primary = try hex("primary"), accent = try hex("accent")
        for surface in surfaces {
            let tint = composite(primary, over: try hex(surface), alpha: HV.Tint.fill)
            let ratio = contrast(accent, tint)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "Accent text on a primary tint over \(surface) is \(ratio):1.")
        }
    }

    /// The tint ladder in the light look. The 10% fill gives a tag, a disc or a badge text of 4.5:1 or better on most
    /// surfaces, and the pairs listed here fall a little under it: the light shades of emerald and amber are the 700s the
    /// web mirrors to, and amber is the lowest (3.80:1 on raised paper). They are recorded, as the other light lows are, so
    /// that a change to a light value or to `HV.Tint.fill` that moves any pair fails here and is not stumbled on. The words
    /// of a tag carry the meaning and the colour only echoes it.
    func testTheTintLadderInTheLightLookHoldsExceptTheRecordedLows() throws {
        let light = HVTokens.lightColors
        func value(_ name: String) throws -> UInt32 { try XCTUnwrap(light[name]) }
        let lows: [String: Double] = [
            "emerald-400 on background": 4.45, "emerald-400 on muted": 4.11,
            "amber-400 on background": 4.10, "amber-400 on card": 4.39, "amber-400 on muted": 3.80,
            "accent on muted": 4.45,
        ]
        for tint in ["emerald-400", "amber-400", "muted-foreground", "accent"] {
            for surface in ["background", "card", "muted"] {
                let pair = "\(tint) on \(surface)"
                let fill = composite(try value(tint), over: try value(surface), alpha: HV.Tint.fill)
                let ratio = contrast(try value(tint), fill)
                if let recorded = lows[pair] {
                    XCTAssertEqual(ratio, recorded, accuracy: 0.02, "A \(pair) tag in the light look.")
                } else {
                    XCTAssertGreaterThanOrEqual(ratio, 4.5, "A \(pair) tag is \(ratio):1 in the light look.")
                }
            }
        }
        // Small text on a `primary` tint is `accent`: 4.5:1 or better on the page and on paper, 4.46:1 on raised paper.
        let primary = try value("primary"), accent = try value("accent")
        for surface in ["background", "card"] {
            let ratio = contrast(accent, composite(primary, over: try value(surface), alpha: HV.Tint.fill))
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "Accent text on a primary tint over \(surface) is \(ratio):1 in the light look.")
        }
        let onRaised = contrast(accent, composite(primary, over: try value("muted"), alpha: HV.Tint.fill))
        XCTAssertEqual(onRaised, 4.46, accuracy: 0.02, "Accent text on a primary tint over muted in the light look.")
    }

    /// The app's own decorative tints, which the web has no token for, are text as well as glyph in places.
    func testTheDecorativeTintsAreAtLeastFourAndAHalfOnEverySurface() throws {
        let tints: [(String, Color)] = [
            ("violet", Palette.violet),
            // The three hues the palette has no token for are a model family's colour and live in `ChatAgentTone`.
            ("chat coral", ChatAgentTone.coral.color), ("chat cyan", ChatAgentTone.cyan.color), ("chat rose", ChatAgentTone.rose.color),
        ]
        for (name, tint) in tints {
            for surface in surfaces {
                let ratio = contrast(hex(of: tint), try hex(surface))
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(name) on \(surface) is \(ratio):1.")
            }
        }
    }

    /// `Palette` is the one door the screens use; its members must be the tokens they are named for.
    func testThePaletteIsBuiltFromTheTokens() throws {
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        func resolved(_ color: Color) -> UInt32 { DesignTokensTests.hex(of: UIColor(color).resolvedColor(with: dark)) }
        DesignTokensTests.assertSame(resolved(Palette.background), try hex("background"), "Palette.background")
        DesignTokensTests.assertSame(resolved(Palette.surface), try hex("card"), "Palette.surface")
        DesignTokensTests.assertSame(resolved(Palette.surfaceRaised), try hex("muted"), "Palette.surfaceRaised")
        DesignTokensTests.assertSame(resolved(Palette.textPrimary), try hex("foreground"), "Palette.textPrimary")
        DesignTokensTests.assertSame(resolved(Palette.textSecondary), try hex("muted-foreground"), "Palette.textSecondary")
        // The colour of a field's prompt (`Text.hvPrompt`): the same token, so the 4.5:1 above holds it on every surface.
        DesignTokensTests.assertSame(resolved(Palette.textTertiary), try hex("muted-foreground"), "Palette.textTertiary")
        DesignTokensTests.assertSame(resolved(Palette.blue), try hex("primary"), "Palette.blue")
        DesignTokensTests.assertSame(resolved(Palette.sky), try hex("accent"), "Palette.sky")
        DesignTokensTests.assertSame(resolved(Palette.action), try hex("action"), "Palette.action")
        DesignTokensTests.assertSame(resolved(Palette.danger), try hex("destructive"), "Palette.danger")
        DesignTokensTests.assertSame(resolved(Palette.success), try hex("emerald-400"), "Palette.success")
        DesignTokensTests.assertSame(resolved(Palette.warning), try hex("amber-400"), "Palette.warning")
    }
}
