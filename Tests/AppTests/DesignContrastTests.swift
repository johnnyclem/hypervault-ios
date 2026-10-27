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

    private func hex(of color: Color) -> UInt32 {
        DesignTokensTests.hex(of: UIColor(color))
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
        DesignTokensTests.assertSame(resolved(Palette.blue), try hex("primary"), "Palette.blue")
        DesignTokensTests.assertSame(resolved(Palette.sky), try hex("accent"), "Palette.sky")
        DesignTokensTests.assertSame(resolved(Palette.danger), try hex("destructive"), "Palette.danger")
        DesignTokensTests.assertSame(resolved(Palette.success), try hex("emerald-400"), "Palette.success")
        DesignTokensTests.assertSame(resolved(Palette.warning), try hex("amber-400"), "Palette.warning")
    }
}
