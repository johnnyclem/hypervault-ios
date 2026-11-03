import HyperVaultKit
import SwiftUI

/// The first-agent path: "Copy a starter prompt" puts a prompt on the pasteboard that the person pastes into the AI they
/// already use, and that AI sets up the connection. The canvas's hints and Home's starter page both offer it.
enum StarterPrompt {
    /// Puts the prompt for this server on the pasteboard, with the haptic that says it worked.
    @MainActor
    static func copy(origin: URL) {
        UIPasteboard.general.string = HVCopy.starterPrompt(origin: origin.absoluteString)
        Haptics.success()
    }

    /// How long the button says "Copied", and the line under it says what to do next.
    static let copiedFor: UInt64 = 4_000_000_000
}

/// The quiet button that copies the starter prompt, and the line that says what to do with it once it has. The owner keeps
/// the copied state (it is the owner's pasteboard call), so the button is the same on every page that offers it; each page
/// gives its own identifier (`canvas.starter` on the canvas, `home.starter` on Home).
struct StarterPromptButton: View {
    let copied: Bool
    let identifier: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            Button(action: action) {
                Label(copied ? "Copied" : HVCopy.copyPromptLabel, systemImage: copied ? HVSymbol.copied : HVSymbol.copy)
                    .font(.system(.subheadline, weight: .semibold))
            }
            .buttonStyle(.hvGhost)
            .tint(Palette.textSecondary)
            .accessibilityIdentifier(identifier)
            if copied {
                Text(HVCopy.copyPromptNextLine)
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.textSecondary)
                    .transition(.opacity)
            }
        }
        .hvAnimation(HV.Motion.entrance, value: copied)
    }
}
