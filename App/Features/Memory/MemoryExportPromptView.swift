import HyperVaultKit
import SwiftUI

/// The prompt that makes another AI hand over what it has learned about the
/// person: nothing needs exporting, they paste this into ChatGPT, Gemini or
/// Grok and bring the reply back to Memorize. Verbatim from the web app
/// (components/memory-export-prompt.tsx).
enum MemoryExportPrompt {
    static let text = """
    Export all of my stored memories and any context you've learned about me from past conversations. Preserve my words verbatim where possible, especially for instructions and preferences.

    ## Categories (output in this order):

    1. **Instructions**: Rules I've explicitly asked you to follow going forward — tone, format, style, "always do X", "never do Y", and corrections to your behavior. Only include rules from stored memories, not from conversations.

    2. **Identity**: Name, age, location, education, family, relationships, languages, and personal interests.

    3. **Career**: Current and past roles, companies, and general skill areas.

    4. **Projects**: Projects I meaningfully built or committed to. Ideally ONE entry per project. Include what it does, current status, and any key decisions. Use the project name or a short descriptor as the first words of the entry.

    5. **Preferences**: Opinions, tastes, and working-style preferences that apply broadly.

    ## Format:

    Use section headers for each category. Within each category, list one entry per line, sorted by oldest date first. Format each line as:

    [YYYY-MM-DD] - Entry content here.

    If no date is known, use [unknown] instead.

    ## Output:
    - Wrap the entire export in a single code block for easy copying.
    - After the code block, state whether this is the complete set or if more remain.
    """
}

struct MemoryExportPromptView: View {
    @Environment(AppModel.self) private var app
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HV.Space.l) {
                VStack(alignment: .leading, spacing: HV.Space.xs) {
                    Text("Bring memories from another AI")
                        .font(.hvTitle)
                    Text("Your old assistant already knows you. Make it hand that over: paste this prompt into ChatGPT, Gemini, Grok, or any AI with memory. It replies with everything it has stored about you in one code block. Paste that reply into Memorize, and repeat if it says more remain.")
                        .font(.hvCallout)
                        .foregroundStyle(Palette.textSecondary)
                }

                Button {
                    UIPasteboard.general.string = MemoryExportPrompt.text
                    Haptics.success()
                    copied = true
                    app.toasts.success("Prompt copied.")
                    Task {
                        try? await Task.sleep(nanoseconds: 1_800_000_000)
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy prompt", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.hvPrimary)

                Text(MemoryExportPrompt.text)
                    .font(.hvMono)
                    .foregroundStyle(Palette.textPrimary)
                    .textSelection(.enabled)
                    .padding(HV.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
            }
            .padding(HV.Space.m)
            .hvReadableWidth()
        }
        .hvScreenBackground()
        .navigationTitle("From another AI")
        .navigationBarTitleDisplayMode(.inline)
    }
}
