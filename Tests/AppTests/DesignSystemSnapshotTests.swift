import SwiftUI
import XCTest
@testable import HyperVault

private func swatch(_ name: String, _ color: Color) -> some View {
    VStack(spacing: 4) {
        RoundedRectangle(cornerRadius: HV.Radius.control, style: .continuous)
            .fill(color)
            .frame(height: 36)
            .overlay(RoundedRectangle(cornerRadius: HV.Radius.control, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
        Text(name).font(.system(size: 9)).foregroundStyle(Palette.textSecondary).lineLimit(1).minimumScaleFactor(0.7)
    }
}

/// The design system on one page each, so the stock look can be read off the published renders: the palette on its
/// surfaces, the buttons, fields and tags, the pieces the Vault is built from, and the marks and glass.
@MainActor
final class DesignSystemSnapshotTests: XCTestCase {
    private func page<Content: View>(paper: Bool = true, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: HV.Space.wide) { content() }
            .padding(HV.Space.m)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(paper ? Palette.background : Color.clear)
            .tint(HVColor.primary)
    }

    /// The palette page: the tokens as swatches, then text on the page, on paper and on raised paper.
    private func palettePage() -> some View {
        let tokens: [(String, Color)] = [
            ("background", HVColor.background), ("foreground", HVColor.foreground), ("card", HVColor.card),
            ("muted", HVColor.muted), ("muted-fg", HVColor.mutedForeground), ("primary", HVColor.primary),
            ("primary-fg", HVColor.primaryForeground), ("secondary", HVColor.secondary), ("accent", HVColor.accent),
            ("accent-fg", HVColor.accentForeground), ("border", HVColor.border), ("ring", HVColor.ring),
            ("destructive", HVColor.destructive), ("emerald-400", HVColor.emerald400), ("amber-400", HVColor.amber400),
        ]
        return page {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: HV.Space.xs), count: 5), spacing: HV.Space.xs) {
                ForEach(tokens, id: \.0) { swatch($0.0, $0.1) }
            }
            VStack(alignment: .leading, spacing: HV.Space.s) {
                Text("Section heading").font(.system(.subheadline, weight: .semibold)).foregroundStyle(HVColor.foreground)
                Text("Body text on the page, foreground").font(.hvBody).foregroundStyle(Palette.textPrimary)
                Text("Hint text, muted-foreground").font(.hvFootnote).foregroundStyle(Palette.textSecondary)
                Text("Accent text").font(.hvBody).foregroundStyle(HVColor.accent)
                Text("Primary text").font(.hvBody).foregroundStyle(HVColor.primary)
                Text("Destructive text").font(.hvBody).foregroundStyle(HVColor.destructive)
            }
            .hvCard()
            VStack(alignment: .leading, spacing: HV.Space.s) {
                Text("Raised paper, muted").font(.hvBody).foregroundStyle(Palette.textPrimary)
                Text("Hint on muted").font(.hvFootnote).foregroundStyle(Palette.textSecondary)
                Text("Accent on muted").font(.hvBody).foregroundStyle(HVColor.accent)
            }
            .padding(HV.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HVColor.muted, in: RoundedRectangle(cornerRadius: HV.Radius.card, style: .continuous))
        }
    }

    func testThePaletteOnItsSurfaces() throws {
        try snapshot(palettePage(), named: "design-palette", size: CGSize(width: 393, height: 700))
    }

    /// The controls page: the buttons, the fields, the tags and the chips.
    private func controlsPage() -> some View {
        page {
            VStack(spacing: HV.Space.xs) {
                Button("Save") {}.buttonStyle(.hvPrimary)
                Button("Save") {}.buttonStyle(.hvPrimary).disabled(true)
                Button("Generate a key") {}.buttonStyle(.hvSecondary)
                Button("Delete the account forever") {}.buttonStyle(.hvDestructive)
                Button("Cancel") {}.buttonStyle(.hvGhost)
                HStack {
                    Button {} label: { Image(systemName: HVSymbol.add) }.buttonStyle(.hvIcon)
                    Button {} label: { Image(systemName: HVSymbol.add) }.buttonStyle(.hvIconProminent)
                }
            }
            VStack(spacing: HV.Space.s) {
                HVLabeledField(title: "Name", footnote: "Letters, digits, dots and dashes.") {
                    TextField("", text: .constant("stripe-key"), prompt: .hvPrompt("name"))
                }
                HVLabeledField(title: "Name (optional)", footnote: "A name is needed.", isFocused: true) {
                    TextField("", text: .constant(""), prompt: .hvPrompt("name"))
                }
                HVLabeledField(title: "Value", footnote: "No such secret.", isInvalid: true) {
                    TextField("", text: .constant("sk_live_"), prompt: .hvPrompt("value"))
                }
            }
            HStack(spacing: HV.Space.xs) {
                HVTag(text: "Latest", tint: Palette.success)
                HVTag(text: "Out of date", tint: Palette.warning)
                HVTag(text: "Signed in", tint: Palette.blue)
                HVTag(text: "Failed", tint: Palette.danger)
            }
            HStack(spacing: HV.Space.xs) {
                HVTag(text: "agent", tint: Palette.violet)
                HVTag(text: "Found for you", tint: Palette.sky)
                HVTag(text: "Default")
                HVTag(text: "#tag")
            }
            HStack(spacing: HV.Space.xs) {
                HVChip(title: "All 6", isSelected: true, minTarget: 0)
                HVChip(title: "Files 2", minTarget: 0)
                HVIconBadge(symbol: "key", tint: Palette.amber)
                HVIconBadge(symbol: "doc", tint: Palette.blue)
            }
        }
    }

    func testButtonsFieldsAndTags() throws {
        try snapshot(controlsPage(), named: "design-controls", size: CGSize(width: 393, height: 940))
    }

    /// The small things that are drawn once and used everywhere: the one filter with and without a count, the quiet text a
    /// count or a plan is, the status tag (a capsule on one line, a small rounded rectangle where it wraps at a large text
    /// size), the saved-copy notice (one line, and wrapped, where it is no stadium), and the system Paste control in the
    /// app's shape.
    func testTheDetails() throws {
        try snapshot(
            page {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: HV.Space.hair) {
                        HVFilterPill(title: "All", isSelected: true) {}
                        HVFilterPill(title: "Open") {}
                        HVFilterPill(title: "Unread", count: 3) {}
                        HVFilterPill(title: "Done") {}
                    }
                }
                HStack(spacing: HV.Space.s) {
                    Text("Linear").font(.hvBody).foregroundStyle(Palette.textPrimary)
                    HVCount("2 of 3 on")
                    HVCount(12)
                    HVCount("Pro")
                }
                HVTag(text: "Signed in with a login", tint: Palette.success)
                HVTag(text: "Signed in with a login", tint: Palette.success).environment(\.dynamicTypeSize, .accessibility3)
                HVStaleBanner()
                HVStaleBanner().environment(\.dynamicTypeSize, .accessibility3)
                HVPasteButton { _ in }
            },
            named: "design-details", size: CGSize(width: 393, height: 600)
        )
    }

    func testThePiecesTheVaultIsBuiltFrom() throws {
        try snapshot(
            page {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: HV.Space.hair) {
                        HVFilterPill(title: "All", count: 9, isSelected: true) {}
                        HVFilterPill(title: "Logins", count: 4) {}
                        HVFilterPill(title: "Cards", count: 2) {}
                        HVFilterPill(title: "Contact info", count: 1) {}
                        HVFilterPill(title: "Keys", count: 2) {}
                    }
                }
                HStack(spacing: HV.Space.s) {
                    HVTile(symbol: HVSymbol.card)
                    HVTile(symbol: HVSymbol.contact)
                    HVTile(symbol: HVSymbol.address)
                    HVTile(symbol: HVSymbol.key)
                    HVTile(monogram: "G")
                }
                HStack(spacing: HV.Space.s) {
                    ForEach(HVCardBrand.allCases, id: \.self) { HVCardBrandTile(brand: $0).frame(width: 36, height: 36) }
                }
                HVCodePanel("curl -H \"Authorization: Bearer $HV_KEY\" https://hypervault.store/api/secrets/stripe-key")
                HVEmptyBox(message: "No cards yet. The list only ever shows a card's brand and last four digits.")
                VStack(spacing: 0) {
                    ForEach(["github.com", "Visa 4242", "Home address"], id: \.self) { name in
                        HStack(spacing: HV.Space.s) {
                            HVTile(monogram: String(name.prefix(1)).uppercased())
                            VStack(alignment: .leading, spacing: 0) {
                                Text(name).font(.hvBody).foregroundStyle(Palette.textPrimary)
                                Text("A hint").font(.hvFootnote).foregroundStyle(Palette.textSecondary)
                            }
                            Spacer()
                            Image(systemName: HVSymbol.open).foregroundStyle(Palette.textSecondary)
                        }
                        .padding(.horizontal, HV.Space.m)
                        .padding(.vertical, HV.Space.s)
                        if name != "Home address" { Divider().overlay(Palette.divider) }
                    }
                }
                .background(HVColor.card, in: RoundedRectangle(cornerRadius: HV.Radius.surface, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: HV.Radius.surface, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
            },
            named: "design-vault-pieces", size: CGSize(width: 393, height: 780)
        )
    }

    func testTheMarksAndTheGlass() throws {
        try snapshot(
            ZStack {
                AuroraBackground()
                page(paper: false) {
                    HStack(spacing: HV.Space.m) {
                        BrandMark(size: 32)
                        BrandMark(size: 64)
                        BrandMark(size: 104)
                    }
                    Text("Ask your AI to keep something")
                        .font(.hvBody)
                        .foregroundStyle(Palette.textPrimary)
                        .padding(HV.Space.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .hvGlass()
                    HVEmptyState(symbol: "tray", title: "Nothing kept yet.", message: "Ask your AI to keep something.", actionTitle: "Copy a starter prompt") {}
                }
            },
            named: "design-marks-and-glass", size: CGSize(width: 393, height: 640)
        )
    }

    // MARK: In a theme

    /// Wears `kit`, builds the screen under it (a page reads some of its colours as it is built), draws it pinned to the kit's
    /// appearance, and always puts the stock look back.
    private func render<V: View>(in kit: StyleKit, named name: String, size: CGSize, _ screen: () -> V) throws -> PixelBuffer {
        StyleRuntime.shared.apply(kit)
        defer { StyleRuntime.shared.apply(nil) }
        let images = try renderSnapshot(screen(), named: name, size: size, schemes: [kit.appearance.userInterfaceStyle])
        return try XCTUnwrap(images.first.flatMap(PixelBuffer.init), "\(name) was not drawn")
    }

    /// The palette page in a light theme (Newsprint) and in a dark one (Glassmorphism), so a published render shows both. The
    /// page itself is the kit's background, which is what a pixel at its edge says.
    func testThePaletteInTwoThemes() throws {
        for kit in [StyleKitFixtures.newsprint, StyleKitFixtures.glassmorphism] {
            let pixels = try render(in: kit, named: "design-palette-\(kit.id)", size: CGSize(width: 393, height: 700)) { palettePage() }
            let edge = try XCTUnwrap(pixels.color(x: 2, y: 690), "\(kit.id): no pixel at the edge")
            XCTAssertTrue(PixelBuffer.same(edge, kit.colors.background.hex), "\(kit.id): the page is the kit's background, not \(String(edge, radix: 16))")
        }
    }

    /// The controls in the same two themes: the filled button is the kit's `action`, and the destructive one its red.
    func testTheControlsInTwoThemes() throws {
        for kit in [StyleKitFixtures.newsprint, StyleKitFixtures.glassmorphism] {
            let pixels = try render(in: kit, named: "design-controls-\(kit.id)", size: CGSize(width: 393, height: 940)) { controlsPage() }
            let edge = try XCTUnwrap(pixels.color(x: 2, y: 930), "\(kit.id): no pixel at the edge")
            XCTAssertTrue(PixelBuffer.same(edge, kit.colors.background.hex), "\(kit.id): the page")
            XCTAssertTrue(pixels.column(x: 30, contains: kit.colors.destructive.hex), "\(kit.id): the destructive button is the kit's red")
            XCTAssertTrue(pixels.column(x: 30, contains: kit.colors.action.hex), "\(kit.id): the filled button is the kit's action fill")
        }
    }

    /// The Appearance pane, in the theme it offers: the picked theme is worn by the pane that picks it.
    func testTheAppearancePaneWearsTheTheme() throws {
        let kit = StyleKitFixtures.newsprint
        let suite = "hv-appearance-snapshot-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        // The pane is given a store of its own that does not touch the process's look; the test wears the kit itself.
        let store = StyleKitStore(defaults: defaults, wearer: RecordingWearer())
        var capabilities = RealmsPreviewData.capabilities
        capabilities.features.stylekit = true
        let body = String(decoding: try JSONEncoder().encode(kit), as: UTF8.self)
        let routes: [MockRoute] = [.json(.get, "/api/dashboard-theme", #"{"theme":"newsprint","kit":\#(body)}"#)]
        let pixels = try render(in: kit, named: "pane-appearance-newsprint", size: CGSize(width: 393, height: 852)) {
            PreviewHost(routes: routes, capabilities: capabilities, style: store) { AppearancePane() }
        }
        let edge = try XCTUnwrap(pixels.color(x: 2, y: 840))
        XCTAssertTrue(PixelBuffer.same(edge, kit.colors.background.hex), "the pane is on the theme's page")
        XCTAssertEqual(store.look, .worn(name: "Newsprint", adjusted: false), "and says what the app is wearing")
    }
}
