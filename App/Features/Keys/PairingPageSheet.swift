import HyperVaultKit
import SwiftUI

extension Notification.Name {
    /// A key may have been made or taken away somewhere else (the website's pairing page was closed); lists reload.
    static let hvKeysChanged = Notification.Name("store.hypervault.keysChanged")
}

/// A `hypervault://pair` link: an AI tool showed its person a code, and the person answers on the website's own
/// pairing page, in Safari. The app does not approve a pairing itself. The server takes an answer only from a page
/// of the site, and a request the app builds cannot honestly say that it came from one.
struct PairingPageSheet: View {
    let code: String?

    @Environment(AppEnvironment.self) private var env

    var body: some View {
        KeysSafariSheet(url: PairingCode.pageURL(server: env.server.baseURL, code: code))
            .ignoresSafeArea()
            .onDisappear { NotificationCenter.default.post(name: .hvKeysChanged, object: nil) }
    }
}
