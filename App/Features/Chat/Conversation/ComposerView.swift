import HyperVaultKit
import SwiftUI

/// The message field in glass chrome. The send button exists only while there
/// is something to send; while a turn is in flight it is a stop button.
struct ChatComposerView: View {
    @Bindable var model: ChatConversationModel
    var focus: FocusState<Bool>.Binding
    var onOptions: () -> Void

    var body: some View {
        VStack(spacing: HV.Space.xs) {
            if let notice = model.notice {
                noticeLine(notice)
            }
            if let line = model.toolFreeLine {
                Label(line, systemImage: model.isOnDevice ? "iphone" : "desktopcomputer")
                    .font(.hvCaption)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, HV.Space.xs)
            }
            if model.backendsLoaded && !model.canChat {
                connectCard
            } else {
                field
            }
        }
        .padding(.horizontal, HV.Space.m)
        .padding(.top, HV.Space.xs)
        .padding(.bottom, HV.Space.xs)
        .hvReadableWidth()
        .hvAnimation(HV.Motion.entrance, value: model.notice)
        .hvAnimation(.spring(response: 0.3, dampingFraction: 0.8), value: model.canSend)
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Message", text: $model.draft, prompt: Text("Message").foregroundStyle(Palette.textSecondary), axis: .vertical)
                .font(.hvBody)
                .lineLimit(1...8)
                .focused(focus)
                .padding(.horizontal, HV.Space.m)
                .padding(.top, HV.Space.s)
                .padding(.bottom, HV.Space.xs)
                .accessibilityLabel("Message")
                .accessibilityHint("Sends to \(model.modelName)")

            HStack(spacing: HV.Space.xs) {
                Button(action: onOptions) {
                    HStack(spacing: 6) {
                        HVIcon(model.isOnDevice ? "iphone" : (model.runsLocally ? "desktopcomputer" : HVSymbol.model)).font(.hvFootnote.weight(.semibold))
                        Text(model.modelName).lineLimit(1)
                        HVIcon("chevron.up.chevron.down").font(.hvCaption.weight(.bold)).imageScale(.small)
                    }
                    .font(.hvFootnote.weight(.medium))
                    .foregroundStyle(Palette.textSecondary)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .padding(.horizontal, HV.Space.s)
                    .padding(.vertical, 6)
                    .background(Palette.surfaceRaised, in: Capsule())
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Model and options")
                .accessibilityValue(model.modelName)

                Spacer(minLength: 0)

                if showsCounter {
                    Text("\(model.draft.count.formatted()) / \(model.maxCharacters.formatted())")
                        .font(.hvCaption.monospacedDigit())
                        .foregroundStyle(model.draftTooLong ? Palette.danger : Palette.textTertiary)
                }

                if model.isWorking {
                    Button(action: model.stop) {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(.hvIcon)
                    .accessibilityLabel("Stop")
                    .transition(.scale.combined(with: .opacity))
                } else if model.canSend {
                    Button {
                        Haptics.tap()
                        model.sendDraft()
                    } label: {
                        Image(systemName: "arrow.up")
                    }
                    .buttonStyle(.hvIconProminent)
                    .accessibilityLabel("Send")
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.leading, HV.Space.s)
            .padding(.trailing, HV.Space.xs)
            .padding(.bottom, HV.Space.xxs)
        }
        .hvGlass(radius: HV.Radius.floating)
    }

    private var showsCounter: Bool {
        Double(model.draft.count) > Double(model.maxCharacters) * 0.8
    }

    private func noticeLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: HV.Space.xs) {
            Text(text)
                .font(.hvFootnote)
                .foregroundStyle(Palette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                model.dismissNotice()
            } label: {
                Image(systemName: HVSymbol.close).font(.hvCaption.weight(.bold)).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.textSecondary)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, HV.Space.s)
        .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous))
    }

    /// Nothing is connected and the phone cannot answer either.
    private var connectCard: some View {
        VStack(alignment: .leading, spacing: HV.Space.s) {
            Text(HVCopy.noModelLine)
                .font(.hvCallout)
                .foregroundStyle(Palette.textSecondary)
            if !model.onDeviceStatus.isAvailable, model.backends.isEmpty {
                Text(model.onDeviceStatus.explanation)
                    .font(.hvCaption)
                    .foregroundStyle(Palette.textTertiary)
            }
            NavigationLink(value: ChatDestination.models) {
                Text(HVCopy.connectAILabel)
            }
            .buttonStyle(.hvPrimary)
        }
        .padding(HV.Space.m)
        .hvGlass(radius: HV.Radius.floating)
    }
}
