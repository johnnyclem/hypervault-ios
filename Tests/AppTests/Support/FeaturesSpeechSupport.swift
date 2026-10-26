@testable import HyperVault

/// Stands in for VoiceOver: keeps what a screen asked to have said, in order.
@MainActor
final class FeaturesRecordingAnnouncer: FeatureAnnouncer {
    private(set) var spoken: [String] = []

    func announce(_ text: String) {
        spoken.append(text)
    }

    /// Forgets what was said so far, to look only at what a step adds.
    func clear() {
        spoken = []
    }
}
