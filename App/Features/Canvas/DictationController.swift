import AVFoundation
import Speech
import SwiftUI

/// Why dictation did not start.
enum DictationProblem: Equatable {
    /// The recognizer is off for this language or the service is down.
    case unavailable
    /// The microphone or speech recognition was refused; only Settings can change that.
    case denied
    /// The audio session or engine would not start.
    case failed

    var line: String {
        switch self {
        case .unavailable: return "Dictation is not available right now."
        case .denied: return "Allow the microphone and speech recognition in Settings to dictate."
        case .failed: return "Dictation could not start."
        }
    }
}

/// Talking into the canvas. Recognition happens on the device when the language supports it, so
/// what is said does not leave the phone unless it has to.
@MainActor
@Observable
final class DictationController {
    private(set) var isListening = false
    private(set) var transcript = ""
    /// Set by the last `start` that did not get going, and cleared by the next one.
    private(set) var problem: DictationProblem?

    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?

    var isAvailable: Bool { recognizer?.isAvailable ?? false }

    func toggle() async {
        if isListening {
            stop()
        } else {
            await start()
        }
    }

    func start() async {
        problem = nil
        transcript = ""
        guard let recognizer, recognizer.isAvailable else {
            problem = .unavailable
            return
        }
        guard await authorizeSpeech(), await authorizeMicrophone() else {
            problem = .denied
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
            self.request = request

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()
            isListening = true
            Haptics.tap()

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result { self.transcript = result.bestTranscription.formattedString }
                    if error != nil || result?.isFinal == true { self.stop() }
                }
            }
        } catch {
            problem = .failed
            stop()
        }
    }

    func stop() {
        guard isListening || engine.isRunning else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isListening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func authorizeSpeech() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func authorizeMicrophone() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
