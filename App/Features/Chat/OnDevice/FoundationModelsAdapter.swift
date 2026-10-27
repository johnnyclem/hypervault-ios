import HyperVaultKit
import SwiftUI

// The one place the Foundation Models framework is touched. Everything else
// (context, history, saving, the outbox) is the Kit's `OnDeviceChat`, tested on
// Linux with a fake model; this file is only the thin part that talks to
// Apple's model. It is compiled only where the framework exists (Xcode 26 and
// later) and used only on iOS 26, so the app still builds and runs on iOS 17.
#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, *)
enum ChatFoundationModelsAdapter {
    private static let gate = NSLock()
    private static var assetsBroken = false
    /// Coming back from Settings is the moment a download can have finished.
    /// The next status check should trust Apple again, and the next message
    /// tries the model instead of repeating the old failure.
    private static let becameActive: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil
    ) { _ in noteWorking() }

    static func noteAssetFailure() {
        gate.lock()
        assetsBroken = true
        gate.unlock()
    }

    static func noteWorking() {
        gate.lock()
        assetsBroken = false
        gate.unlock()
    }

    private static var assetsAreBroken: Bool {
        gate.lock()
        defer { gate.unlock() }
        return assetsBroken
    }

    static func status() -> ChatOnDeviceStatus {
        _ = becameActive
        if assetsAreBroken { return .unavailable(OnDeviceModelAssets.explanation) }
        switch SystemLanguageModel.default.availability {
        case .available:
            return .ready
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .unavailable("This iPhone can't run Apple Intelligence, so it can't write replies itself. Connect a model to chat.")
            case .appleIntelligenceNotEnabled:
                return .unavailable("Apple Intelligence is turned off. Turn it on in Settings, under Apple Intelligence & Siri, to chat on this iPhone.")
            case .modelNotReady:
                return .unavailable("The model on this iPhone is still getting ready. Try again in a little while.")
            @unknown default:
                return .unavailable("The model on this iPhone isn't available right now.")
            }
        @unknown default:
            return .unavailable("The model on this iPhone isn't available right now.")
        }
    }

    static func isAssetFailure(_ error: Error) -> Bool {
        if OnDeviceModelAssets.isMissing(error) { return true }
        if #available(iOS 27.0, *), let failure = error as? SystemLanguageModel.Error, case .assetsUnavailable = failure {
            return true
        }
        if let failure = error as? LanguageModelSession.GenerationError, case .assetsUnavailable = failure {
            return true
        }
        return false
    }

    /// Apple's errors, said in plain words.
    static func explain(_ error: Error) -> String {
        if isAssetFailure(error) { return OnDeviceModelAssets.explanation }
        if let failure = error as? LanguageModelSession.GenerationError {
            switch failure {
            case .exceededContextWindowSize:
                return "That conversation is too long for the model on this iPhone. Start a new chat, or choose a connected model."
            case .guardrailViolation:
                return "Apple's on-device model won't answer that one. Try asking another way, or choose a connected model."
            case .unsupportedLanguageOrLocale:
                return "The model on this iPhone doesn't support this language yet."
            default:
                break
            }
        }
        return error.localizedDescription
    }
}

@available(iOS 26.0, *)
struct ChatFoundationModelsProvider: ChatModelProvider {
    let modelName = "apple-on-device"
    /// About four thousand tokens in all, answer included: a little over two
    /// thousand tokens (roughly seven thousand characters) go to what it reads.
    let contextBudget = 7_000

    func generate(system: String, messages: [ChatWireMessage]) -> AsyncThrowingStream<String, Error> {
        let instructions = OnDevicePrompt.instructions(system: system)
        let prompt = OnDevicePrompt.prompt(messages: messages)
        return AsyncThrowingStream { continuation in
            let task = Task {
                // Default guardrails insert a safety-guardrail token the phone
                // may not have downloaded. Chat is a transformation of the
                // person's own words, which is what the permissive setting is
                // for, and it does not ask for that token. If that setting
                // itself is refused for some other reason, the default model
                // still gets one try. A missing asset fails both, so it is not
                // tried twice.
                let permissive = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
                let yielded = Yielded()
                do {
                    try await Self.respond(model: permissive, instructions: instructions, prompt: prompt, yielded: yielded, continuation: continuation)
                    ChatFoundationModelsAdapter.noteWorking()
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    if yielded.value || ChatFoundationModelsAdapter.isAssetFailure(error) {
                        if ChatFoundationModelsAdapter.isAssetFailure(error) { ChatFoundationModelsAdapter.noteAssetFailure() }
                        continuation.finish(throwing: OnDeviceChatError.generation(ChatFoundationModelsAdapter.explain(error)))
                        return
                    }
                    do {
                        try await Self.respond(model: .default, instructions: instructions, prompt: prompt, yielded: yielded, continuation: continuation)
                        ChatFoundationModelsAdapter.noteWorking()
                        continuation.finish()
                    } catch is CancellationError {
                        continuation.finish(throwing: CancellationError())
                    } catch {
                        if ChatFoundationModelsAdapter.isAssetFailure(error) { ChatFoundationModelsAdapter.noteAssetFailure() }
                        continuation.finish(throwing: OnDeviceChatError.generation(ChatFoundationModelsAdapter.explain(error)))
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func respond(
        model: SystemLanguageModel, instructions: String, prompt: String, yielded: Yielded,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        let session = LanguageModelSession(model: model, instructions: instructions)
        for try await snapshot in session.streamResponse(to: prompt) {
            try Task.checkCancellation()
            yielded.value = true
            continuation.yield(snapshot.content)
        }
    }
}

/// Set from the stream loop. A class so the flag survives the `await`.
private final class Yielded: @unchecked Sendable {
    var value = false
}
#endif
