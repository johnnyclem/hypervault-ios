import HyperVaultKit
import SwiftUI

extension AppEnvironment {
    /// Keeps whatever the share sheet saved while it could not reach the server. Called when the app
    /// opens and each time it comes back to the foreground.
    func flushOutbox(toasts: ToastCenter) async {
        let items = OutboxStore.load()
        guard !items.isEmpty else { return }
        let client = self.client
        let result = await Outbox.flush(items) { item in
            _ = try await client.send(.keep(content: item.content, sourcePrompt: item.sourcePrompt))
        }
        OutboxStore.remove(ids: Set((result.kept + result.dropped).map(\.id)))
        if !result.kept.isEmpty {
            Haptics.success()
            WidgetRefresh.reload()
            toasts.success(result.kept.count == 1 ? "Kept the thing you shared" : "Kept \(result.kept.count) things you shared")
        }
        if !result.dropped.isEmpty {
            toasts.show("\(result.dropped.count) shared item\(result.dropped.count == 1 ? " was" : "s were") too large to keep", style: .error)
        }
    }
}
