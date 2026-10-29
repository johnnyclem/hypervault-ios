import HyperVaultKit
import SwiftUI

/// Share on a card of the Home canvas: the people-and-role sheet a page has under its Share button, opened over the canvas.
enum CanvasShare {
    /// The page the share sheet takes for a card, or nil for a card that offers no Share. A page, a file and a group do,
    /// because each has a link to give and people to give it to (they are the cards that have a slug); a memory and a key
    /// have neither, as on the web. The card's kind is passed along so a group's link is on `/g/` from the first moment,
    /// before the sheet has read anything.
    @MainActor
    static func target(for card: CanvasCard, env: AppEnvironment) -> CanvasShareTarget? {
        guard let slug = card.slug else { return nil }
        return CanvasShareTarget(id: slug, detail: ArtifactDetailModel(slug: slug, env: env, kindHint: card.kind))
    }
}

/// A page on its way to the share sheet, `Identifiable` (by its slug) so a sheet can be driven by it.
struct CanvasShareTarget: Identifiable {
    let id: String
    let detail: ArtifactDetailModel
}

/// The share sheet over the canvas. The page's screen has read the page before its Share is tapped; a card on the canvas
/// has not, so this opens at once with a loading state while the sheet's model reads what the link and its line need (the
/// title, who can open the page, whether it is a group, the person's own addresses), and then shows the sheet itself, which
/// reads who has the page and says what went wrong in its own words.
struct CanvasShareSheet: View {
    let detail: ArtifactDetailModel

    @Environment(\.dismiss) private var dismiss
    @State private var ready = false

    var body: some View {
        Group {
            if ready {
                ArtifactShareSheet(detail: detail)
            } else {
                loading
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            await detail.loadForSharing()
            ready = true
        }
    }

    private var loading: some View {
        NavigationStack {
            HVLoadingState()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .hvScreenBackground()
                .navigationTitle("Share")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
    }
}
