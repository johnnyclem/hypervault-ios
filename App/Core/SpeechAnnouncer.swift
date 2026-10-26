import SwiftUI

/// Where a spoken result goes. The toasts and the canvas say what happened through this, so a test can read
/// what VoiceOver would have been told.
@MainActor
protocol SpeechAnnouncer: AnyObject {
    func announce(_ text: String)
}

/// Speaks through VoiceOver. An outcome is posted with high priority: the system is usually still reading the
/// control that was just activated, and a plain announcement made in that moment is cut off.
@MainActor
final class VoiceOverAnnouncer: SpeechAnnouncer {
    /// Reachable from a default argument, which is not on the main actor; the announcer has no state to protect.
    nonisolated static let shared = VoiceOverAnnouncer()

    nonisolated private init() {}

    func announce(_ text: String) {
        var spoken = AttributedString(text)
        spoken.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(spoken).post()
    }
}
