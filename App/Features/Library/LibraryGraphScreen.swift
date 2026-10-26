import HyperVaultKit
import SwiftUI

/// The Library's graph mode. It is the Memory tab's map (the web draws one graph for both), fed by a
/// list of its own so the two screens do not share a branch or a search.
struct LibraryGraphScreen: View {
    @State private var list: MemoryListModel

    init(env: AppEnvironment) {
        _list = State(initialValue: MemoryListModel(env: env))
    }

    var body: some View {
        MemoryGraphScreen(list: list)
            .task { await list.load() }
    }
}
