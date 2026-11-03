import HyperVaultKit
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import HyperVault

/// A flag a `@Sendable` observation callback can set.
private final class ToldFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

/// The look being worn is the process's, so every test here puts the stock look back, whatever it did.
@MainActor
class StyleRuntimeTestCase: XCTestCase {
    override func setUp() {
        super.setUp()
        StyleRuntime.shared.apply(nil)
    }

    override func tearDown() {
        StyleRuntime.shared.apply(nil)
        super.tearDown()
    }
}

/// `Palette`, `HVColor` and `HV.Radius` follow the kit that is worn, and are the stock look when none is.
final class StyleRuntimeTests: StyleRuntimeTestCase {
    // MARK: What each member is under a kit

    private struct Expectation {
        let name: String
        let color: Color
        let expected: (RGB, alpha: CGFloat)
    }

    /// Every `Palette` member, with what it is for `kit` under `colors` (the standard set, or the Increase Contrast one) and
    /// `hues`. Written out, so a member added to `Palette` and not here fails the count below.
    private func paletteMembers(_ colors: StyleKitColors, _ hues: StyleKitHues) -> [Expectation] {
        [
            Expectation(name: "background", color: Palette.background, expected: (colors.background, 1)),
            Expectation(name: "surface", color: Palette.surface, expected: (colors.card, 1)),
            Expectation(name: "surfaceRaised", color: Palette.surfaceRaised, expected: (colors.muted, 1)),
            Expectation(name: "border", color: Palette.border, expected: (colors.border, 0.6)),
            Expectation(name: "controlBorder", color: Palette.controlBorder, expected: (colors.border, 0.7)),
            Expectation(name: "divider", color: Palette.divider, expected: (colors.border, 0.5)),
            Expectation(name: "hairline", color: Palette.hairline, expected: (colors.border, 0.5)),
            Expectation(name: "textPrimary", color: Palette.textPrimary, expected: (colors.foreground, 1)),
            Expectation(name: "textSecondary", color: Palette.textSecondary, expected: (colors.mutedForeground, 1)),
            Expectation(name: "textTertiary", color: Palette.textTertiary, expected: (colors.mutedForeground, 1)),
            Expectation(name: "skeleton", color: Palette.skeleton, expected: (colors.border, 1)),
            Expectation(name: "violet", color: Palette.violet, expected: (hues.memory, 1)),
            Expectation(name: "blue", color: Palette.blue, expected: (colors.primary, 1)),
            Expectation(name: "sky", color: Palette.sky, expected: (colors.accent, 1)),
            Expectation(name: "mint", color: Palette.mint, expected: (colors.success, 1)),
            Expectation(name: "amber", color: Palette.amber, expected: (colors.warning, 1)),
            Expectation(name: "success", color: Palette.success, expected: (colors.success, 1)),
            Expectation(name: "warning", color: Palette.warning, expected: (colors.warning, 1)),
            Expectation(name: "danger", color: Palette.danger, expected: (colors.destructive, 1)),
            Expectation(name: "action", color: Palette.action, expected: (colors.action, 1)),
            Expectation(name: "onAction", color: Palette.onAction, expected: (colors.actionForeground, 1)),
            Expectation(name: "onDestructive", color: Palette.onDestructive, expected: (colors.destructive.legibleLabel, 1)),
        ]
    }

    /// Every `HVColor` member, the same way.
    private func tokenMembers(_ colors: StyleKitColors, _ hues: StyleKitHues) -> [Expectation] {
        [
            Expectation(name: "background", color: HVColor.background, expected: (colors.background, 1)),
            Expectation(name: "foreground", color: HVColor.foreground, expected: (colors.foreground, 1)),
            Expectation(name: "card", color: HVColor.card, expected: (colors.card, 1)),
            Expectation(name: "cardForeground", color: HVColor.cardForeground, expected: (colors.foreground, 1)),
            Expectation(name: "muted", color: HVColor.muted, expected: (colors.muted, 1)),
            Expectation(name: "mutedForeground", color: HVColor.mutedForeground, expected: (colors.mutedForeground, 1)),
            Expectation(name: "primary", color: HVColor.primary, expected: (colors.primary, 1)),
            Expectation(name: "primaryForeground", color: HVColor.primaryForeground, expected: (colors.primary.legibleLabel, 1)),
            Expectation(name: "secondary", color: HVColor.secondary, expected: (colors.mutedForeground, 1)),
            Expectation(name: "secondaryForeground", color: HVColor.secondaryForeground, expected: (colors.background, 1)),
            Expectation(name: "accent", color: HVColor.accent, expected: (colors.accent, 1)),
            Expectation(name: "accentForeground", color: HVColor.accentForeground, expected: (colors.accent.legibleLabel, 1)),
            Expectation(name: "border", color: HVColor.border, expected: (colors.border, 1)),
            Expectation(name: "ring", color: HVColor.ring, expected: (colors.ring, 1)),
            Expectation(name: "destructive", color: HVColor.destructive, expected: (colors.destructive, 1)),
            Expectation(name: "emerald400", color: HVColor.emerald400, expected: (colors.success, 1)),
            Expectation(name: "amber400", color: HVColor.amber400, expected: (colors.warning, 1)),
            Expectation(name: "memory", color: HVColor.memory, expected: (hues.memory, 1)),
            Expectation(name: "action", color: HVColor.action, expected: (colors.action, 1)),
        ]
    }

