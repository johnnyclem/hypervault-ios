import XCTest
@testable import HyperVaultKit

/// The JSON the server's StyleKit builder emits (Fixtures/stylekit), read as it is.
enum StyleKitFixtures {
    struct Missing: Error, CustomStringConvertible {
        let name: String
        var description: String { "Fixtures/stylekit/\(name).json is not in the test bundle" }
    }

    /// A fixture that is not there fails the test: a skipped StyleKit suite would read as green.
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/stylekit") else {
            throw Missing(name: name)
        }
        return try Data(contentsOf: url)
    }

    static func json(_ name: String) throws -> JSONValue {
        try HVCoding.decoder(.verbatim).decode(JSONValue.self, from: data(name))
    }

    static func kit(_ name: String) throws -> StyleKit {
        try decode(StyleKit.self, from: data(name))
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try HVCoding.decoder(.verbatim).decode(type, from: data)
    }

    static func encode(_ value: JSONValue) throws -> Data {
        try HVCoding.encoder(.verbatim).encode(value)
    }

    /// The four goldens.
    static let goldens = ["newsprint", "glassmorphism", "hypervault-light", "modern-dark"]

    /// `json` with the value at `path` replaced (or removed, for nil).
    static func setting(_ json: JSONValue, _ path: [String], to value: JSONValue?) -> JSONValue {
        guard case .object(var object) = json, let head = path.first else { return json }
        if path.count == 1 {
            object[head] = value
        } else {
            object[head] = setting(object[head] ?? .object([:]), Array(path.dropFirst()), to: value)
        }
        return .object(object)
    }

    /// A golden with one change, as the bytes the server would have sent.
    static func variant(_ name: String, _ path: [String], to value: JSONValue?) throws -> Data {
        try encode(setting(json(name), path, to: value))
    }

    /// Newsprint with one change.
    static func variant(_ path: [String], to value: JSONValue?) throws -> Data {
        try variant("newsprint", path, to: value)
    }
}

final class StyleKitTests: XCTestCase {
    // MARK: Colours

    func testAColourIsExactlyHashAndSixHexDigits() {
        XCTAssertEqual(RGB(parsing: "#0b0f14")?.hex, 0x0B0F14)
        XCTAssertEqual(RGB(parsing: "#0B0F14")?.hex, 0x0B0F14)
        XCTAssertEqual(RGB(parsing: "#FfFfFf")?.hex, 0xFFFFFF)
        XCTAssertEqual(RGB(parsing: "#000000")?.hex, 0)
        XCTAssertEqual(RGB(parsing: "#00d492")?.red, 0x00)
        XCTAssertEqual(RGB(parsing: "#00d492")?.green, 0xD4)
        XCTAssertEqual(RGB(parsing: "#00d492")?.blue, 0x92)
    }

    func testAnAlphaChannelIsRefusedWhateverItsValue() {
        XCTAssertNil(RGB(parsing: "#0b0f1480"), "translucent")
        XCTAssertNil(RGB(parsing: "#0b0f14ff"), "even a fully opaque alpha: the wire is #rrggbb")
        XCTAssertNil(RGB(parsing: "#0b0f1400"))
        XCTAssertNil(RGB(parsing: "#fff8"), "#rgba")
    }

    func testEverythingElseIsRefusedToo() {
        let refused = [
            "", "#", "#fff", "#12345", "#1234567", "0b0f14", "0x0b0f14", " #0b0f14", "#0b0f14 ", "#0b0f14\n", "#gggggg", "#0b0f1g",
            "#+12345", "#-12345", "#0x0f14", "rgb(1 2 3)", "rgb(1, 2, 3)", "rgba(1,2,3,0.5)", "hsl(0 0% 0%)", "red", "transparent",
            "#0b0f1\u{E9}", "\u{FF03}0b0f14", "#0b0f14\u{0}", "##0b0f14",
        ]
        for text in refused {
            XCTAssertNil(RGB(parsing: text), text.debugDescription)
        }
    }

