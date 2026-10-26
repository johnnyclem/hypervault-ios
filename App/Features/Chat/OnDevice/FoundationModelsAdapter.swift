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
    static func status() -> ChatOnDeviceStatus {
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

    /// Apple's errors, said in plain words.
    static func explain(_ error: Error) -> String {
        if let failure = error as? LanguageModelSession.GenerationError {
            switch failure {
            case .exceededContextWindowSize:
                return "That conversation is too long for the model on this iPhone. Start a new chat, or choose a connected model."
            case .guardrailViolation:
                return "Apple's on-device model won't answer that one. Try asking another way, or choose a connected model."
            case .unsupportedLanguageOrLocale:
                return "The model on this iPhone doesn't support this language yet."
            case .assetsUnavailable:
                return "The model on this iPhone isn't ready yet. Try again in a little while."
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
                do {
                    let session = LanguageModelSession(instructions: instructions)
                    for try await snapshot in session.streamResponse(to: prompt) {
                        continuation.yield(snapshot.content)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: OnDeviceChatError.generation(ChatFoundationModelsAdapter.explain(error)))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
