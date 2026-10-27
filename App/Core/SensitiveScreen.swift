import SwiftUI

extension View {
    /// Marks a screen that shows or takes a value nobody should see in the app switcher's picture: a card number being
    /// typed, a replacement value, the one-time agent key. While it is up, leaving the foreground puts the blank card
    /// over the app (`PrivacyCoverController`), whether or not the Face ID lock is on. It never locks anything.
    ///
    /// `isOn` is for a screen that is only sometimes sensitive, such as a sheet that holds a key for as long as it has one.
    func hvSensitive(_ isOn: Bool = true) -> some View {
        modifier(SensitiveScreen(isOn: isOn))
    }
}

private struct SensitiveScreen: ViewModifier {
    let isOn: Bool

    /// Optional so a screen drawn without the app around it (a preview) simply asks for nothing.
    @Environment(AppModel.self) private var model: AppModel?
    /// This screen's name in the lock's count: it is counted once however many times it reports.
    @State private var screen = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { report() }
            .onChange(of: isOn) { _, _ in report() }
            .onDisappear { model?.lock.endSensitive(screen) }
    }

    @MainActor
    private func report() {
        if isOn { model?.lock.beginSensitive(screen) } else { model?.lock.endSensitive(screen) }
    }
}
