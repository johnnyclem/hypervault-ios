import HyperVaultKit
import SwiftUI

/// How each of the five nouns looks wherever it appears: a card, a row, a chip.
extension KeptKind {
    var symbol: String {
        switch self {
        case .memory: return "brain.head.profile"
        case .page: return "doc.richtext"
        case .file: return "doc.fill"
        case .group: return "square.stack.3d.up"
        case .key: return "key.horizontal"
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
