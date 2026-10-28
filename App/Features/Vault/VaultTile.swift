import HyperVaultKit
import SwiftUI

/// The tile that leads a vault row: a card in its brand's colours (read from the hint, the only part of a
/// card the app ever has), a monogram for a login, a person for contact info (a house when it is only an
/// address), a key for everything else. Logins get a monogram rather than the site's icon: fetching an icon
/// would tell a third party which sites are in the vault.
///
/// The shapes are the design system's (`HVTile`, `HVCardBrandTile`): 36pt, drawn the same wherever an entry appears,
/// and hidden from VoiceOver, since the row's words say what the entry is.
struct VaultTile: View {
    let secret: VaultSecret
    var size: CGFloat = 36

    var body: some View {
        switch secret.kind.category {
        case .cards: card
        case .logins: HVTile(monogram: secret.monogram, size: size)
        case .contact: HVTile(symbol: secret.hint == "Address" ? HVSymbol.address : HVSymbol.contact, size: size)
        case .keys: HVTile(symbol: HVSymbol.key, size: size)
        }
    }

    @ViewBuilder
    private var card: some View {
        if let brand = secret.cardBrand, let tileBrand = HVCardBrand(brand) {
            // 36 by 24, centred in the tile's box; the marks do not scale with the box.
            HVCardBrandTile(brand: tileBrand).frame(width: size, height: size)
        } else {
            HVTile(symbol: HVSymbol.card, size: size)
        }
    }
}

extension HVCardBrand {
    /// The tile for a card brand the Kit recognised. An unrecognised one ("Card") has none, and is drawn on the neutral tile.
    init?(_ brand: VaultItems.CardBrand) {
        switch brand {
        case .visa: self = .visa
        case .amex: self = .amex
        case .discover: self = .discover
        case .mastercard: self = .mastercard
        case .other: return nil
        }
    }
}
