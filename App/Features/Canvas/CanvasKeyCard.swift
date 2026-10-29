import HyperVaultKit
import SwiftUI

/// Open on a key card of the Home canvas: the entry's own page from the Vault, over the canvas, so that who may use a key can
/// be changed, and the key renamed, from the card's own place. A key card lists the agents that may use the entry and
/// holds nothing else (never a value), and the page it opens is the same one the Vault pane opens, which keeps a value
/// behind its lock.
enum CanvasKeyCard {
    /// Where Open goes when the entry cannot be shown: the Vault's list, which is where it went before the card had a page of
    /// its own to open.
    static let fallback = DeepLink.account(.vault)

    /// The entry a key card stands for on its way to the sheet, or nil for a card that is not a key. Nothing is read here: a
    /// card on the canvas has not read the vault, so the sheet does, with a loading state while it waits.
    @MainActor
    static func target(for card: CanvasCard, env: AppEnvironment) -> CanvasKeyTarget? {
        guard card.kind == .key else { return nil }
        return CanvasKeyTarget(
            id: card.key,
            entryID: card.ref?.id,
            name: card.title,
            entries: VaultItemsModel(client: env.client, rest: env.keysRest, userID: env.user.id)
        )
    }
}

/// A key's entry on its way to the sheet, `Identifiable` (by its card's key) so a sheet can be driven by it.
struct CanvasKeyTarget: Identifiable {
    /// What the sheet is for, as its outcome stands.
    enum Outcome: Equatable {
        /// The vault has not answered yet.
        case loading
        /// The vault could not be read: the sentence to show.
        case failed(String)
        /// The vault answered and the entry is in it.
        case found(VaultSecret)
        /// The vault answered and the entry is not in it: it was deleted somewhere else after the card was put on the page.
        case gone
    }

    /// The card's key (`key:<id>`).
    let id: String
    /// The stored row the card stands for. It is the vault entry's own id, and it follows the entry through a rename on
    /// another device, which the card's title does not.
    let entryID: String?
    /// The title the card had, which finds the entry when its id finds nothing.
    let name: String
    let entries: VaultItemsModel

    @MainActor
    var outcome: Outcome {
        switch entries.phase {
        case .loading:
            return .loading
        case .failed(let message):
            return .failed(message)
        case .loaded:
            if let entryID, let entry = entries.secret(id: entryID) { return .found(entry) }
            if let entry = entries.secret(named: name) { return .found(entry) }
            return .gone
        }
    }
}

/// The sheet over the canvas. The card has not read the vault, so this opens at once with a loading state for the entry's
/// name and then shows the entry's page: the one the Vault pane opens, with its switches for the agents that may use the
/// entry, Rename, and no way to see the value. An entry that is not in the vault any more has no page to show, and the sheet
/// does not say so: it asks to be taken away (`onGone`) for the place Open used to go.
struct CanvasKeySheet: View {
    let target: CanvasKeyTarget
    let onGone: () -> Void

    @Environment(\.dismiss) private var dismiss
    /// The entry's name once it was found. From then on its page is on screen, and stays there whatever the list does:
    /// the page follows the entry by its id, and is the one that closes the sheet when the entry is deleted from it.
    @State private var entryName: String?

    var body: some View {
        NavigationStack {
            if let entryName {
                VaultItemDetailView(name: entryName, model: target.entries)
            } else {
                waiting
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { await load() }
    }

    /// Until the entry is known: the loading state, or the sentence for a vault that could not be read. An entry found, or
    /// gone, is a moment away from being the page or from being closed, so the loading state stays: nothing is flashed.
    private var waiting: some View {
        Group {
            if case .failed(let message) = target.outcome {
                HVErrorState(message: message) { Task { await load() } }
            } else {
                HVLoadingState(message: VaultCopy.loadingLine)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .hvScreenBackground()
        .navigationTitle(target.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .accessibilityIdentifier("canvas.key.done")
            }
        }
    }

    private func load() async {
        guard entryName == nil else { return }
        let opened = Date()
        await target.entries.load()
        switch target.outcome {
        case .found(let entry):
            entryName = entry.name
        case .gone:
            // A sheet that is still sliding up cannot be closed: the request is dropped, and the sheet is left on screen. A
            // vault that answers faster than that waits out the rest of the slide, which costs nothing on a key that is gone.
            let slide = Self.slideUp - Date().timeIntervalSince(opened)
            if slide > 0 { try? await Task.sleep(nanoseconds: UInt64(slide * 1_000_000_000)) }
            // The sheet was closed in the meantime (Done, or a swipe down): it has gone already, and nobody is waiting.
            guard !Task.isCancelled else { return }
            onGone()
        case .loading, .failed:
            break
        }
    }

    /// About as long as a sheet takes to come up.
    private static let slideUp: TimeInterval = 0.5
}
