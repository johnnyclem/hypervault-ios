import HyperVaultKit
import PhotosUI
import SwiftUI
import UIKit

/// The message field in glass chrome. The send button exists only while there
/// is something to send; while a turn is in flight it is a stop button.
struct ChatComposerView: View {
    let model: ChatConversationModel
    var focus: FocusState<Bool>.Binding
    var onOptions: () -> Void

    @State private var pickedPhotos: [PhotosPickerItem] = []

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
    }

    /// The text field's binding. A write from a field that has since been replaced is dropped (`fieldWrote`).
    private var draftBinding: Binding<String> {
        let epoch = model.composerEpoch
        return Binding(get: { model.draft }, set: { model.fieldWrote($0, epoch: epoch) })
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.pendingImages.isEmpty {
                pendingStrip
            }
            TextField(
                "Message", text: draftBinding,
                prompt: Text(model.pendingImages.isEmpty ? "Message" : "Ask about the photo").foregroundStyle(Palette.textSecondary),
                axis: .vertical
            )
                .font(.hvBody)
                .lineLimit(1...8)
                .focused(focus)
                .hvFieldReset(epoch: model.composerEpoch, focus: focus, field: true)
                .padding(.horizontal, HV.Space.m)
                .padding(.top, HV.Space.s)
                .padding(.bottom, HV.Space.xs)
                .accessibilityLabel("Message")
                .accessibilityIdentifier("chat.field")
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

                if model.canAttach {
                    PhotosPicker(selection: $pickedPhotos, maxSelectionCount: model.attachSlots, matching: .images) {
                        Image(systemName: "photo.on.rectangle")
                    }
                    .buttonStyle(.hvIcon)
                    .accessibilityLabel("Add photos")
                    .accessibilityHint("Up to \(ChatImageUpload.maxPerMessage) per message")
                }

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
                    .transition(.opacity)
                } else if model.canSend {
                    Button {
                        Haptics.tap()
                        model.sendDraft()
                    } label: {
                        Image(systemName: "arrow.up")
                    }
                    .buttonStyle(.hvIconProminent)
                    .accessibilityLabel("Send")
                    .transition(.opacity)
                }
            }
            .padding(.leading, HV.Space.s)
            .padding(.trailing, HV.Space.xs)
            .padding(.bottom, HV.Space.xxs)
            // Only the buttons move with `canSend`. The text field is not in this subtree, so an animated change of
            // Send never shares a transaction with the field's text.
            .hvAnimation(HV.Motion.entrance, value: model.canSend)
        }
        .hvGlass(radius: HV.Radius.floating)
        .onChange(of: pickedPhotos) { _, items in
            guard !items.isEmpty else { return }
            pickedPhotos = []
            Task {
                for item in items {
                    await model.attach(try? await item.loadTransferable(type: Data.self))
                }
            }
        }
    }

    /// The photos chosen for this message, each with a way to take it off.
    private var pendingStrip: some View {
        HStack(spacing: HV.Space.xs) {
            ForEach(model.pendingImages) { pending in
                ZStack(alignment: .topTrailing) {
                    if let image = UIImage(data: pending.thumbnail) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: HV.Radius.control, style: .continuous))
                            .accessibilityLabel("Photo to send")
                    }
                    Button {
                        model.removeImage(pending.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.65))
                            .font(.hvBody)
                            .frame(width: 44, height: 44, alignment: .topTrailing)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .offset(x: 14, y: -14)
                    .accessibilityLabel("Remove photo")
                }
                .frame(width: 64, height: 64)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, HV.Space.m)
        .padding(.top, HV.Space.s)
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
        .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: HV.Radius.card, style: .continuous))
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
