import XCTest
@testable import HyperVaultKit

/// Increase Contrast: the 7:1 set the app derives from the 4.5:1 kit the server sent (StyleKitIncreasedContrast).
final class StyleKitIncreasedContrastTests: XCTestCase {
    private struct PresetAnswer: Decodable {
        let theme: String
        let kit: StyleKit?
    }

    private func allKits() throws -> [StyleKit] {
        try StyleKitFixtures.decode([PresetAnswer].self, from: StyleKitFixtures.data("all-presets")).compactMap(\.kit)
    }

    private func wrapped(_ kit: StyleKit, _ colors: StyleKitColors) -> StyleKit {
        var copy = kit
        copy.colors = colors
        return copy
    }

    /// The pairs the shared contract holds, over a kit's colours.
    private func inkRatio(_ role: StyleColorRole, in colors: StyleKitColors) -> Double {
        StyleKitContract.ink.first { $0.role == role }.map { entry in
            entry.surfaces.map { colors[role].contrast(with: colors[$0]) }.min() ?? 0
        } ?? 0
    }

    func testTheSurfacesNeverMove() throws {
        for kit in try allKits() {
            let high = kit.highContrast
            XCTAssertEqual(high.surfaces, kit.colors.surfaces, kit.id)
            XCTAssertEqual(high.action, kit.colors.action, "\(kit.id): the fill is the theme's own")
        }
    }

    func testEveryServedKitReachesSevenToOneWhereAnythingCan() throws {
        var short: [String] = []
        for kit in try allKits() {
            let high = kit.highContrast
            for entry in StyleKitContract.ink {
                let ratio = inkRatio(entry.role, in: high)
                if ratio + StyleKitContract.tolerance < 7 { short.append("\(kit.id) \(entry.role.rawValue) \(String(format: "%.2f", ratio))") }
            }
        }
        // A colour a kit's own page and paper leave no room for is the best the search found, not a failure; the sweep
        // records which ones, so a change to the search that makes it worse fails here.
        XCTAssertEqual(short, [], "ink a served kit cannot take to 7:1")
    }

    func testNoColourEverGetsLessContrastAndTheStandardFloorsStillHold() throws {
        for kit in try allKits() {
            let high = kit.highContrast
            for entry in StyleKitContract.ink {
                XCTAssertGreaterThanOrEqual(inkRatio(entry.role, in: high) + StyleKitContract.tolerance, inkRatio(entry.role, in: kit.colors), "\(kit.id) \(entry.role.rawValue)")
            }
            XCTAssertGreaterThanOrEqual(
                high.actionForeground.contrast(with: high.action) + StyleKitContract.tolerance,
                kit.colors.actionForeground.contrast(with: kit.colors.action), "\(kit.id) action label"
            )
            XCTAssertEqual(wrapped(kit, high).violations.map(\.label), [], "\(kit.id): the high set is a kit the app may wear")
        }
    }

    func testInkThatAlreadyClearsSevenComesBackByteForByte() throws {
        // Newsprint's body text is near-black on cream: 15:1.
        let kit = try StyleKitFixtures.kit("newsprint")
        XCTAssertEqual(kit.highContrast.foreground, kit.colors.foreground)
        XCTAssertEqual(kit.highContrast.primary, kit.colors.primary, "primary is the same near-black")
    }

