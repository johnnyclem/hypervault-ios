import HyperVaultKit
import SwiftUI

/// One pane of Settings: the screen already built for it, under the pane's name. The web's panes are Settings, the
/// Vault, Agent keys, Models, Domain, Appearance and Import; the heading is the navigation title, and a pane whose
/// screen has a line to say under it says it above its first group.
///
/// The Vault and Domain screens name themselves (the same word, with the large title, and the Vault's own add button and
/// search), so the pane puts no second title on them. Every pane is pushed on the Account sheet's navigation stack
/// (`AccountMenuSheet`), which those screens need for their own toolbar and pushes.
struct AccountPaneView: View {
    let pane: AccountPane

    @Environment(AppEnvironment.self) private var env

    var body: some View {
        switch pane {
        case .vault: VaultItemsView()
        case .domain: RealmsRootView()
        case .general: titled(GeneralPane())
        case .keys: titled(AgentsAndKeysView())
        case .backends: titled(ChatModelsContent(env: env, onChange: nil, embedded: true))
        case .appearance: titled(AppearancePane())
        case .import: titled(ImportPane())
        }
    }

    private func titled<Content: View>(_ content: Content) -> some View {
        content
            .navigationTitle(pane.label)
            .keysLargeTitle()
    }
}
