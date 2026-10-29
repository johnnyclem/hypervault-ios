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
        let tagAlpha = 0.10
        for tint in ["emerald-400", "amber-400", "muted-foreground", "accent"] {
            for surface in surfaces {
                let fill = composite(try hex(tint), over: try hex(surface), alpha: tagAlpha)
                let ratio = contrast(try hex(tint), fill)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "A \(tint) tag on \(surface) is \(ratio):1.")
            }
        }
        let decorative: [(String, Color)] = [
            ("violet", Palette.violet), ("cyan", Palette.cyan), ("coral", Palette.coral), ("rose", Palette.rose),
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

    /// Small text on a 12 to 14% `primary` tint (the chip of a manual memory, the Add capsule of the Tools catalog, the
    /// numbered step badges) is `accent`: `primary` over its own 14% fill is 4.08:1 on paper and 3.66:1 on raised paper, the
    /// same known low as above, here recorded where the fill is the tint and not the surface.
    func testSmallTextOnAPrimaryTintIsAccentBecausePrimaryFallsShort() throws {
        let primary = try hex("primary"), accent = try hex("accent")
        for alpha in [0.12, 0.14] {
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
            ("cyan", Palette.cyan, 0x0E7490), ("coral", Palette.coral, 0xC2410C), ("rose", Palette.rose, 0xBE123C),
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

    /// The graph and its legend draw Repository in a brighter orange than its words use: graphics need 3:1, and the deep
    /// shade is too near Agent's amber to tell apart. Held at 3:1 on the page and on paper in the light look.
    func testTheGraphsRepositoryOrangeStaysApartFromAgentAndHoldsAsAGraphic() throws {
        let light = UITraitCollection(userInterfaceStyle: .light)
        func resolved(_ color: Color) -> UInt32 { DesignTokensTests.hex(of: UIColor(color).resolvedColor(with: light)) }
        let repository = resolved(MemoryStyle.graphTint(forSource: "github"))
        DesignTokensTests.assertSame(repository, 0xEA580C, "Repository on the graph in the light look")
        for surface in ["background", "card"] {
            let ratio = contrast(repository, try XCTUnwrap(HVTokens.lightColors[surface]))
            XCTAssertGreaterThanOrEqual(ratio, 3, "Repository on \(surface) is \(ratio):1 as a graphic in the light look.")
        }
        // The words of the chip keep the deep shade, which is not the graph's.
        XCTAssertNotEqual(resolved(MemoryStyle.ink(forSource: "github")), repository)
        // And the other kinds are what they were.
        for source in ["manual", "chat", "coding", "agent", "file", "web"] {
            XCTAssertEqual(resolved(MemoryStyle.graphTint(forSource: source)), resolved(MemoryStyle.tint(forSource: source)), source)
        }
        // In the dark look Repository is the orange it always was.
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        DesignTokensTests.assertSame(DesignTokensTests.hex(of: UIColor(MemoryStyle.graphTint(forSource: "github")).resolvedColor(with: dark)), 0xF97316, "Repository on the graph in the dark look")
    }

    func testTextOnTheAccentFillIsBodyText() throws {
        XCTAssertGreaterThanOrEqual(contrast(try hex("accent-foreground"), try hex("accent")), 4.5)
    }

    /// The app's own decorative tints, which the web has no token for, are text as well as glyph in places.
    func testTheDecorativeTintsAreAtLeastFourAndAHalfOnEverySurface() throws {
        let tints: [(String, Color)] = [
            ("violet", Palette.violet), ("cyan", Palette.cyan), ("coral", Palette.coral), ("rose", Palette.rose),
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
        DesignTokensTests.assertSame(resolved(Palette.danger), try hex("destructive"), "Palette.danger")
        DesignTokensTests.assertSame(resolved(Palette.success), try hex("emerald-400"), "Palette.success")
        DesignTokensTests.assertSame(resolved(Palette.warning), try hex("amber-400"), "Palette.warning")
    }
}
