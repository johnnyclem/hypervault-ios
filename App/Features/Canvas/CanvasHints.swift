import HyperVaultKit
import SwiftUI

/// What the canvas says before anyone has said anything: the mark, the one line, and three
/// quiet things to do. It goes away the moment anything is on the page.
struct CanvasHints: View {
    let model: CanvasModel
    let userName: String?
    var onCopyStarter: () -> Void
    var starterCopied: Bool

    @Environment(AppModel.self) private var app
    @State private var canPaste = UIPasteboard.general.hasStrings

    var body: some View {
        VStack(spacing: HV.Space.l) {
            BrandMark(size: 68)
            VStack(spacing: HV.Space.xs) {
                if let userName {
                    Text(greeting(for: userName))
                        .font(.system(.subheadline, design: .rounded, weight: .medium))
                        .foregroundStyle(Palette.textSecondary)
                }
                Text(HVCopy.landingLine)
                    .font(.hvTitle)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: HV.Space.s + 2) {
                Text(HVCopy.hintKeepLine)
                    .font(.hvCallout)
                    .foregroundStyle(Palette.textSecondary)

                // The system's paste control looks switched off when there is nothing on the pasteboard, which
                // is how a first run finds it; it appears when there is something to paste.
                if canPaste {
                    PasteButton(payloadType: String.self) { strings in
                        let text = strings.joined(separator: "\n\n")
                        guard !text.isEmpty else { return }
                        model.stagePaste(text)
                    }
                    .labelStyle(.titleAndIcon)
                    .buttonBorderShape(.capsule)
                    .tint(Palette.blue)
                }

                starterButton
            }

            VStack(spacing: HV.Space.s) {
                FlowLayout(spacing: HV.Space.xs) {
                    Text(HVCopy.hintTryLabel).font(.hvFootnote).foregroundStyle(Palette.textSecondary)
                    ForEach(HVCopy.hintExamples, id: \.self) { example in
                        Button {
                            model.setDraft(example)
                            Task { await model.send() }
                        } label: {
                            HVChip(title: example)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity)

                if model.backendsLoaded {
                    if model.hasModel {
                        Text(HVCopy.hintAskLine).font(.hvFootnote).foregroundStyle(Palette.textSecondary)
                    } else {
                        Text(HVCopy.hintConnectLine).font(.hvFootnote).foregroundStyle(Palette.textSecondary)
                        Button(HVCopy.connectAILabel) { app.router.sheet = .connectAgent }
                            .buttonStyle(.hvGhost)
                    }
                }
            }
        }
        .padding(.horizontal, HV.Space.xl)
        .frame(maxWidth: 440)
        .frame(maxWidth: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            canPaste = UIPasteboard.general.hasStrings
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            canPaste = UIPasteboard.general.hasStrings
        }
    }

    private var starterButton: some View {
        VStack(spacing: 4) {
            Button(action: onCopyStarter) {
                Label(starterCopied ? "Copied" : HVCopy.copyPromptLabel, systemImage: starterCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
            }
            .buttonStyle(.hvGhost)
            if starterCopied {
                Text(HVCopy.copyPromptNextLine)
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.textSecondary)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: starterCopied)
    }

    private func greeting(for name: String) -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 5 ? "Hello" : hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        return "\(part), \(name)."
    }
}
