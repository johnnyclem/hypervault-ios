import HyperVaultKit
import SwiftUI

/// Settings: the web's You page, `/vault/account`, as a list of its seven panes in the web's order. It is the second step of
/// the Account sheet's stack (`AccountMenuSheet`: the menu, then this list, then the pane), on a phone and on an iPad alike,
/// so a pane is always one push away from the list and one more from the menu.
///
/// A pane is chosen with `AppRouter.openPane`, which pushes it on the sheet's path, and a link brings one forward with
/// `AppRouter.showSettings`. The rows are buttons and not `NavigationLink`s because a link draws the system's chevron at every
/// text size, and at an accessibility size the chevron is left off so the name has the row's whole width.
struct SettingsListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        List {
            ForEach(AccountPane.allCases) { pane in
                Button {
                    model.router.openPane(pane)
                } label: {
                    HStack(spacing: HV.Space.xs) {
                        paneLabel(pane)
                            .foregroundStyle(Palette.textPrimary)
                        Spacer(minLength: HV.Space.xs)
                        if !dynamicTypeSize.isAccessibilitySize {
                            HVIcon(HVSymbol.open)
                                .font(.hvCaption.weight(.semibold))
                                .foregroundStyle(Palette.textTertiary)
                        }
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(Palette.surface)
                .listRowSeparatorTint(Palette.hairline)
                .accessibilityIdentifier("settings.pane.\(pane.rawValue)")
            }
        }
        .scrollContentBackground(.hidden)
        .hvScreenBackground()
        .navigationTitle(AccountMenu.settings)
        .keysLargeTitle()
    }

    /// A pane's symbol and name. At an accessibility text size the symbol goes above the name and the chevron is left
    /// off, so the name has the row's whole width and is not broken in the middle of a word.
    @ViewBuilder
    private func paneLabel(_ pane: AccountPane) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: HV.Space.xs) {
                HVIcon(pane.symbol)
                Text(pane.label)
            }
        } else {
            Label(pane.label, systemImage: pane.symbol)
        }
    }
}

#if DEBUG
#Preview("Settings") {
    PreviewHost { SettingsListView() }
}
#endif
