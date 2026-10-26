import HyperVaultKit
import SwiftUI

/// The tile that leads a vault row: a card in its brand's colours (read from the hint, the only part of a
/// card the app ever has), a monogram for a login, a person for contact info (a house when it is only an
/// address), a key for everything else. Logins get a monogram rather than the site's icon: fetching an icon
/// would tell a third party which sites are in the vault.
struct VaultTile: View {
    let secret: VaultSecret
    var size: CGFloat = 36

    var body: some View {
        Group {
            switch secret.kind.category {
            case .cards: card
            case .logins: monogram
            case .contact: symbol(secret.hint == "Address" ? "house" : "person.crop.circle", tint: Palette.sky)
            case .keys: symbol("key.horizontal", tint: Palette.amber)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var card: some View {
        if let brand = secret.cardBrand, brand != .other {
            // Drawn for a 36pt tile; it grows with the tiles beside it instead of sitting small in a larger box.
            VaultBrandCard(brand: brand).scaleEffect(size / 36)
        } else {
            symbol("creditcard", tint: Palette.violet)
        }
    }

    private var monogram: some View {
        Text(secret.monogram)
            .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
            .foregroundStyle(Palette.textPrimary)
            .frame(width: size, height: size)
            .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
    }

    private func symbol(_ name: String, tint: Color) -> some View {
        HVIconBadge(symbol: name, tint: tint, size: size)
    }
}

/// A small card in a brand's colours. A brand is recognised by its colour, so these stay fixed in light and
/// dark, as the web's tiles do; white reads on all of them.
struct VaultBrandCard: View {
    let brand: VaultItems.CardBrand

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(fill)
            .frame(width: 34, height: 24)
            .overlay(mark.foregroundStyle(.white))
            .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
            .accessibilityHidden(true)
    }

    private var fill: Color {
        switch brand {
        case .visa: return Color(hex: 0x1A1F71)
        case .amex: return Color(hex: 0x006FCF)
        case .discover: return Color(hex: 0xE55C20)
        case .mastercard: return Color(hex: 0x1C1C1E)
        case .other: return Palette.textSecondary
        }
    }

    @ViewBuilder
    private var mark: some View {
        switch brand {
        case .visa: Text("VISA").font(.system(size: 8, weight: .black).italic())
        case .amex: Text("AMEX").font(.system(size: 7, weight: .black))
        case .discover: Text("DISC").font(.system(size: 7, weight: .black))
        case .mastercard:
            HStack(spacing: -5) {
                Circle().fill(Color(hex: 0xEB001B)).frame(width: 11, height: 11)
                Circle().fill(Color(hex: 0xF79E1B)).opacity(0.9).frame(width: 11, height: 11)
            }
        case .other: Image(systemName: "creditcard").font(.system(size: 10))
        }
    }
}
