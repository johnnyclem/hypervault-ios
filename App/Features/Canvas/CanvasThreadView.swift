import HyperVaultKit
import SwiftUI

/// The conversation under the cards. The page's own lines (help, "Which one?") are quiet and
/// are never kept; a model's replies can be kept with one tap.
struct CanvasThreadView: View {
    let model: CanvasModel

    var body: some View {
        VStack(alignment: .leading, spacing: HV.Space.s) {
            ForEach(Array(model.messages.enumerated()), id: \.element.id) { index, message in
                MessageRow(message: message, canKeep: !model.isKeeping) {
                    model.keepReply(at: index)
                } choose: { item in
                    model.choose(item, answering: message.id)
                }
            }
            if model.isBusy {
                ThinkingRow()
            }
            if model.needsModel {
                NoModelRow()
            }
            if let error = model.chatError {
                Text(error)
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct MessageRow: View {
    let message: ThreadMessage
    let canKeep: Bool
    let keep: () -> Void
    let choose: (KeptItem) -> Void

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: HV.Space.hair) {
            bubble
            if message.role == .assistant, !message.isLocal {
                footer
            }
            if let choices = message.choices {
                choiceList(choices)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    private var bubble: some View {
        Text(ThreadMessage.rendered(message.content))
            .font(.hvBody)
            .foregroundStyle(message.role == .user ? Color.white : (message.isLocal ? Palette.textSecondary : Palette.textPrimary))
            .textSelection(.enabled)
            .padding(.horizontal, HV.Space.m)
            .padding(.vertical, HV.Space.s)
            .background(background)
            .frame(maxWidth: 520, alignment: message.role == .user ? .trailing : .leading)
            .accessibilityLabel(message.spokenLine)
    }

    @ViewBuilder
    private var background: some View {
        if message.role == .user {
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Palette.softGradient)
        } else if message.isLocal {
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Palette.surfaceRaised)
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
        } else {
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Palette.surface)
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !message.using.isEmpty {
                Text(HVCopy.usingLine(message.using.joined(separator: ", ")))
                    .font(.hvCaption)
                    .foregroundStyle(Palette.textTertiary)
            }
            if message.truncated {
                Text(HVCopy.replyCutShortLine)
                    .font(.hvCaption)
                    .foregroundStyle(Palette.warning)
            }
            Button(action: keep) {
                Label(HVCopy.keepReplyLabel, systemImage: "tray.and.arrow.down")
                    .font(.system(.footnote, weight: .semibold))
            }
            .buttonStyle(.hvGhost)
            .disabled(!canKeep)
            .accessibilityLabel("Keep this reply")
        }
        .padding(.leading, HV.Space.xs)
    }

    private func choiceList(_ choices: ThreadChoices) -> some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            ForEach(choices.items) { item in
                Button {
                    choose(item)
                } label: {
                    HStack(spacing: HV.Space.s) {
                        HVIconBadge(symbol: item.kind.symbol, tint: item.kind.tint, size: 28)
                        Text(item.name).font(.hvCallout).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(HV.Space.s)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            if choices.more {
                Text(HVCopy.pullMoreLine).font(.hvCaption).foregroundStyle(Palette.textTertiary)
            }
        }
        .frame(maxWidth: 420)
    }
}

private struct ThinkingRow: View {
    @State private var phase = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: HV.Space.hair) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Palette.textTertiary)
                    .frame(width: HV.Space.xs, height: HV.Space.xs)
                    .scaleEffect(phase ? 1 : 0.55)
                    // A reply can take minutes; with Reduce Motion on the dots hold still at full size.
                    .animation(reduceMotion ? nil : Animation.easeInOut(duration: 0.6).repeatForever().delay(Double(index) * 0.15), value: phase)
            }
            Text(HVCopy.thinkingLine)
                .font(.hvFootnote)
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(.horizontal, HV.Space.m)
        .padding(.vertical, HV.Space.s)
        .onAppear { phase = true }
        .accessibilityLabel(HVCopy.thinkingLine)
    }
}

private struct NoModelRow: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: HV.Space.s) {
            Text(HVCopy.noModelLine).font(.hvCallout).foregroundStyle(Palette.textSecondary)
            Button(HVCopy.connectAILabel) {
                app.router.sheet = .connectAgent
            }
            .buttonStyle(.hvSecondary)
            .frame(maxWidth: 260)
        }
        .padding(HV.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceRaised.opacity(0.7), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
