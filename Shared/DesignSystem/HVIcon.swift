import SwiftUI

/// A symbol that is only decoration: drawn, and never spoken. Beside the words that already name the same thing,
/// VoiceOver would read the symbol's own description as well ("key", "chevron right"), so the person hears it twice or
/// hears noise (handoff 2.7 and 9). `HVSymbol` names the symbol of each concept.
///
/// A symbol that is the whole label of a control is not decoration: give the control an accessibility label instead.
/// A `Label(title, systemImage:)` already hides its symbol, so it needs none of this.
///
///     HStack { HVIcon(HVSymbol.key); Text("Agent keys") }
struct HVIcon: View {
    let name: String

    init(_ name: String) {
        self.name = name
    }

    var body: some View {
        Image(systemName: name).accessibilityHidden(true)
    }
}

extension View {
    /// Hides a drawn thing that says nothing the words beside it do not, such as a mark or a tile, from VoiceOver.
    func hvDecorative() -> some View {
        accessibilityHidden(true)
    }
}

#Preview("Icons") {
    VStack(alignment: .leading, spacing: HV.Space.s) {
        HStack { HVIcon(HVSymbol.agentKeys); Text("Agent keys") }
        HStack { HVIcon(HVSymbol.vault); Text("Vault") }
        HStack { Text("Open"); HVIcon(HVSymbol.open).foregroundStyle(Palette.textSecondary) }
    }
    .padding(HV.Space.m)
    .hvScreenBackground()
}
