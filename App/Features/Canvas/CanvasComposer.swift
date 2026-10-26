import HyperVaultKit
import SwiftUI

/// The field at the foot of the canvas. A long paste waits above it as a chip, to be
/// kept or asked about; everything else is typed.
struct CanvasComposer: View {
    @Bindable var model: CanvasModel
    var onNewThread: () -> Void
    var onCopyStarter: () -> Void
    var onDictate: (() -> Void)?
    var onScan: (() -> Void)?

    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: HV.Space.xs + 2) {
            if let staged = model.staged {
                StagedChip(characters: staged.count, isKeeping: model.isKeeping, keep: model.keepStaged, ask: model.askInstead)
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
        .animation(.snappy, value: model.staged != nil)
        .animation(.snappy, value: model.notice)
    }

    private var field: some View {
        HStack(alignment: .bottom, spacing: HV.Space.xs) {
            Menu {
                Button("New thread", systemImage: "square.and.pencil", action: onNewThread)
                Button(HVCopy.copyPromptLabel, systemImage: "doc.on.doc", action: onCopyStarter)
                if let onScan { Button("Scan a page", systemImage: "doc.viewfinder", action: onScan) }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: 38, height: 38)
            }
            .accessibilityLabel("More")

            TextField(HVCopy.chatPlaceholder, text: $model.draft, axis: .vertical)
                .font(.hvBody)
                .lineLimit(1...6)
                .focused($focused)
                .submitLabel(.send)
                .padding(.vertical, 9)
                .onChange(of: model.draft) { old, new in
                    // A text field gives no paste event, but a paste is the one edit that adds a whole page at once.
                    if let inserted = PasteDiff.insertion(old: old, new: new), PasteStaging.shouldStage(inserted) {
                        model.draft = old
                        model.stagePaste(inserted)
                    }
                }

            trailing
        }
        .padding(.horizontal, HV.Space.xs)
        .padding(.vertical, HV.Space.xs)
        .hvGlass(radius: 26)
    }

    @ViewBuilder
    private var trailing: some View {
        if model.canSend {
            Button {
                Task { await model.send() }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Palette.softGradient, in: Circle())
            }
            .accessibilityLabel("Send")
            .transition(.scale.combined(with: .opacity))
        } else if model.isBusy {
            ProgressView().frame(width: 38, height: 38)
        } else if let onDictate {
            Button(action: onDictate) {
                Image(systemName: "mic")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: 38, height: 38)
            }
            .accessibilityLabel("Dictate")
        }
    }
}

/// "Pasted - 1,234 characters" with its two ways out.
private struct StagedChip: View {
    let characters: Int
    let isKeeping: Bool
    let keep: () -> Void
    let ask: () -> Void

    var body: some View {
        HStack(spacing: HV.Space.s) {
            Image(systemName: "doc.on.clipboard")
                .foregroundStyle(Palette.textSecondary)
            Text(HVCopy.pastedLine(characters: characters))
                .font(.system(.subheadline, design: .rounded, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 0)
            Button(isKeeping ? HVCopy.keepingLine : HVCopy.keepItLabel, action: keep)
                .buttonStyle(.hvGhost)
                .disabled(isKeeping)
            Button(HVCopy.askInsteadLabel, action: ask)
                .buttonStyle(.hvGhost)
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(.horizontal, HV.Space.m)
        .padding(.vertical, 4)
        .hvGlass(radius: 18)
        .accessibilityElement(children: .contain)
    }
}

private struct NoticeLine: View {
    let notice: KeepNotice
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: HV.Space.xs) {
            Image(systemName: notice.kind == .error ? "exclamationmark.circle" : "info.circle")
            Text(notice.text).font(.hvFootnote)
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .font(.system(size: 11, weight: .bold))
                .accessibilityLabel("Dismiss")
        }
        .foregroundStyle(notice.kind == .error ? Palette.danger : Palette.textSecondary)
        .padding(.horizontal, HV.Space.m)
    }
}
