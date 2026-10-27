import SwiftUI
import XCTest
@testable import HyperVault

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

    private func swatch(_ name: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: HV.Radius.control, style: .continuous)
                .fill(color)
                .frame(height: 36)
                .overlay(RoundedRectangle(cornerRadius: HV.Radius.control, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
            Text(name).font(.system(size: 9)).foregroundStyle(Palette.textSecondary).lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    func testThePaletteOnItsSurfaces() throws {
        let tokens: [(String, Color)] = [
            ("background", HVColor.background), ("foreground", HVColor.foreground), ("card", HVColor.card),
            ("muted", HVColor.muted), ("muted-fg", HVColor.mutedForeground), ("primary", HVColor.primary),
            ("primary-fg", HVColor.primaryForeground), ("secondary", HVColor.secondary), ("accent", HVColor.accent),
            ("accent-fg", HVColor.accentForeground), ("border", HVColor.border), ("ring", HVColor.ring),
            ("destructive", HVColor.destructive), ("emerald-400", HVColor.emerald400), ("amber-400", HVColor.amber400),
        ]
        try snapshot(
            page {
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
            },
            named: "design-palette", size: CGSize(width: 393, height: 700)
        )
    }

    func testButtonsFieldsAndTags() throws {
        try snapshot(
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
                    HVTag(text: "Found for you", tint: Palette.cyan)
                    HVTag(text: "Default")
                    HVTag(text: "#tag")
                }
                HStack(spacing: HV.Space.xs) {
                    HVChip(title: "All 6", isSelected: true, minTarget: 0)
                    HVChip(title: "Files 2", minTarget: 0)
                    HVIconBadge(symbol: "key", tint: Palette.amber)
                    HVIconBadge(symbol: "doc", tint: Palette.blue)
                }
            },
            named: "design-controls", size: CGSize(width: 393, height: 940)
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
}
