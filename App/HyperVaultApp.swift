import CoreSpotlight
import SwiftUI

@main
struct HyperVaultApp: App {
    @State private var model = HyperVaultApp.makeModel()

    init() {
        RetiredPreferences.remove()
        HVTabBarStyle.install()
    }

    var body: some Scene {
        WindowGroup {
            // The stock look is dark and has one accent, the web's primary (Info.plist declares the dark style, so the
            // launch screen, alerts and keyboard are dark from the first frame). The tint is set outright: a
            // Toggle with none draws system green.
            RootView()
                .environment(model)
                .tint(HVColor.primary)
                #if DEBUG
                .overlay(alignment: .topLeading) { UITestWritesBeacon() }
                #endif
                .onOpenURL { url in model.handle(url: url) }
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    // A result tapped in Spotlight carries the hypervault:// link it was indexed with.
                    if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String, let url = URL(string: id) {
                        model.handle(url: url)
                    }
                }
                .task {
                    if HyperVaultApp.startsModel {
                        await model.start()
                    }
                }
        }
    }

    /// The real app's model. A debug build launched by the UI tests (`-HV_UITEST`) gets one wired to canned answers
    /// instead; see `UITestHarness`.
    private static func makeModel() -> AppModel {
        // Before the first request: the system's cache keeps nothing the server said to a signed-in person.
        HVURLCache.install()
        #if DEBUG
        if let canned = UITestHarness.makeModel() { return canned }
        #endif
        return AppModel()
    }

    /// Whether launch should run. Unit tests host the app and must not go to the network; a UI-test launch is the exception,
    /// because its model only ever talks to the canned server.
    private static var startsModel: Bool {
        #if DEBUG
        if UITestHarness.isActive { return true }
        #endif
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    }
}