    func testAColourIsWrittenInTheWiresSpelling() throws {
        XCTAssertEqual(RGB(hex: 0x00D492).hexString, "#00d492")
        XCTAssertEqual(RGB(hex: 0x000001).hexString, "#000001")
        XCTAssertEqual(RGB.white.hexString, "#ffffff")
        let upper = try HVCoding.decoder(.verbatim).decode([RGB].self, from: Data(##"["#0B0F14"]"##.utf8))
        XCTAssertEqual(upper.first?.hexString, "#0b0f14")
        XCTAssertThrowsError(try HVCoding.decoder(.verbatim).decode([RGB].self, from: Data(##"["#0b0f14ff"]"##.utf8)))
        let written = try HVCoding.encoder(.verbatim).encode([RGB(hex: 0x3B82F6)])
        XCTAssertEqual(String(decoding: written, as: UTF8.self), ##"["#3b82f6"]"##)
    }

    func testTheContrastMathIsTheWebsAndTheAppsTests() {
        XCTAssertEqual(RGB.white.contrast(with: .black), 21, accuracy: 0.001)
        XCTAssertEqual(RGB.white.luminance, 1, accuracy: 1e-9)
        XCTAssertEqual(RGB.black.luminance, 0, accuracy: 1e-9)
        // The figures DesignContrastTests records for the stock look.
        XCTAssertEqual(RGB.white.contrast(with: RGB(hex: 0x3B82F6)), 3.68, accuracy: 0.01)
        XCTAssertEqual(RGB.white.contrast(with: RGB(hex: 0x2563EB)), 5.17, accuracy: 0.01)
        XCTAssertEqual(RGB.white.contrast(with: RGB(hex: 0xEF4444)), 3.76, accuracy: 0.01)
        XCTAssertEqual(RGB(hex: 0x3B82F6).contrast(with: RGB(hex: 0x1A222D)), 4.36, accuracy: 0.01)
        XCTAssertEqual(RGB(hex: 0x3B82F6).contrast(with: RGB(hex: 0x1A222D)), RGB(hex: 0x1A222D).contrast(with: RGB(hex: 0x3B82F6)), accuracy: 1e-12, "either way round")
    }

    func testALabelOnAFillIsWhiteOrBlackWhicheverReadsBetter() {
        XCTAssertEqual(RGB(hex: 0x0B0F14).legibleLabel, .white)
        XCTAssertEqual(RGB(hex: 0xFFFDF4).legibleLabel, .black)
        XCTAssertEqual(RGB(hex: 0x3B82F6).legibleLabel, .black, "the stock blue reads better under black, 5.7 against 3.7")
        XCTAssertEqual(RGB(hex: 0x2563EB).legibleLabel, .white)
    }

    // MARK: Reading the goldens

    func testEveryGoldenDecodesAndHoldsTheFloors() throws {
        for name in StyleKitFixtures.goldens {
            let kit = try StyleKitFixtures.kit(name)
            XCTAssertEqual(kit.id, name)
            XCTAssertEqual(kit.violations.map(\.label), [], name)
            XCTAssertNil(kit.rejection, name)
            // Held without the floating point slack: the checks do not lean on it.
            XCTAssertTrue(StyleKitContract.pairs(for: kit).allSatisfy { $0.ratio >= $0.floor }, name)
        }
    }

    func testNewsprintIsRead() throws {
        let kit = try StyleKitFixtures.kit("newsprint")
        XCTAssertEqual(kit.name, "Newsprint")
        XCTAssertEqual(kit.appearance, .light)
        XCTAssertEqual(kit.font, .serif)
        XCTAssertEqual(kit.backdrop, .lines)
        XCTAssertEqual(kit.radius, 12)
        XCTAssertEqual(kit.adjusted, [.destructive])
        XCTAssertFalse(kit.hasNoticeableAdjustments, "a nudged error red is not worth a line under the picker")
        XCTAssertEqual(kit.colors.background.hexString, "#f6f3ea")
        XCTAssertEqual(kit.colors.mutedForeground.hexString, "#5c574a", "muted_foreground is mutedForeground")
        XCTAssertEqual(kit.colors.actionForeground.hexString, "#fffdf4", "action_foreground is actionForeground")
        XCTAssertEqual(kit.colors.action.hexString, "#17150f")
        XCTAssertEqual(kit.colors.destructive.hexString, "#dd1313")
        XCTAssertEqual(kit.colors[.ring], kit.colors.ring)
    }

    func testGlassmorphismArrivesFlattenedAndMovesItsInk() throws {
        let kit = try StyleKitFixtures.kit("glassmorphism")
        XCTAssertEqual(kit.appearance, .dark)
        XCTAssertEqual(kit.colors.card.hexString, "#1a1f2d", "the server flattened the 6% white over the page: the app never sees an alpha")
        XCTAssertEqual(kit.adjusted, [.primary, .destructive, .actionForeground])
        XCTAssertTrue(kit.hasNoticeableAdjustments, "the brand colour moved")
        XCTAssertEqual(kit.colors.primary.hexString, "#7678f3", "primary is ink, moved until it reads")
        XCTAssertEqual(kit.colors.action.hexString, "#6366f1", "action is the fill the theme designed, not moved")
        XCTAssertEqual(kit.colors.actionForeground, .black)
    }

    func testHyperVaultLightMovesNothing() throws {
        let kit = try StyleKitFixtures.kit("hypervault-light")
        XCTAssertEqual(kit.adjusted, [])
        XCTAssertEqual(kit.appearance, .light)
        XCTAssertEqual(kit.colors.primary.hexString, "#845300")
        XCTAssertEqual(kit.colors.action, kit.colors.primary)
    }

    func testModernDarkIsTheStockPaletteWithABlackLabelOnItsBlue() throws {
        let kit = try StyleKitFixtures.kit("modern-dark")
        XCTAssertEqual(kit.colors.background.hex, 0x0B0F14)
        XCTAssertEqual(kit.colors.foreground.hex, 0xE8EEF5)
        XCTAssertEqual(kit.colors.primary.hex, 0x3B82F6)
        XCTAssertEqual(kit.adjusted, [.actionForeground])
        XCTAssertGreaterThanOrEqual(kit.colors.actionForeground.contrast(with: kit.colors.action), 4.5)
        XCTAssertEqual(kit.font, .system)
        XCTAssertEqual(kit.backdrop, .glow)
    }

    func testAKitWritesBackTheServersOwnJSON() throws {
        for name in StyleKitFixtures.goldens {
            let kit = try StyleKitFixtures.kit(name)
            let written = try HVCoding.encoder(.verbatim).encode(kit)
            let again = try HVCoding.decoder(.verbatim).decode(JSONValue.self, from: written)
            XCTAssertEqual(again, try StyleKitFixtures.json(name), name)
            XCTAssertEqual(try StyleKitFixtures.decode(StyleKit.self, from: written), kit, name)
        }
    }

    // MARK: Tolerance

    func testWhatItDoesNotKnowIsIgnored() throws {
        var json = try StyleKitFixtures.json("newsprint")
        json = StyleKitFixtures.setting(json, ["future_top_level"], to: ["anything": [1, 2, 3]])
        json = StyleKitFixtures.setting(json, ["colors", "card_foreground"], to: "#000000")
        json = StyleKitFixtures.setting(json, ["colors", "shadow_float"], to: "0 1px 2px rgb(0 0 0 / 0.24)")
        json = StyleKitFixtures.setting(json, ["radius", "xl"], to: 16)
        json = StyleKitFixtures.setting(json, ["font", "family"], to: "Georgia")
        json = StyleKitFixtures.setting(json, ["backdrop", "stops"], to: ["#000000"])
        let kit = try StyleKitFixtures.decode(StyleKit.self, from: StyleKitFixtures.encode(json))
        XCTAssertEqual(kit, try StyleKitFixtures.kit("newsprint"))
    }

    func testAnUnknownFontDesignIsTheSystemOneAndAnUnknownBackdropIsPlain() throws {
        let rounded = try StyleKitFixtures.decode(StyleKit.self, from: StyleKitFixtures.variant(["font", "design"], to: "rounded"))
        XCTAssertEqual(rounded.font, .system)
        let waves = try StyleKitFixtures.decode(StyleKit.self, from: StyleKitFixtures.variant(["backdrop", "kind"], to: "waves"))
        XCTAssertEqual(waves.backdrop, .plain)
        let wrongType = try StyleKitFixtures.decode(StyleKit.self, from: StyleKitFixtures.variant(["font", "design"], to: 7))
        XCTAssertEqual(wrongType.font, .system)
        let notAnObject = try StyleKitFixtures.decode(StyleKit.self, from: StyleKitFixtures.variant(["backdrop"], to: "lines"))
        XCTAssertEqual(notAnObject.backdrop, .plain)
    }

    func testAnUnknownAdjustedRoleIsDroppedAndTheRestKeptInOrder() throws {
        let kit = try StyleKitFixtures.decode(StyleKit.self, from: StyleKitFixtures.variant(["adjusted"], to: ["destructive", "hologram", "action_foreground"]))
        XCTAssertEqual(kit.adjusted, [.destructive, .actionForeground])
        let junk = try StyleKitFixtures.decode(StyleKit.self, from: StyleKitFixtures.variant(["adjusted"], to: "destructive"))
        XCTAssertEqual(junk.adjusted, [])
    }

    func testTheDecorativeKeysAreOptional() throws {
        var json = try StyleKitFixtures.json("newsprint")
        for key in ["name", "radius", "font", "backdrop", "adjusted"] { json = StyleKitFixtures.setting(json, [key], to: nil) }
        let kit = try StyleKitFixtures.decode(StyleKit.self, from: StyleKitFixtures.encode(json))
        XCTAssertEqual(kit.name, "newsprint", "the id stands in for a missing name")
        XCTAssertEqual(kit.radius, StyleKit.defaultRadius)
        XCTAssertEqual(kit.font, .system)
        XCTAssertEqual(kit.backdrop, .plain)
        XCTAssertEqual(kit.adjusted, [])
        XCTAssertNil(kit.rejection)
    }

    func testTheLargerRadiiFollowTheBaseAsTheWebsDo() throws {
        let stock = try StyleKitFixtures.kit("newsprint")
        XCTAssertEqual([stock.radius, stock.radiusXL, stock.radius2XL, stock.radius3XL], [12, 16, 20, 28], "HVTokens.RadiusPx")
        let round = try StyleKitFixtures.decode(StyleKit.self, from: StyleKitFixtures.variant(["radius", "base"], to: 24))
        XCTAssertEqual([round.radius, round.radiusXL, round.radius2XL, round.radius3XL], [24, 28, 32, 40])
    }

    func testTheRadiusIsKeptInRange() throws {
        func radius(_ value: JSONValue) throws -> Double {
            try StyleKitFixtures.decode(StyleKit.self, from: StyleKitFixtures.variant(["radius", "base"], to: value)).radius
        }
        XCTAssertEqual(try radius(24), 24)
        XCTAssertEqual(try radius(10.5), 10.5)
        XCTAssertEqual(try radius(0), 0)
        XCTAssertEqual(try radius(-6), 0)
        XCTAssertEqual(try radius(1_000_000), StyleKit.maxRadius)
        XCTAssertEqual(try radius("12"), StyleKit.defaultRadius, "not a number: the stock radius")
        XCTAssertEqual(try radius(.null), StyleKit.defaultRadius)
    }

    // MARK: Refusal

    private func rejection(_ data: Data, file: StaticString = #filePath, line: UInt = #line) -> StyleKitRejection? {
        do {
            _ = try StyleKitFixtures.decode(StyleKit.self, from: data)
            XCTFail("the kit should have been refused", file: file, line: line)
            return nil
        } catch {
            XCTAssertTrue(error is StyleKitRejection, "\(error)", file: file, line: line)
            return error as? StyleKitRejection
        }
    }

    func testAnotherSchemaMajorIsRefusedAndNeverHalfRead() throws {
        XCTAssertEqual(rejection(try StyleKitFixtures.variant(["schema_version"], to: 2)), .unsupportedSchema(2))
        XCTAssertEqual(rejection(try StyleKitFixtures.variant(["schema_version"], to: 99)), .unsupportedSchema(99))
        XCTAssertEqual(rejection(try StyleKitFixtures.variant(["schema_version"], to: 0)), .unsupportedSchema(0))
        XCTAssertEqual(rejection(try StyleKitFixtures.variant(["schema_version"], to: nil)), .unsupportedSchema(nil))
        guard case .malformed = rejection(try StyleKitFixtures.variant(["schema_version"], to: "1")) else { return XCTFail("a string is not a version") }
    }

    func testAnUnknownAppearanceIsRefused() throws {
        guard case .malformed(let why) = rejection(try StyleKitFixtures.variant(["appearance"], to: "sepia")) else { return XCTFail("expected malformed") }
        XCTAssertTrue(why.contains("sepia"), why)
        guard case .malformed = rejection(try StyleKitFixtures.variant(["appearance"], to: nil)) else { return XCTFail("expected malformed") }
        guard case .malformed = rejection(try StyleKitFixtures.variant(["appearance"], to: 1)) else { return XCTFail("expected malformed") }
    }

    func testAKitWithoutAnIdIsRefused() throws {
        guard case .malformed = rejection(try StyleKitFixtures.variant(["id"], to: nil)) else { return XCTFail("expected malformed") }
        guard case .malformed = rejection(try StyleKitFixtures.variant(["id"], to: "")) else { return XCTFail("expected malformed") }
    }

    func testAKitMissingAnyOneOfTheFourteenColoursIsRefused() throws {
        XCTAssertEqual(StyleColorRole.allCases.count, 14)
        for role in StyleColorRole.allCases {
            guard case .malformed(let why) = rejection(try StyleKitFixtures.variant(["colors", role.rawValue], to: nil)) else {
                return XCTFail("\(role) is required")
            }
            XCTAssertTrue(why.contains(role.rawValue), why)
        }
        guard case .malformed = rejection(try StyleKitFixtures.variant(["colors"], to: nil)) else { return XCTFail("no colours at all") }
    }

    func testAColourThatIsNotOpaqueHexRefusesTheWholeKit() throws {
        let bad: [JSONValue] = [
            "rgba(255, 255, 255, 0.06)", "#ffffff0f", "#ffffffff", "#fff", "white", "", "ffffff", 16_777_215, .null, true, ["r": 1],
        ]
        for value in bad {
            for role in [StyleColorRole.card, .primary, .actionForeground] {
                guard case .malformed = rejection(try StyleKitFixtures.variant(["colors", role.rawValue], to: value)) else {
                    return XCTFail("\(role) = \(value) should refuse the kit")
                }
            }
        }
    }

    func testAKitThatIsNotAnObjectIsRefused() throws {
        for text in ["null", "5", #""newsprint""#, "[]"] {
            XCTAssertThrowsError(try StyleKitFixtures.decode(StyleKit.self, from: Data(text.utf8)), text)
        }
        // `{}` has no schema_version.
        XCTAssertEqual(rejection(Data("{}".utf8)), .unsupportedSchema(nil))
    }

    // MARK: The floors

    func testTheTableOfPairsIsPinned() throws {
        let pairs = StyleKitContract.pairs(for: try StyleKitFixtures.kit("newsprint"))
        XCTAssertEqual(pairs.map(\.label), [
            "foreground on background", "foreground on card", "foreground on muted",
            "muted_foreground on background", "muted_foreground on card", "muted_foreground on muted",
            "primary on background", "primary on card",
            "accent on background", "accent on card", "accent on muted",
            "destructive on background", "destructive on card",
            "success on background", "success on card", "success on muted",
            "warning on background", "warning on card", "warning on muted",
            "action_foreground on action",
            "system label on background", "system label on card", "system label on muted",
        ])
        XCTAssertEqual(pairs.map(\.floor), Array(repeating: 4.5, count: 20) + [4.5, 3.0, 3.0])
    }

    func testTextThatDoesNotReadOnItsSurfaceMakesTheKitIllegible() throws {
        var kit = try StyleKitFixtures.kit("modern-dark")
        kit.colors.foreground = kit.colors.background
        XCTAssertTrue(kit.violations.map(\.label).contains("foreground on background"))
        guard case .illegible(let why)? = kit.rejection else { return XCTFail("expected illegible") }
        XCTAssertTrue(why.hasPrefix("foreground on background is 1.00:1"), why)

        for role in [StyleColorRole.mutedForeground, .primary, .accent, .destructive, .success, .warning] {
            var other = try StyleKitFixtures.kit("modern-dark")
            other.colors[role] = other.colors.card
            XCTAssertFalse(other.violations.isEmpty, "\(role) the colour of its own paper")
            XCTAssertNotNil(other.rejection)
        }
    }

    func testALabelThatDoesNotReadOnItsFillMakesTheKitIllegible() throws {
        var kit = try StyleKitFixtures.kit("newsprint")
        kit.colors.actionForeground = kit.colors.action
        XCTAssertEqual(kit.violations.map(\.label), ["action_foreground on action"])
    }

    func testAnAppearanceThatDoesNotFitThePageMakesTheKitIllegibleBecauseSystemTextTakesIt() throws {
        var dark = try StyleKitFixtures.kit("modern-dark")
        dark.appearance = .light
        XCTAssertTrue(dark.violations.map(\.label).contains("system label on background"), "black system text on a near-black page")
        var light = try StyleKitFixtures.kit("newsprint")
        light.appearance = .dark
        XCTAssertTrue(light.violations.map(\.label).contains("system label on background"), "white system text on cream")
    }

    func testFloatingPointSlackIsOnlyForFloatingPoint() {
        let grey = RGB(hex: 0x777777)
        let ratio = RGB.white.contrast(with: grey)
        XCTAssertTrue(StyleKitContract.Pair(label: "x", foreground: .white, background: grey, floor: ratio + 5e-7).holds)
        XCTAssertFalse(StyleKitContract.Pair(label: "x", foreground: .white, background: grey, floor: ratio + 1e-4).holds)
    }

    // MARK: Every preset

    /// One row of `all-presets.json`: what `GET /api/dashboard-theme` answers for a style id.
    private struct PresetAnswer: Decodable {
        let theme: String
        let kit: StyleKit?
        let reason: String?
    }

    private func presets() throws -> [PresetAnswer] {
        try StyleKitFixtures.decode([PresetAnswer].self, from: StyleKitFixtures.data("all-presets"))
    }

    /// `all-presets.json` is the server's own `themePayload` over its 39 themes (Fixtures/stylekit/README.md).
    func testTheAppsFloorsAgreeWithTheServersClampForEveryPreset() throws {
        let all = try presets()
        XCTAssertEqual(all.count, 39)
        XCTAssertEqual(Set(all.map(\.theme)).count, 39)

        let withheld = all.filter { $0.kit == nil }
        XCTAssertEqual(withheld.map(\.theme), ["retro"], "retro is the one preset with no accessible kit")
        XCTAssertEqual(withheld.map(\.reason), ["unsupported"])

        // Every kit the server serves is one the app may wear.
        let kits = all.compactMap(\.kit)
        XCTAssertEqual(kits.count, 38)
        var tightest = Double.infinity
        for (answer, kit) in zip(all.filter { $0.kit != nil }, kits) {
            XCTAssertEqual(kit.id, answer.theme)
            XCTAssertNil(answer.reason)
            for pair in StyleKitContract.pairs(for: kit) {
                XCTAssertTrue(pair.holds, "\(kit.id): \(pair.label) is \(pair.ratio)")
                tightest = min(tightest, pair.ratio / pair.floor)
            }
        }
        XCTAssertGreaterThanOrEqual(tightest, 1, "no pair passes only on the floating point slack")
    }

    /// The four goldens are the server's files and the sweep is the server's builder run over every theme, so each golden
    /// is the `kit` of its own row. Editing one by hand and not the other fails here.
    func testTheGoldensAreTheKitsOfTheSweep() throws {
        let rows = try XCTUnwrap(StyleKitFixtures.json("all-presets").array)
        XCTAssertEqual(rows.count, 39)
        for name in StyleKitFixtures.goldens {
            let row = try XCTUnwrap(rows.first(where: { $0["theme"] == JSONValue.string(name) }), name)
            XCTAssertEqual(row["kit"], try StyleKitFixtures.json(name), name)
        }
    }

    func testEveryPresetsAppearanceIsTheSideOfItsPage() throws {
        for kit in try presets().compactMap(\.kit) {
            // Where a white label and a black label contrast equally with the page.
            let light = kit.colors.background.luminance > 0.1791
            XCTAssertEqual(kit.appearance, light ? .light : .dark, kit.id)
        }
    }
    // MARK: The hues the web has no token for

    private func allKits() throws -> [StyleKit] {
        try presets().compactMap(\.kit)
    }

    func testTheAppsOwnHuesAreOneForEachLook() {
        let dark = StyleKitHues.stock(.dark), light = StyleKitHues.stock(.light)
        XCTAssertEqual([dark.memory, dark.coral, dark.cyan, dark.rose].map(\.hexString), ["#a78bfa", "#f97316", "#22d3ee", "#fb7185"])
        XCTAssertEqual([light.memory, light.coral, light.cyan, light.rose].map(\.hexString), ["#6d28d9", "#c2410c", "#0e7490", "#be123c"])
        XCTAssertEqual(StyleKitHues.tintFill, 0.10)
    }

    func testHuesThatAlreadyReadOnAKitsSurfacesComeBackByteForByte() throws {
        for name in ["modern-dark", "hypervault-light", "glassmorphism", "newsprint"] {
            let kit = try StyleKitFixtures.kit(name)
            XCTAssertEqual(kit.hues, StyleKitHues.stock(kit.appearance), name)
        }
    }

    func testAHueIsMovedAlongItsOwnHueOnlyWhereTheSurfacesNeedIt() throws {
        let moved = try allKits().filter { $0.hues != StyleKitHues.stock($0.appearance) }
        XCTAssertEqual(moved.map(\.id).sorted(), ["industrial", "neumorphism", "organic"], "the three presets whose surfaces the stock tones fall short on")
        for kit in moved {
            let stock = StyleKitHues.stock(kit.appearance), now = kit.hues
            for (was, is_) in [(stock.coral, now.coral), (stock.cyan, now.cyan), (stock.rose, now.rose), (stock.memory, now.memory)] where was != is_ {
                XCTAssertEqual(is_.hsl.hue, was.hsl.hue, accuracy: 4, "\(kit.id): the hue stays")
                XCTAssertEqual(is_.hsl.saturation, was.hsl.saturation, accuracy: 0.02, "\(kit.id): the saturation stays")
                // Industrial and neumorphism are light kits: darker; they would not have needed to move lighter.
                XCTAssertEqual(kit.appearance, .light)
                XCTAssertLessThan(is_.hsl.lightness, was.hsl.lightness, kit.id)
            }
        }
    }

    func testEveryPresetsHuesHoldTheirFloors() throws {
        for kit in try allKits() {
            let hues = kit.hues
            for (name, colour) in [("memory", hues.memory), ("coral", hues.coral), ("cyan", hues.cyan), ("rose", hues.rose)] {
                XCTAssertGreaterThanOrEqual(StyleKitHues.margin(colour, on: kit.colors), 1, "\(kit.id) \(name)")
                for surface in [kit.colors.background, kit.colors.card] {
                    XCTAssertGreaterThanOrEqual(colour.contrast(with: surface), 4.5, "\(kit.id) \(name) as text")
                }
                XCTAssertGreaterThanOrEqual(colour.contrast(with: kit.colors.muted), 4.0, "\(kit.id) \(name) on raised paper")
                for surface in kit.colors.surfaces {
                    XCTAssertGreaterThanOrEqual(colour.contrast(with: colour.composited(over: surface, alpha: StyleKitHues.tintFill)), 3.5, "\(kit.id) \(name) as a tag")
                }
            }
        }
    }

    func testHuesThatCannotBeRescuedFallBackToTheKitsOwnText() throws {
        var kit = try StyleKitFixtures.kit("modern-dark")
        // A white page, black paper and grey raised paper: no colour reads on all three.
        kit.colors.background = .white
        kit.colors.card = .black
        kit.colors.muted = RGB(hex: 0x808080)
        XCTAssertEqual(kit.hues, StyleKitHues(memory: kit.colors.foreground, coral: kit.colors.foreground, cyan: kit.colors.foreground, rose: kit.colors.foreground))
    }

    func testTheHslRoundTripIsClose() {
        for hex: UInt32 in [0xF97316, 0x22D3EE, 0x6D28D9, 0x808080, 0x000000, 0xFFFFFF, 0xBE123C] {
            let colour = RGB(hex: hex)
            let (h, s, l) = colour.hsl
            let back = RGB(hue: h, saturation: s, lightness: l)
            XCTAssertEqual(Int(back.red), Int(colour.red), accuracy: 1, String(hex, radix: 16))
            XCTAssertEqual(Int(back.green), Int(colour.green), accuracy: 1, String(hex, radix: 16))
            XCTAssertEqual(Int(back.blue), Int(colour.blue), accuracy: 1, String(hex, radix: 16))
        }
    }
}