    func testInkMovesAlongItsOwnHueAwayFromItsSurfaces() throws {
        let kit = try StyleKitFixtures.kit("newsprint")
        let high = kit.highContrast
        // The red accent: darker on a light page, its hue and saturation kept.
        XCTAssertNotEqual(high.accent, kit.colors.accent)
        XCTAssertLessThan(high.accent.luminance, kit.colors.accent.luminance)
        XCTAssertEqual(high.accent.hsl.hue, kit.colors.accent.hsl.hue, accuracy: 4)
        XCTAssertEqual(high.accent.hsl.saturation, kit.colors.accent.hsl.saturation, accuracy: 0.03)

        // On a dark kit the ink that moves goes the other way: lighter.
        let dark = try StyleKitFixtures.kit("glassmorphism")
        let moved = StyleColorRole.allCases.filter { [.foreground, .mutedForeground, .primary, .accent, .destructive, .success, .warning].contains($0) && dark.highContrast[$0] != dark.colors[$0] }
        XCTAssertFalse(moved.isEmpty, "something in Glassmorphism's ink is under 7:1")
        for role in moved {
            XCTAssertGreaterThan(dark.highContrast[role].luminance, dark.colors[role].luminance, role.rawValue)
            XCTAssertEqual(dark.highContrast[role].hsl.hue, dark.colors[role].hsl.hue, accuracy: 4, role.rawValue)
        }
    }

    func testTheEdgesAreThreeToOneAsDrawn() throws {
        for kit in try allKits() {
            let high = kit.highContrast
            for surface in [kit.colors.background, kit.colors.card] {
                let border = high.border.composited(over: surface, alpha: StyleKitIncreasedContrast.borderStrength).contrast(with: surface)
                XCTAssertGreaterThanOrEqual(border + StyleKitContract.tolerance, StyleKitIncreasedContrast.edgeFloor, "\(kit.id) border")
                let ring = high.ring.composited(over: surface, alpha: StyleKitIncreasedContrast.ringStrength).contrast(with: surface)
                XCTAssertGreaterThanOrEqual(ring + StyleKitContract.tolerance, StyleKitIncreasedContrast.edgeFloor, "\(kit.id) ring")
            }
        }
    }

    func testTheLabelOnTheFillIsTheThemesOwnUnlessBlackOrWhiteReadsBetter() throws {
        // Glassmorphism's black label on its indigo fill is the theme's own, and it already reads better than white would.
        let glass = try StyleKitFixtures.kit("glassmorphism")
        XCTAssertEqual(glass.highContrast.actionForeground, glass.colors.actionForeground)

        var kit = try StyleKitFixtures.kit("newsprint")
        kit.colors.action = RGB(hex: 0x808080)
        kit.colors.actionForeground = RGB(hex: 0x999999)
        let label = kit.highContrast.actionForeground
        XCTAssertTrue(label == .black || label == .white, "a grey label on a grey fill becomes black or white")
        XCTAssertGreaterThan(label.contrast(with: kit.colors.action), RGB(hex: 0x999999).contrast(with: kit.colors.action))
    }

    func testTheHuesTheWebHasNoTokenForAreInkToo() throws {
        for kit in try allKits() {
            let high = kit.highContrastHues
            for (name, colour) in [("memory", high.memory), ("coral", high.coral), ("cyan", high.cyan), ("rose", high.rose)] {
                for surface in kit.colors.surfaces {
                    XCTAssertGreaterThanOrEqual(colour.contrast(with: surface) + StyleKitContract.tolerance, 7, "\(kit.id) \(name)")
                }
            }
        }
    }

    func testAKitWithNoRoomIsTheBestTheSearchFoundAndNeverAFailure() throws {
        var kit = try StyleKitFixtures.kit("modern-dark")
        // A white page, black paper and grey raised paper: no ink reads 7:1 on all three.
        kit.colors.background = .white
        kit.colors.card = .black
        kit.colors.muted = RGB(hex: 0x808080)
        let high = kit.highContrast
        let before = inkRatio(.foreground, in: kit.colors)
        XCTAssertGreaterThanOrEqual(inkRatio(.foreground, in: high) + StyleKitContract.tolerance, before)
        XCTAssertLessThan(inkRatio(.foreground, in: high), 7, "there is no colour that reads 7:1 on white, black and grey at once")
    }

    func testTheSearchIsDeterministicAndPure() throws {
        let kit = try StyleKitFixtures.kit("glassmorphism")
        XCTAssertEqual(kit.highContrast, kit.highContrast)
        XCTAssertEqual(kit.highContrastHues, kit.highContrastHues)
    }
}
