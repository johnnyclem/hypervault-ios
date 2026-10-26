import SwiftUI
import XCTest
@testable import HyperVault

@MainActor
final class OnboardingSnapshotTests: XCTestCase {
    func testWelcomePages() throws {
        try snapshot(ZStack { AuroraBackground(); WelcomePageKeep() }, named: "welcome-1-keep")
        try snapshot(ZStack { AuroraBackground(); WelcomePageTalk() }, named: "welcome-2-talk")
        try snapshot(ZStack { AuroraBackground(); WelcomePageAnyAI() }, named: "welcome-3-any-ai")
        try snapshot(ZStack { AuroraBackground(); WelcomePageSecrets() }, named: "welcome-4-secrets")
    }

    func testStates() throws {
        try snapshot(
            VStack(spacing: 24) {
                HVEmptyState(symbol: "tray", title: "Nothing kept yet.", message: "Ask your AI to keep something.", actionTitle: "Copy a starter prompt") {}
                HVErrorState(message: "Network hiccup. That did not load. Try again.") {}
                HVListSkeleton(rows: 3)
            }
            .padding()
            .hvScreenBackground(),
            named: "states"
        )
    }

    func testSettings() throws {
        try snapshot(PreviewHost { SettingsRootView() }, named: "settings")
    }

    func testYouTab() throws {
        try snapshot(PreviewHost { YouRootView() }, named: "you")
    }
}
