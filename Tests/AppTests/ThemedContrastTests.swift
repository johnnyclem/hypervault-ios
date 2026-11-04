import HyperVaultKit
import SwiftUI
import UIKit
import XCTest
@testable import HyperVault

/// The pairs the app draws text in, held for every theme the app can wear, through the real path from a kit to a pixel:
/// `Palette` -> `Color` -> `UIColor` resolved under a contrast setting. The Kit holds the same pairs on the kit's numbers
/// (`StyleKitContract`); this catches a mistake in the mapping of one to the other (a role wired to the wrong colour, a colour
/// that lost a channel) which the Kit's tests cannot see. The stock look's own numbers stay in `DesignContrastTests`.
final class ThemedContrastTests: StyleRuntimeTestCase {
    private func hex(_ color: Color, contrast: UIAccessibilityContrast) -> RGB {
        RGB(hex: resolveColor(color, contrast: contrast).hex)
    }

    private func surfaces(_ contrast: UIAccessibilityContrast) -> [(String, RGB)] {
        [("the page", hex(Palette.background, contrast: contrast)), ("paper", hex(Palette.surface, contrast: contrast)), ("raised paper", hex(Palette.surfaceRaised, contrast: contrast))]
    }

    private func assertRatio(_ ink: RGB, on surface: RGB, atLeast floor: Double, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let ratio = ink.contrast(with: surface)
        // The colours went through 8-bit channels twice; a thousandth of slack is for that, not for a bar missed.
        XCTAssertGreaterThanOrEqual(ratio + 0.001, floor, "\(what) is \(String(format: "%.2f", ratio)):1, needs \(floor):1.", file: file, line: line)
    }

    func testBodyTextAndTheAccentsReadOnTheSurfacesTheyAreDrawnOn() {
        for kit in StyleKitFixtures.all {
            StyleRuntime.shared.apply(kit)
            let on = surfaces(.normal)
            let all = [0, 1, 2], pageAndPaper = [0, 1]
            let inks: [(String, Color, [Int], Double)] = [
                ("textPrimary", Palette.textPrimary, all, 4.5), ("textSecondary", Palette.textSecondary, all, 4.5),
                ("blue", Palette.blue, pageAndPaper, 4.5), ("danger", Palette.danger, pageAndPaper, 4.5),
                ("sky", Palette.sky, all, 4.5), ("success", Palette.success, all, 4.5), ("warning", Palette.warning, all, 4.5),
                // The tones the web has no token for: 4.5 on the page and paper, 4.0 on raised paper (StyleKitHues).
                ("violet", Palette.violet, pageAndPaper, 4.5), ("coral", ChatAgentTone.coral.color, pageAndPaper, 4.5),
                ("cyan", ChatAgentTone.cyan.color, pageAndPaper, 4.5), ("rose", ChatAgentTone.rose.color, pageAndPaper, 4.5),
                ("violet raised", Palette.violet, [2], 4.0), ("coral raised", ChatAgentTone.coral.color, [2], 4.0),
                ("cyan raised", ChatAgentTone.cyan.color, [2], 4.0), ("rose raised", ChatAgentTone.rose.color, [2], 4.0),
            ]
            for (name, color, indexes, floor) in inks {
                for index in indexes {
                    assertRatio(hex(color, contrast: .normal), on: on[index].1, atLeast: floor, "\(kit.id): \(name) on \(on[index].0)")
                }
            }
        }
    }

    func testTheLabelsOnTheFillsReadOnThem() {
        for kit in StyleKitFixtures.all {
            StyleRuntime.shared.apply(kit)
            for contrast in [UIAccessibilityContrast.normal, .high] {
                assertRatio(hex(Palette.onAction, contrast: contrast), on: hex(Palette.action, contrast: contrast), atLeast: 4.5, "\(kit.id): the label on the action fill (\(contrast.rawValue))")
                assertRatio(hex(Palette.onDestructive, contrast: contrast), on: hex(Palette.danger, contrast: contrast), atLeast: 4.5, "\(kit.id): the label on the destructive fill")
                assertRatio(hex(HVColor.primaryForeground, contrast: contrast), on: hex(HVColor.primary, contrast: contrast), atLeast: 4.5, "\(kit.id): the mark's letter on primary")
                assertRatio(hex(HVColor.accentForeground, contrast: contrast), on: hex(HVColor.accent, contrast: contrast), atLeast: 4.5, "\(kit.id): the label on the accent fill")
            }
        }
    }

    func testIncreaseContrastTakesTheInkToSevenToOne() {
        for kit in StyleKitFixtures.all {
            StyleRuntime.shared.apply(kit)
            let on = surfaces(.high)
            let inks: [(String, Color, [Int])] = [
                ("textPrimary", Palette.textPrimary, [0, 1, 2]), ("textSecondary", Palette.textSecondary, [0, 1, 2]),
                ("blue", Palette.blue, [0, 1]), ("danger", Palette.danger, [0, 1]), ("sky", Palette.sky, [0, 1, 2]),
                ("success", Palette.success, [0, 1, 2]), ("warning", Palette.warning, [0, 1, 2]),
            ]
            for (name, color, indexes) in inks {
                for index in indexes {
                    assertRatio(hex(color, contrast: .high), on: on[index].1, atLeast: 7, "\(kit.id): \(name) on \(on[index].0) under Increase Contrast")
                }
            }
        }
    }

    func testTheSurfacesDoNotMoveUnderIncreaseContrast() {
        for kit in StyleKitFixtures.all {
            StyleRuntime.shared.apply(kit)
            for color in [Palette.background, Palette.surface, Palette.surfaceRaised, Palette.action] {
                XCTAssertEqual(resolveColor(color, contrast: .normal).hex, resolveColor(color, contrast: .high).hex, kit.id)
            }
        }
    }

    /// The edges are the kit's `border` at the strengths the screens use, and under Increase Contrast they are 3:1 as drawn.
    func testTheEdgesAreVisibleUnderIncreaseContrast() {
        for kit in StyleKitFixtures.all {
            StyleRuntime.shared.apply(kit)
            for surface in [Palette.background, Palette.surface] {
                let under = hex(surface, contrast: .high)
                let edge = resolveColor(Palette.border, contrast: .high)
                XCTAssertEqual(edge.alpha, 0.6, accuracy: 0.01)
                let drawn = RGB(hex: edge.hex).composited(over: under, alpha: Double(edge.alpha))
                assertRatio(drawn, on: under, atLeast: 3, "\(kit.id): the border as drawn under Increase Contrast")
            }
        }
    }
}
