import CoreSpotlight
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
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    // A result tapped in Spotlight carries the hypervault:// link it was indexed with.
                    if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String, let url = URL(string: id) {
                        model.handle(url: url)
                    }
                }
                .task {
                    // Unit tests host the app; they must not go to the network.
                    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
                        await model.start()
                    }
                }
        }
    }
}
