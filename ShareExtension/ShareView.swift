import HyperVaultKit
import SwiftUI

/// "Keep in HyperVault" from any app's share sheet. It keeps with the same session as the app
/// (the shared Keychain), and when it cannot reach the server it saves the thing to be kept
/// the next time the app can.
struct ShareView: View {
    let context: NSExtensionContext?
    @State private var model = ShareModel()
    @State private var celebrated = false

    var body: some View {
        VStack(spacing: 0) {
            bar
            Divider().overlay(Palette.hairline)
            content
                .padding(HV.Space.l)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Palette.background.ignoresSafeArea())
        .task { await model.load(from: context) }
    }

    // MARK: Bar

    private var bar: some View {
        HStack {
            Button("Cancel") { cancel() }
                .buttonStyle(.hvGhost)
            Spacer()
            HStack(spacing: 6) {
                BrandMark(size: 22)
                Text("HyperVault").font(.system(.headline, design: .rounded, weight: .semibold))
            }
            Spacer()
            if case .ready = model.phase {
                Button("Keep") { Task { await model.keep() } }
                    .buttonStyle(.hvGhost)
                    .font(.system(.body, design: .rounded, weight: .bold))
                    .disabled(model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                Color.clear.frame(width: 56, height: 1)
            }
        }
        .padding(.horizontal, HV.Space.s)
        .frame(height: 52)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView().padding(.top, HV.Space.xxl)
        case .empty:
            message(symbol: "tray", title: "Nothing to keep", detail: "Share some text or a link and it will land here.")
        case .ready:
            editor
        case .keeping:
            VStack(spacing: HV.Space.m) {
                ProgressView()
                Text(HVCopy.keepingLine).font(.hvCallout).foregroundStyle(Palette.textSecondary)
            }
            .padding(.top, HV.Space.xxl)
        case .kept(let kept, let link):
            keptView(kept, link: link)
        case .queued(let signedOut):
            message(
                symbol: "clock.badge.checkmark",
                title: "Saved for later",
                detail: signedOut
                    ? "Open HyperVault and sign in. This will be kept as soon as you do."
                    : "No connection right now. HyperVault will keep this the next time it can.",
                done: true
            )
        case .failed(let text):
            VStack(spacing: HV.Space.m) {
                message(symbol: "exclamationmark.triangle", title: "That could not be kept", detail: text)
                Button("Try again") { Task { await model.keep() } }.buttonStyle(.hvPrimary)
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: HV.Space.s) {
            Text("What to keep")
                .font(.system(.footnote, design: .rounded, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
            TextEditor(text: $model.text)
                .font(.hvBody)
                .scrollContentBackground(.hidden)
                .padding(HV.Space.s)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
                .frame(maxHeight: 260)
        }
    }

    private func keptView(_ kept: KeptThing, link: String) -> some View {
        VStack(spacing: HV.Space.m) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 52))
                .foregroundStyle(Palette.success)
                .symbolEffect(.bounce, value: celebrated)
                .onAppear { celebrated = true }
            Text(kept.duplicate ? HVCopy.alreadyKeptLine : HVCopy.keptLine)
                .font(.hvTitle3)
            if kept.isPrivate {
                Text(HVCopy.onlyYouLine).font(.hvCallout).foregroundStyle(Palette.textSecondary)
            }
            Text(link)
                .font(.hvMono)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: HV.Space.s) {
                Button("Copy link") {
                    UIPasteboard.general.string = link
                    Haptics.tap()
                }
                .buttonStyle(.hvSecondary)
                Button("Done") { finish() }
                    .buttonStyle(.hvPrimary)
            }
        }
        .padding(.top, HV.Space.xl)
    }

    private func message(symbol: String, title: String, detail: String, done: Bool = false) -> some View {
        VStack(spacing: HV.Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 40))
                .foregroundStyle(Palette.textSecondary)
            Text(title).font(.hvTitle3)
            Text(detail)
                .font(.hvCallout)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
            if done {
                Button("Done") { finish() }.buttonStyle(.hvPrimary)
            }
        }
        .padding(.top, HV.Space.xl)
    }

    // MARK: Closing

    private func finish() {
        context?.completeRequest(returningItems: nil)
    }

    private func cancel() {
        context?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: CocoaError.userCancelled.rawValue))
    }
}
