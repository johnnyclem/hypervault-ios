import SwiftUI

/// Where a spoken result goes. A job that finished, a name that turned out to be free or a reply that arrived
/// shows up somewhere VoiceOver is not looking, so it is said as well as shown. Going through this lets a test
/// read what would have been said.
@MainActor
protocol FeatureAnnouncer: AnyObject {
    func announce(_ text: String)
}

/// Speaks through VoiceOver. An outcome is posted with high priority: the system is usually still reading the
/// control that was just activated, and a plain announcement made then is cut off.
@MainActor
final class VoiceOverFeatureAnnouncer: FeatureAnnouncer {
    /// Reachable from a default argument, which is not on the main actor; there is no state to protect.
    nonisolated static let shared = VoiceOverFeatureAnnouncer()

    nonisolated private init() {}

    func announce(_ text: String) {
        var spoken = AttributedString(text)
        spoken.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(spoken).post()
    }
}
