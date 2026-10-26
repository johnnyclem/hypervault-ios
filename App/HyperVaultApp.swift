import SwiftUI

@main
struct HyperVaultApp: App {
    @State private var model = AppModel()
    @AppStorage(PrefKey.appearance) private var appearance = AppearanceChoice.system
    @AppStorage(PrefKey.accent) private var accent = AccentChoice.blue

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(accent.color)
                .preferredColorScheme(appearance.colorScheme)
                .onOpenURL { url in model.handle(url: url) }
                .task { await model.start() }
        }
    }
}
