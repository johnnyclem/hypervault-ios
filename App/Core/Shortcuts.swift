import AppIntents
import HyperVaultKit

/// "Keep this in HyperVault" for Siri, Shortcuts and the Action button. It keeps with the app's own
/// session, and when there is no network it saves the text to the outbox like the share sheet does.
struct KeepTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Keep in HyperVault"
    static let description = IntentDescription("Keeps some text and gives you its private link.")

    @Parameter(title: "Text", requestValueDialog: "What do you want to keep?")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Keep \(\.$text)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw ShortcutError.nothingToKeep }
        guard let (client, _) = SharedConfig.makeClient() else {
            OutboxStore.add(OutboxItem(content: content))
            return .result(value: "", dialog: "Open HyperVault and sign in. This will be kept as soon as you do.")
        }
        do {
            let kept = try await client.send(.keep(content: content))
            let base = SharedConfig.server.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return .result(value: "\(base)/a/\(kept.slug)", dialog: IntentDialog(stringLiteral: kept.duplicate ? HVCopy.alreadyKeptLine : HVCopy.keptLine))
        } catch {
            let failure = (error as? HVError) ?? .transport(error.localizedDescription)
            if Outbox.shouldRetain(after: failure) {
                OutboxStore.add(OutboxItem(content: content))
                return .result(value: "", dialog: "Saved. HyperVault will keep it the next time it can.")
            }
            throw ShortcutError.refused(failure.userMessage)
        }
    }
}

struct OpenCanvasIntent: AppIntent {
    static let title: LocalizedStringResource = "Open the canvas"
    static let description = IntentDescription("Opens HyperVault, ready to keep or ask.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        .result()
    }
}

enum ShortcutError: Error, CustomLocalizedStringResourceConvertible {
    case nothingToKeep
    case refused(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .nothingToKeep: return "There was nothing to keep."
        case .refused(let message): return LocalizedStringResource(stringLiteral: message)
        }
    }
}

struct HyperVaultShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: KeepTextIntent(),
            phrases: ["Keep this in \(.applicationName)", "Keep a note in \(.applicationName)"],
            shortTitle: "Keep",
            systemImageName: "tray.and.arrow.down"
        )
        AppShortcut(
            intent: OpenCanvasIntent(),
            phrases: ["Open \(.applicationName)"],
            shortTitle: "Open canvas",
            systemImageName: "sparkles"
        )
    }
}