    private func assertMembers(_ members: [Expectation], contrast: UIAccessibilityContrast, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        for member in members {
            let got = resolveColor(member.color, contrast: contrast)
            DesignTokensTests.assertSame(got.hex, member.expected.0.hex, "\(label) \(member.name)", file: file, line: line)
            XCTAssertEqual(got.alpha, member.expected.alpha, accuracy: 0.01, "\(label) \(member.name)'s alpha", file: file, line: line)
        }
    }

    func testEveryPaletteAndHVColorMemberFollowsTheKit() {
        for kit in [StyleKitFixtures.newsprint, StyleKitFixtures.glassmorphism, StyleKitFixtures.industrial] {
            StyleRuntime.shared.apply(kit)
            let members = paletteMembers(kit.colors, kit.hues)
            let tokens = tokenMembers(kit.colors, kit.hues)
            XCTAssertEqual(members.count, 22, "`Palette` has 22 members; a new one is listed here too.")
            XCTAssertEqual(tokens.count, 19, "`HVColor` has 19 colour members; a new one is listed here too.")
            assertMembers(members, contrast: .normal, "\(kit.id) Palette")
            assertMembers(tokens, contrast: .normal, "\(kit.id) HVColor")
        }
    }

    func testIncreaseContrastSelectsTheKitsHighSet() {
        for kit in [StyleKitFixtures.newsprint, StyleKitFixtures.glassmorphism, StyleKitFixtures.auroraMesh] {
            StyleRuntime.shared.apply(kit)
            assertMembers(paletteMembers(kit.highContrast, kit.highContrastHues), contrast: .high, "\(kit.id) Palette under Increase Contrast")
            assertMembers(tokenMembers(kit.highContrast, kit.highContrastHues), contrast: .high, "\(kit.id) HVColor under Increase Contrast")
        }
        // And the set is a different one: Newsprint's red accent gets darker, Glassmorphism's secondary text lighter.
        StyleRuntime.shared.apply(StyleKitFixtures.newsprint)
        let normal = resolveColor(Palette.sky, contrast: .normal).hex, high = resolveColor(Palette.sky, contrast: .high).hex
        XCTAssertNotEqual(normal, high, "Increase Contrast moves the red accent")
        XCTAssertLessThan(RGB(hex: high).luminance, RGB(hex: normal).luminance)
    }

    func testTheHighSetIsAPlainColourWhereItWouldChangeNothing() {
        // Newsprint's body text is near-black on cream: it reads 7:1 already, so it is the same in both sets.
        StyleRuntime.shared.apply(StyleKitFixtures.newsprint)
        XCTAssertEqual(resolveColor(Palette.textPrimary, contrast: .normal).hex, resolveColor(Palette.textPrimary, contrast: .high).hex)
    }

    func testTheModelFamilyTonesAndTheMemoryVioletAreTheKitsHues() {
        // Industrial's surfaces leave the stock tones short, so its hues are moved along their own hue (StyleKitHues).
        let kit = StyleKitFixtures.industrial
        StyleRuntime.shared.apply(kit)
        let hues = kit.hues
        XCTAssertNotEqual(hues, StyleKitHues.stock(kit.appearance), "the fixture is one where a hue moves")
        DesignTokensTests.assertSame(resolveColor(ChatAgentTone.coral.color).hex, hues.coral.hex, "coral")
        DesignTokensTests.assertSame(resolveColor(ChatAgentTone.cyan.color).hex, hues.cyan.hex, "cyan")
        DesignTokensTests.assertSame(resolveColor(ChatAgentTone.rose.color).hex, hues.rose.hex, "rose")
        DesignTokensTests.assertSame(resolveColor(ChatAgentTone.violet.color).hex, hues.memory.hex, "violet")
    }

