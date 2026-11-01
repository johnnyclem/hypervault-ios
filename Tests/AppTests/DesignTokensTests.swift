import SwiftUI
import UIKit
import XCTest
@testable import HyperVault

/// The stock look is the web's, kept in docs/brand/tokens.json, and the light look is the iOS guide's mirror of it.
/// CI's `gen_tokens.py --check` holds the generated files to that file; these hold what the app compiled to the
/// generated numbers, so a colour set that was edited by hand or left out of a target fails here and not on a phone.
final class DesignTokensTests: XCTestCase {
    private let bundle = Bundle(for: AppModel.self)

    /// The colour a name resolves to under a style, as 0xRRGGBB.
    private func resolved(_ named: String, _ style: UIUserInterfaceStyle) throws -> UInt32 {
        let traits = UITraitCollection(userInterfaceStyle: style)
        let color = try XCTUnwrap(
            UIColor(named: named, in: bundle, compatibleWith: traits),
            "The colour set \(named) is not in the app bundle."
        )
        return Self.hex(of: color.resolvedColor(with: traits))
    }

    static func hex(of color: UIColor) -> UInt32 {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        XCTAssertTrue(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha), "The colour has no RGB form.")
        XCTAssertEqual(alpha, 1, accuracy: 0.001)
        func byte(_ value: CGFloat) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
        return byte(red) << 16 | byte(green) << 8 | byte(blue)
    }

    /// Two colours are the same when no channel is more than one step of 255 apart.
    static func assertSame(_ actual: UInt32, _ expected: UInt32, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        for shift in [UInt32(16), 8, 0] {
            let a = Int((actual >> shift) & 0xFF), e = Int((expected >> shift) & 0xFF)
            XCTAssertLessThanOrEqual(abs(a - e), 1, "\(what): \(String(actual, radix: 16)) is not \(String(expected, radix: 16)).", file: file, line: line)
        }
    }

    func testEveryColourSetHoldsItsTokenInEachLook() throws {
        XCTAssertEqual(HVTokens.stockColors.count, 15, "tokens.json has 15 stock colours.")
        let colors = HVTokens.stockColors.merging(HVTokens.appColors, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(Set(HVTokens.lightColors.keys), Set(colors.keys), "Every colour set has a light slot.")
        for (name, dark) in colors {
            let light = try XCTUnwrap(HVTokens.lightColors[name], "No light value for \(name).")
            Self.assertSame(try resolved(name, .dark), dark, "\(name) in the dark look")
            Self.assertSame(try resolved(name, .light), light, "\(name) in the light look")
            // No appearance named: the Any slot, which is the dark value. Without it UIColor(named:) is nil.
            Self.assertSame(try resolved(name, .unspecified), dark, "\(name) when the style is unspecified")
        }
    }

    func testTheSystemsOwnColoursFollowTheTokens() throws {
        for style in [UIUserInterfaceStyle.dark, .light] {
            let source = style == .dark ? HVTokens.stockColors : HVTokens.lightColors
            let primary = try XCTUnwrap(source["primary"])
            let background = try XCTUnwrap(source["background"])
            let look = style == .dark ? "dark" : "light"
            Self.assertSame(try resolved("AccentColor", style), primary, "AccentColor is primary in the \(look) look")
            Self.assertSame(try resolved("LaunchBackground", style), background, "LaunchBackground is the page in the \(look) look")
        }
        let darkPrimary = try XCTUnwrap(HVTokens.stockColors["primary"])
        let darkPage = try XCTUnwrap(HVTokens.stockColors["background"])
        Self.assertSame(try resolved("AccentColor", .unspecified), darkPrimary, "AccentColor is primary when the style is unspecified")
        Self.assertSame(try resolved("LaunchBackground", .unspecified), darkPage, "LaunchBackground is the page when the style is unspecified")
    }

    /// `HVColor` loads by name, and a misspelt name draws nothing and says nothing.
    func testHVColorReachesTheSetOfTheSameName() throws {
        let members: [(String, Color)] = [
            ("background", HVColor.background), ("foreground", HVColor.foreground),
            ("card", HVColor.card), ("card-foreground", HVColor.cardForeground),
            ("muted", HVColor.muted), ("muted-foreground", HVColor.mutedForeground),
            ("primary", HVColor.primary), ("primary-foreground", HVColor.primaryForeground),
            ("secondary", HVColor.secondary), ("secondary-foreground", HVColor.secondaryForeground),
            ("accent", HVColor.accent), ("accent-foreground", HVColor.accentForeground),
            ("border", HVColor.border), ("ring", HVColor.ring), ("destructive", HVColor.destructive),
            ("emerald-400", HVColor.emerald400), ("amber-400", HVColor.amber400),
            ("memory", HVColor.memory), ("action", HVColor.action),
        ]
        XCTAssertEqual(members.count, HVTokens.stockColors.count + HVTokens.appColors.count)
        let traits = UITraitCollection(userInterfaceStyle: .dark)
        for (name, color) in members {
            let expected = try XCTUnwrap(HVTokens.stockColors[name] ?? HVTokens.appColors[name])
            Self.assertSame(Self.hex(of: UIColor(color).resolvedColor(with: traits)), expected, "HVColor for \(name)")
        }
    }

    func testRadiiAreTheWebsResolvedAtSixteenToTheRem() {
        XCTAssertEqual(HVTokens.RadiusPx.radius, 12)
        XCTAssertEqual(HVTokens.RadiusPx.radiusXl, 16)
        XCTAssertEqual(HVTokens.RadiusPx.radius2xl, 20)
        XCTAssertEqual(HVTokens.RadiusPx.radius3xl, 28)
    }

    /// The radii are the web's roles, read from the tokens where the web has one.
    func testTheRadiiAreTheWebsRoles() {
        XCTAssertEqual(HV.Radius.control, 8)
        XCTAssertEqual(HV.Radius.smallControl, 6)
        XCTAssertEqual(HV.Radius.card, HVTokens.RadiusPx.radiusXl)
        XCTAssertEqual(HV.Radius.surface, HVTokens.RadiusPx.radius2xl)
        XCTAssertEqual(HV.Radius.sheet, HVTokens.RadiusPx.radius3xl)
        XCTAssertEqual(HV.Radius.brandTile, 5)
        XCTAssertEqual(HV.Radius.l, HV.Radius.surface)
        XCTAssertEqual(HV.Radius.xl, HV.Radius.sheet)
    }

    /// `s` and `m` stay as names so call sites compile, and are the control and card radii; moving either moves every
    /// corner that still uses it. `floating` is the app's own role for glass over content, and the tile of a list row
    /// is one size in every list.
    func testTheOlderRadiusNamesAreAliasesAndTheFloatingRoleAndRowTileAreFixed() {
        XCTAssertEqual(HV.Radius.s, HV.Radius.control)
        XCTAssertEqual(HV.Radius.m, HV.Radius.card)
        XCTAssertEqual(HV.Radius.floating, 24)
        XCTAssertEqual(HV.rowTile, 36)
    }

    func testTheCodePanelAndTheCardBrandsAreFixed() {
        XCTAssertEqual(HVTokens.Fixed.docPanelBackground, 0x14161B)
        XCTAssertEqual(HVTokens.Fixed.docPanelForeground, 0xE6E8EC)
        XCTAssertEqual(HVTokens.Fixed.docPanelBorder, 0xFFFFFF)
        XCTAssertEqual(HVTokens.Fixed.docPanelBorderOpacity, 0.06, accuracy: 0.0001)
        XCTAssertEqual(HVTokens.Fixed.cardVisa, 0x1A1F71)
        XCTAssertEqual(HVTokens.Fixed.cardAmex, 0x006FCF)
        XCTAssertEqual(HVTokens.Fixed.cardDiscover, 0xE55C20)
        XCTAssertEqual(HVTokens.Fixed.cardMastercard, 0x1C1C1E)
        XCTAssertEqual(HVTokens.Fixed.cardMastercardLeft, 0xEB001B)
        XCTAssertEqual(HVTokens.Fixed.cardMastercardRight, 0xF79E1B)
        XCTAssertEqual(HVTokens.Fixed.cardMastercardRightOpacity, 0.9, accuracy: 0.0001)
    }
}
