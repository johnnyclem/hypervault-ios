import HyperVaultKit
import SwiftUI

extension Notification.Name {
    /// A key was made or taken away somewhere else in the app (a pairing was approved); lists reload.
    static let hvKeysChanged = Notification.Name("store.hypervault.keysChanged")
}

/// An AI tool asked for a key and showed its person a code: this is where they answer. The root presents it
/// as a sheet when a pair link opens; the same screen sits inside Account & keys for typing a code by hand.
/// Pairing is a server switch (HYPERVAULT_PAIRING=1): off, the screen says it is not available here.
struct PairApprovalView: View {
    let code: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PairApprovalScreen(code: code)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                }
        }
        .presentationDetents([.large])
    }
}

// MARK: Model

@MainActor
@Observable
final class PairApprovalModel {
    enum Phase: Equatable {
        /// Asking for the code the AI tool is showing.
        case entering
        /// A code is known; the person decides.
        case asking
        case working
        case approved(label: String?)
        case denied
        /// The server has pairing off.
        case unavailable
    }

    private(set) var phase: Phase
    var codeText: String
    private(set) var message: String?
    private(set) var code: String?

    private let client: HVClient
    private let origin: String

    init(client: HVClient, origin: String, code: String?) {
        self.client = client
        self.origin = origin
        self.codeText = code ?? ""
        if let code, !code.isEmpty {
            if let formatted = PairingCode.extract(from: code) {
                self.code = formatted
                self.codeText = formatted
                self.phase = .asking
            } else {
                self.phase = .entering
                self.message = PairingCopy.badCodeLine
            }
        } else {
            self.phase = .entering
        }
    }

    var canContinue: Bool { PairingCode.extract(from: codeText) != nil }

    /// Asks the server whether pairing exists at all, so a link that cannot work says so at once.
    func checkAvailable() async {
        if await PairingAvailability.probe(client: client) == false { phase = .unavailable }
    }

    func submitCode() {
        guard let formatted = PairingCode.extract(from: codeText) else {
            message = PairingCopy.badCodeLine
            return
        }
        code = formatted
        codeText = formatted
        message = nil
        phase = .asking
    }

    func paste(_ text: String) {
        codeText = PairingCode.extract(from: text) ?? text
        message = nil
    }

    func approve() async { await answer(approving: true) }
    func deny() async { await answer(approving: false) }

    private func answer(approving: Bool) async {
        guard let code, phase == .asking else { return }
        phase = .working
        message = nil
        do {
            if approving {
                let result = try await client.send(.pairApprove(userCode: code, origin: origin))
                phase = .approved(label: result.label)
                NotificationCenter.default.post(name: .hvKeysChanged, object: nil)
            } else {
                _ = try await client.send(.pairDeny(userCode: code, origin: origin))
                phase = .denied
            }
            Haptics.success()
        } catch {
            Haptics.failure()
            switch PairingFailure.classify(error) {
            case .unavailable:
                phase = .unavailable
            case .refused(let sentence):
                message = sentence
                // A code that is wrong, run out, answered or tried too often cannot be helped by trying it again.
                let status = (error as? HVError)?.status
                phase = [400, 404, 409, 410, 429].contains(status ?? 0) ? .entering : .asking
            }
        }
    }
}

// MARK: Screen

struct PairApprovalScreen: View {
    let code: String?

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var model: PairApprovalModel?
    @FocusState private var codeFocused: Bool

    var body: some View {
        Group {
            if let model {
                ScrollView {
                    content(model)
                        .padding(HV.Space.l)
                        .hvReadableWidth()
                }
                .scrollDismissesKeyboard(.interactively)
            } else {
                HVLoadingState().frame(maxHeight: .infinity)
            }
        }
        .hvScreenBackground()
        .navigationTitle(PairingCopy.pageTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model == nil {
                model = PairApprovalModel(client: env.client, origin: PairingCode.origin(of: env.server.baseURL), code: code)
            }
            await model?.checkAvailable()
        }
    }

    @ViewBuilder
    private func content(_ model: PairApprovalModel) -> some View {
        switch model.phase {
        case .entering: entering(model)
        case .asking, .working: asking(model)
        case .approved(let label): finished(symbol: "checkmark.circle.fill", tint: Palette.success, line: PairingCopy.approvedLine, label: label)
        case .denied: finished(symbol: "hand.raised.fill", tint: Palette.textSecondary, line: PairingCopy.deniedLine, label: nil)
        case .unavailable:
            HVEmptyState(symbol: "link.badge.plus", title: "Not available here", message: PairingCopy.unavailableLine, actionTitle: "Done") { dismiss() }
        }
    }