    // MARK: The stock look

    func testNoKitIsTheAssetCatalogAndWearingNothingPutsItBack() throws {
        func assertStock(_ when: String) throws {
            let dark = UITraitCollection(userInterfaceStyle: .dark)
            for (name, color) in [
                ("background", HVColor.background), ("foreground", HVColor.foreground), ("primary", HVColor.primary),
                ("destructive", HVColor.destructive), ("action", HVColor.action), ("memory", HVColor.memory),
            ] {
                let expected = try XCTUnwrap(HVTokens.stockColors[name] ?? HVTokens.appColors[name])
                DesignTokensTests.assertSame(DesignTokensTests.hex(of: UIColor(color).resolvedColor(with: dark)), expected, "\(name) \(when)")
            }
            XCTAssertEqual(resolveColor(Palette.onAction, style: .dark).hex, 0xFFFFFF, "white is still the label on the action fill \(when)")
            XCTAssertEqual(resolveColor(Palette.onAction, style: .light).hex, 0xFFFFFF, "in the light look too \(when)")
            XCTAssertEqual(resolveColor(Palette.onDestructive).hex, 0xFFFFFF, "and on the destructive fill \(when)")
            XCTAssertEqual(HV.Radius.card, HVTokens.RadiusPx.radiusXl, when)
            XCTAssertEqual(HV.Radius.surface, HVTokens.RadiusPx.radius2xl, when)
            XCTAssertEqual(HV.Radius.sheet, HVTokens.RadiusPx.radius3xl, when)
            XCTAssertFalse(StyleRuntime.shared.snapshot.isThemed, when)
        }
        try assertStock("before any kit")
        StyleRuntime.shared.apply(StyleKitFixtures.newsprint)
        XCTAssertTrue(StyleRuntime.shared.snapshot.isThemed)
        StyleRuntime.shared.apply(nil)
        try assertStock("after a kit was taken off")
    }

    func testTheStockLookDoesNotAskForAppearanceFontOrWindowInk() {
        let look = StyleRuntime.shared.snapshot
        XCTAssertNil(look.appearance)
        XCTAssertNil(look.window)
        XCTAssertNil(look.themeID)
        XCTAssertEqual(look.font, .system)
        XCTAssertNil(look.font.swiftUIDesign)
        XCTAssertEqual(look.backdrop, .glow, "the wash behind the first screens is the one the app always drew")
    }

    // MARK: What a worn kit asks of the window

    func testAWornKitPinsItsAppearanceAndBringsItsFontBackdropAndWindowInk() throws {
        StyleRuntime.shared.apply(StyleKitFixtures.newsprint)
        var look = StyleRuntime.shared.snapshot
        XCTAssertEqual(look.themeID, "newsprint")
        XCTAssertEqual(look.appearance, .light)
        XCTAssertEqual(look.appearance?.userInterfaceStyle, .light)
        XCTAssertEqual(look.font, .serif)
        XCTAssertEqual(look.font.swiftUIDesign, .serif)
        XCTAssertEqual(look.backdrop, .lines)
        let ink = try XCTUnwrap(look.window)
        let kit = StyleKitFixtures.newsprint
        XCTAssertEqual(ink.tint, kit.colors.primary)
        XCTAssertEqual(ink.quiet, kit.colors.mutedForeground)
        XCTAssertEqual(ink.selected, kit.colors.primary, "a light look selects with primary, as the stock tab bar does")
        XCTAssertEqual(ink.badge, kit.colors.action, "the Mail tab's number is the flat action fill, as the Dreams badge in the Account menu is")
        XCTAssertEqual(ink.onBadge, kit.colors.actionForeground)
        XCTAssertEqual(ink.badgeHigh, kit.highContrast.action)
        XCTAssertEqual(ink.onBadgeHigh, kit.highContrast.actionForeground)

        StyleRuntime.shared.apply(StyleKitFixtures.glassmorphism)
        look = StyleRuntime.shared.snapshot
        XCTAssertEqual(look.appearance, .dark)
        XCTAssertEqual(look.appearance?.userInterfaceStyle, .dark)
        XCTAssertEqual(try XCTUnwrap(look.window).selected, StyleKitFixtures.glassmorphism.colors.foreground, "a dark look selects with the page's own text")

        StyleRuntime.shared.apply(StyleKitFixtures.terminal)
        XCTAssertEqual(StyleRuntime.shared.snapshot.font.swiftUIDesign, .monospaced)
    }

