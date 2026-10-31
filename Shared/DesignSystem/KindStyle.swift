import HyperVaultKit
import SwiftUI

/// How each of the five nouns looks wherever it appears: a card, a row, a chip, a node on a graph.
///
/// `tint` is the one place a noun is given a colour. The cards and rows read it, and so do the Library graph and the
/// Memory map's page diamond, so a page is blue in all of them. Chat's colours say who spoke (`ChatAgentTone`) and are
/// not these. The Memory map colours a memory by where it came from, in its own four hues (`MemoryStyle.graphTint`), so a
/// memory is not always violet there.
///
/// A graph draws in four hues that sit well apart on the colour wheel (violet, blue, mint and amber) and names what each
/// one means in its legend and its callout. File is `Palette.sky`, about 20 degrees of hue from blue and not told apart
/// from it at node size, so a graph leaves it, and every node that is none of the four, in `Palette.textSecondary`. All
/// five hold 4.5:1 on the page and on paper in both looks, so they are text as well as marks. On raised paper blue is
/// 4.36:1 in the dark look and 4.43:1 in the light look, and amber 4.31:1 in the light look: the recorded lows.
extension KeptKind {
    var symbol: String {
        switch self {
        case .memory: return HVSymbol.memory
        case .page: return "doc.richtext"
        case .file: return "doc.fill"
        case .group: return "square.stack.3d.up"
        case .key: return HVSymbol.key
        }
    }

    var tint: Color {
        switch self {
        case .memory: return Palette.violet
        case .page: return Palette.blue
        case .file: return Palette.sky
        case .group: return Palette.mint
        case .key: return Palette.amber
        }
    }
}
