import SwiftUI

/// A sheet's Close button: an X, named "Close" (handoff 4.4). Put it in `.cancellationAction`.
struct VaultCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
        }
        .accessibilityLabel(VaultScreenCopy.closeLabel)
    }
}

enum VaultAnnouncement {
    /// A line spoken when VoiceOver is next free, behind what it is already saying: the web's `aria-live="polite"`.
    /// The error announcements go through `VoiceOverAnnouncer`, which speaks over it.
    @MainActor
    static func polite(_ text: String) {
        var spoken = AttributedString(text)
        spoken.accessibilitySpeechAnnouncementPriority = .low
        AccessibilityNotification.Announcement(spoken).post()
    }
}

extension View {
    /// For a sheet that holds what a person typed: a swipe down cannot drop it, and Close asks first. The web drops typed
    /// values on close without asking; a native sheet is too easy to throw away by accident for that.
    ///
    /// `isDirty` is whether anything typed would be lost; with nothing typed, the sheet closes as any other does. The
    /// Close button sets `isPresented` when it is dirty, and `discard` runs when the person confirms.
    func vaultDiscardGuard(isDirty: Bool, isPresented: Binding<Bool>, discard: @escaping () -> Void) -> some View {
        self
            .interactiveDismissDisabled(isDirty)
            .confirmationDialog(VaultScreenCopy.discardTitle, isPresented: isPresented, titleVisibility: .visible) {
                Button(VaultScreenCopy.discardLabel, role: .destructive, action: discard)
                Button(VaultScreenCopy.keepEditingLabel, role: .cancel) {}
            } message: {
                Text(VaultScreenCopy.discardMessage)
            }
    }
}