    func testTheCardSurfaceAndSheetRadiiFollowTheKitsBaseAndTheControlsDoNot() {
        // Memory Vault's `--radius` is 24: rounded-xl, 2xl and 3xl are that plus 4, 8 and 16.
        StyleRuntime.shared.apply(StyleKitFixtures.memoryVault)
        XCTAssertEqual(HV.Radius.card, 28)
        XCTAssertEqual(HV.Radius.surface, 32)
        XCTAssertEqual(HV.Radius.sheet, 40)
        XCTAssertEqual(HV.Radius.m, HV.Radius.card, "the older name follows the card")
        XCTAssertEqual(HV.Radius.control, 8)
        XCTAssertEqual(HV.Radius.smallControl, 6)
        XCTAssertEqual(HV.Radius.floating, 24)
        XCTAssertEqual(HV.Radius.brandTile, 5)
        XCTAssertEqual(HV.Radius.inner(of: HV.Radius.card, inset: HV.Space.xs), 20)

        StyleRuntime.shared.apply(StyleKitFixtures.newsprint)
        XCTAssertEqual(HV.Radius.card, 16, "a base of 12 is the stock look's own sizes")
        XCTAssertEqual(HV.Radius.surface, 20)
        XCTAssertEqual(HV.Radius.sheet, 28)
    }

    // MARK: Observation

    func testReadingAColourInsideATrackingScopeIsToldWhenTheLookChanges() {
        let told = ToldFlag()
        withObservationTracking {
            _ = Palette.background
        } onChange: {
            told.set()
        }
        XCTAssertFalse(told.isSet)
        StyleRuntime.shared.apply(StyleKitFixtures.newsprint)
        XCTAssertTrue(told.isSet, "a body that read a Palette colour is re-evaluated when a kit is worn")
    }

    func testEveryDoorToAColourIsTracked() {
        func isTold(_ read: @escaping @Sendable () -> Void) -> Bool {
            let told = ToldFlag()
            withObservationTracking(read, onChange: { told.set() })
            StyleRuntime.shared.apply(StyleKitFixtures.glassmorphism)
            StyleRuntime.shared.apply(nil)
            return told.isSet
        }
        XCTAssertTrue(isTold { _ = HVColor.primary }, "HVColor")
        XCTAssertTrue(isTold { _ = Palette.textSecondary }, "Palette")
        XCTAssertTrue(isTold { _ = Palette.border }, "the edges")
        XCTAssertTrue(isTold { _ = Palette.onAction }, "the label on the action fill")
        XCTAssertTrue(isTold { _ = HV.Radius.card }, "the radii")
        XCTAssertTrue(isTold { _ = ChatAgentTone.coral.color }, "the chat tones")
        XCTAssertTrue(isTold { _ = StyleStamp() }, "a style made in a body")
    }

    func testEveryApplyIsANewRevisionSoAStyleMadeBeforeItIsADifferentValue() {
        let before = StyleStamp()
        StyleRuntime.shared.apply(StyleKitFixtures.newsprint)
        let during = StyleStamp()
        XCTAssertNotEqual(before, during)
        StyleRuntime.shared.apply(nil)
        XCTAssertNotEqual(during, StyleStamp())
        XCTAssertEqual(StyleStamp(), StyleStamp(), "two made under the same look are the same value")
    }

    // MARK: The fixtures

    func testEveryFixtureIsAKitTheAppMayWear() {
        XCTAssertEqual(StyleKitFixtures.all.count, 8)
        for kit in StyleKitFixtures.all {
            XCTAssertEqual(kit.violations.map(\.label), [], "\(kit.id) holds the floors")
            XCTAssertEqual(DashboardThemeState(theme: kit.id, kit: kit).kit, kit, "\(kit.id) is a kit a state keeps")
        }
        XCTAssertEqual(Set(StyleKitFixtures.all.map(\.id)).count, 8)
    }
}
