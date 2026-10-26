import AVFoundation
import HyperVaultKit
import NaturalLanguage
import SwiftUI

/// Reads a reply aloud with the system's voices. One reply at a time; tapping
/// the speaker again stops it. The audio session is claimed only at the moment
/// the person taps speak (the playback category, so the silent switch does not
/// mute something they just asked for) and given back when it ends.
@MainActor
@Observable
final class ChatSpeechController: NSObject {
    private(set) var speakingID: String?

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func isSpeaking(_ id: String) -> Bool { speakingID == id }

    func toggle(id: String, text: String) {
        if speakingID == id {
            stop()
        } else {
            speak(id: id, text: text)
        }
    }

    func stop() {
        guard speakingID != nil else { return }
        speakingID = nil
        synthesizer.stopSpeaking(at: .immediate)
        releaseAudio()
    }

    private func speak(id: String, text: String) {
        synthesizer.stopSpeaking(at: .immediate)
        let spoken = ChatMarkdown.plainText(text)
        guard !spoken.isEmpty else { return }
        claimAudio()
        let utterance = AVSpeechUtterance(string: spoken)
        utterance.voice = Self.bestVoice(for: spoken)
        utterance.prefersAssistiveTechnologySettings = true
        speakingID = id
        synthesizer.speak(utterance)
    }

    private func claimAudio() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
    }

    private func releaseAudio() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Choosing a voice

    /// The best installed voice for the language the reply is in (falling back
    /// to the phone's language): premium, then enhanced, then standard.
    static func bestVoice(for text: String) -> AVSpeechSynthesisVoice? {
        let code = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue
            ?? Locale.preferredLanguages.first.flatMap { Locale(identifier: $0).language.languageCode?.identifier }
            ?? "en"
        let region = Locale.current.region?.identifier
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(code) }
        let ranked = voices.sorted { lhs, rhs in
            let left = rank(lhs, region: region)
            let right = rank(rhs, region: region)
            return left != right ? left > right : lhs.name < rhs.name
        }
        return ranked.first ?? AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
    }

    private static func rank(_ voice: AVSpeechSynthesisVoice, region: String?) -> Int {
        var score = 0
        switch voice.quality {
        case .premium: score += 20
        case .enhanced: score += 10
        default: break
        }
        if let region, voice.language.hasSuffix(region) { score += 4 }
        return score
    }
}

extension ChatSpeechController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }

    private func finished() {
        // A new utterance may already have started; only the last one ends the session.
        guard !synthesizer.isSpeaking else { return }
        speakingID = nil
        releaseAudio()
    }
}
