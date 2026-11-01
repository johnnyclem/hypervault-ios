import HyperVaultKit
import SwiftUI

/// The field at the foot of the canvas. A long paste waits above it as a chip, to be
/// kept or asked about; everything else is typed.
struct CanvasComposer: View {
    @Bindable var model: CanvasModel
    var onNewThread: () -> Void
    var onCopyStarter: () -> Void
    var isDictating = false
    var onDictate: (() -> Void)?
    var onScan: (() -> Void)?

    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: HV.Space.xs) {
            if let staged = model.staged {
                StagedChip(
                    characters: staged.count,
                    canAsk: model.canAsk,
                    isKeeping: model.isKeeping,
                    keep: model.keepStaged,
                    ask: {
                        model.askInstead()
                        focused = true
                    }
                )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let notice = model.notice {
                NoticeLine(notice: notice, dismiss: model.dismissNotice)
                    .transition(.opacity)
            }
            field
        }
        .padding(.horizontal, HV.Space.m)
        .padding(.top, HV.Space.xs)
        .padding(.bottom, HV.Space.xs)
        .hvReadableWidth()
        .hvAnimation(HV.Motion.sheet, value: model.staged != nil)
        .hvAnimation(HV.Motion.entrance, value: model.notice)
    }

    private var field: some View {
        HStack(alignment: .bottom, spacing: HV.Space.xs) {
            Menu {
                Button("New thread", systemImage: "square.and.pencil", action: onNewThread)
                Button(HVCopy.copyPromptLabel, systemImage: HVSymbol.copy, action: onCopyStarter)
                if let onScan { Button("Scan a page", systemImage: "doc.viewfinder", action: onScan) }
            } label: {
                Image(systemName: HVSymbol.add)
                    .font(.system(.body, weight: .semibold))
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("More")
            .accessibilityIdentifier("canvas.more")

            TextField(HVCopy.chatPlaceholder, text: $model.draft, prompt: Text.hvPrompt(HVCopy.chatPlaceholder), axis: .vertical)
                .font(.hvBody)
                .lineLimit(1...6)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit(sendFromKeyboard)
                .padding(.vertical, 9)
                .accessibilityIdentifier("canvas.field")
                .onChange(of: model.draft) { old, new in
                    // A field that grows with its text takes Return as a line break and never calls onSubmit.
                    if model.draftChanged(from: old, to: new) == .returned { sendFromKeyboard() }
                }

            trailing
        }
        .padding(.horizontal, HV.Space.xs)
        .padding(.vertical, HV.Space.xs)
        .hvGlass(radius: HV.Radius.floating)
    }

    /// Return, or the Send key: send what is in the field, or keep the paste waiting above it.
    private func sendFromKeyboard() {
        // Words still arriving from dictation would refill the field the moment it is sent.
        if isDictating { onDictate?() }
        Task { await model.submit() }
        focused = true
    }

    @ViewBuilder
    private var trailing: some View {
        if isDictating, let onDictate {
            // While listening the field fills with words; stopping must stay one tap away.
            micButton(onDictate)
        } else if model.canSend {
            Button {
                Task { await model.send() }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(.body, weight: .semibold))
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Palette.action, in: Circle())
            }
            .accessibilityLabel("Send")
            .accessibilityIdentifier("canvas.send")
            .transition(.opacity)
        } else if model.isBusy {
            ProgressView().frame(width: 44, height: 44)
        } else if let onDictate {
            micButton(onDictate)
        }
    }

    private func micButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: isDictating ? "waveform" : "mic")
                .font(.system(.body, weight: .semibold))
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .foregroundStyle(isDictating ? Color.accentColor : Palette.textSecondary)
                .symbolEffect(.variableColor.iterative, isActive: isDictating && !reduceMotion)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel(isDictating ? "Stop dictating" : "Dictate")
    }
}

/// "Pasted - 1,234 characters" with its two ways out.
private struct StagedChip: View {
    let characters: Int
    /// Asking needs a model; without one the paste can only be kept.
    let canAsk: Bool
    let isKeeping: Bool
    let keep: () -> Void
    let ask: () -> Void

    var body: some View {
        HStack(spacing: HV.Space.s) {
            Text(HVCopy.pastedLine(characters: characters))
                .font(.system(.subheadline, weight: .medium))
                .lineLimit(1)
                .accessibilityIdentifier("canvas.pasted")
            Spacer(minLength: 0)
            // The ghost style has no side padding, so the two ways out are set apart here and do not read as one phrase.
            HStack(spacing: HV.Space.m) {
                Button(isKeeping ? HVCopy.keepingLine : HVCopy.keepItLabel, action: keep)
                    .buttonStyle(.hvGhost)
                    .disabled(isKeeping)
                    .accessibilityIdentifier("canvas.keep")
                if canAsk {
                    Button(HVCopy.askInsteadLabel, action: ask)
                        .buttonStyle(.hvGhost)
                        .tint(Palette.textSecondary)
                        .accessibilityIdentifier("canvas.askInstead")
                }
            }
        }
        .padding(.horizontal, HV.Space.m)
        .padding(.vertical, 4)
        .hvGlass(radius: HV.Radius.floating)
        .accessibilityElement(children: .contain)
    }
}

private struct NoticeLine: View {
    let notice: KeepNotice
    let dismiss: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: HV.Space.xs) {
            HVIcon(notice.kind == .error ? "exclamationmark.circle" : "info.circle")
            Text(notice.text).font(.hvFootnote)
                .accessibilityIdentifier("canvas.notice")
            Spacer(minLength: 0)
            if notice.opensSettings, let settings = URL(string: UIApplication.openSettingsURLString) {
                Button("Settings") { openURL(settings) }
                    .font(.system(.footnote, weight: .semibold))
            }
            Button(action: dismiss) {
                Image(systemName: HVSymbol.close)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
                .font(.system(.caption, weight: .semibold))
                .accessibilityLabel("Dismiss")
        }
        .foregroundStyle(notice.kind == .error ? Palette.danger : Palette.textSecondary)
        .padding(.horizontal, HV.Space.m)
    }
}