    // MARK: Entering a code

    private func entering(_ model: PairApprovalModel) -> some View {
        @Bindable var model = model
        return VStack(spacing: HV.Space.l) {
            icon("link")
            Text(PairingCopy.enterLine)
                .font(.hvTitle3)
                .multilineTextAlignment(.center)
            VStack(spacing: HV.Space.s + 2) {
                TextField("XXXX-XXXX", text: $model.codeText)
                    .font(.system(.title2, design: .monospaced, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .focused($codeFocused)
                    .submitLabel(.continue)
                    .onSubmit { model.submitCode() }
                    .accessibilityLabel(PairingCopy.codeFieldLabel)
                    .hvFieldChrome(isFocused: codeFocused)
                Button(PairingCopy.continueLabel) { model.submitCode() }
                    .buttonStyle(.hvPrimary)
                    .disabled(!model.canContinue)
                PasteButton(payloadType: String.self) { strings in
                    if let text = strings.first { model.paste(text) }
                }
                .labelStyle(.titleAndIcon)
                .buttonBorderShape(.capsule)
                if let message = model.message { KeysInlineMessage(text: message).multilineTextAlignment(.center) }
            }
            .frame(maxWidth: 420)
        }
        .onAppear { codeFocused = model.codeText.isEmpty }
    }

    // MARK: Deciding

    private func asking(_ model: PairApprovalModel) -> some View {
        let working = model.phase == .working
        return VStack(spacing: HV.Space.l) {
            icon("link")
            Text(PairingCopy.anAgentAsks)
                .font(.hvTitle)
                .multilineTextAlignment(.center)

            VStack(spacing: HV.Space.xs) {
                Text(PairingCopy.codeHeading)
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .textCase(.uppercase)
                    .tracking(1)
                Text(model.code ?? "")
                    .font(.system(.largeTitle, design: .monospaced, weight: .bold))
                    .tracking(3)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .accessibilityLabel("Code \((model.code ?? "").map(String.init).joined(separator: " "))")
                Text(PairingCopy.codeMatchLine)
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .hvCard()

            KeysNotice(text: PairingCopy.warning)

            VStack(spacing: HV.Space.xs) {
                Text(PairingCopy.approveNote).font(.hvFootnote).foregroundStyle(Palette.textSecondary)
                Text(PairingCopy.whereItGoes).font(.hvFootnote).foregroundStyle(Palette.textTertiary)
            }
            .multilineTextAlignment(.center)

            if let message = model.message { KeysInlineMessage(text: message).multilineTextAlignment(.center) }

            VStack(spacing: HV.Space.s) {
                Button {
                    Task { await model.approve() }
                } label: {
                    if working { ProgressView().tint(.white) } else { Text(PairingCopy.approveLabel) }
                }
                .buttonStyle(.hvPrimary)
                .disabled(working)

                Button(PairingCopy.denyLabel) { Task { await model.deny() } }
                    .buttonStyle(.hvSecondary)
                    .disabled(working)
            }
        }
    }

    // MARK: Done

    private func finished(symbol: String, tint: Color, line: String, label: String?) -> some View {
        VStack(spacing: HV.Space.l) {
            Image(systemName: symbol)
                .font(.system(size: 56))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(line).font(.hvTitle3).multilineTextAlignment(.center)
            if let label {
                Text("Its key is named “Paired: \(label)”. You can revoke it any time under Account & keys.")
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
            Button("Done") { dismiss() }.buttonStyle(.hvSecondary)
        }
        .padding(.top, HV.Space.xl)
        .accessibilityElement(children: .contain)
    }

    private func icon(_ symbol: String) -> some View {
        ZStack {
            Circle().fill(Palette.violet.opacity(0.14)).frame(width: 72, height: 72)
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Palette.violet)
        }
        .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("Approve, a code in the link") {
    PreviewHost(routes: [.failure(.post, "/api/pair/poll", status: 400, message: "device_code is required")], embedInNavigation: false) {
        PairApprovalView(code: "BCDF-2346")
    }
}

#Preview("Approve, no code") {
    PreviewHost(routes: [.failure(.post, "/api/pair/poll", status: 400, message: "device_code is required")], embedInNavigation: false) {
        PairApprovalView(code: nil)
    }
}

#Preview("Approve, not available") {
    PreviewHost(routes: [.failure(.post, "/api/pair/poll", status: 404, message: "Not found.")], embedInNavigation: false) {
        PairApprovalView(code: "BCDF-2346")
    }
}
#endif
