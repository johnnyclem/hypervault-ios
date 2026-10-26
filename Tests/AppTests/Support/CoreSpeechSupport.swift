@testable import HyperVault

/// Stands in for VoiceOver: keeps what the app asked to have said, in order.
@MainActor
final class CoreRecordingAnnouncer: SpeechAnnouncer {
    private(set) var spoken: [String] = []

    func announce(_ text: String) {
        spoken.append(text)
    }
}
