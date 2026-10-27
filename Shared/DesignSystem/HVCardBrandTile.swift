import SwiftUI

/// The card brands the web draws a tile for. Anything else is a plain card on the neutral tile.
enum HVCardBrand: CaseIterable {
    case visa, amex, discover, mastercard
}

/// A card in its brand's colours, 36 by 24 with 5pt corners, centred in the 36pt box of a row's tile. A card is
/// recognised by its colour, so these are fixed (tokens.json `fixed`) and the same under any look; white reads on all
/// of them. The marks are 7 to 8pt and do not scale, and the tile is hidden from VoiceOver: the row's words carry the
/// brand and the last four digits (handoff 4.3).
struct HVCardBrandTile: View {
    let brand: HVCardBrand

    var body: some View {
        RoundedRectangle(cornerRadius: HV.Radius.brandTile, style: .continuous)
            .fill(fill)
            .frame(width: 36, height: 24)
            .overlay(mark.foregroundStyle(.white))
            .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
            .accessibilityHidden(true)
    }

    private var fill: Color {
        switch brand {
        case .visa: return Color(hex: HVTokens.Fixed.cardVisa)
        case .amex: return Color(hex: HVTokens.Fixed.cardAmex)
        case .discover: return Color(hex: HVTokens.Fixed.cardDiscover)
        case .mastercard: return Color(hex: HVTokens.Fixed.cardMastercard)
        }
    }

    @ViewBuilder
    private var mark: some View {
        switch brand {
        case .visa: Text("VISA").font(.system(size: 8, weight: .black).italic())
        case .amex: Text("AMEX").font(.system(size: 7, weight: .black))
        case .discover: Text("DISC").font(.system(size: 7, weight: .black))
        case .mastercard:
            // Two 12pt discs overlapping by 6.
            HStack(spacing: -6) {
                Circle().fill(Color(hex: HVTokens.Fixed.cardMastercardLeft)).frame(width: 12, height: 12)
                Circle()
                    .fill(Color(hex: HVTokens.Fixed.cardMastercardRight, opacity: HVTokens.Fixed.cardMastercardRightOpacity))
                    .frame(width: 12, height: 12)
            }
        }
    }
}

#Preview("Card brands") {
    HStack(spacing: HV.Space.s) {
        ForEach(HVCardBrand.allCases, id: \.self) { brand in
            HVCardBrandTile(brand: brand).frame(width: 36, height: 36)
        }
    }
    .padding(HV.Space.m)
    .hvScreenBackground()
}
