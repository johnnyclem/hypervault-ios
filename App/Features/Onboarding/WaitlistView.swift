import HyperVaultKit
import SwiftUI

/// Signed in, not yet let in. An invite code opens the door; so does being
/// approved while the app is open ("Check again").
struct WaitlistView: View {
    @Environment(AppModel.self) private var model
    let user: AuthUser

    @State private var code = ""
    @State private var isWorking = false
    @State private var message: String?
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            AuroraBackground(intensity: 0.8)
            ScrollView {
                VStack(spacing: HV.Space.l) {
                    Spacer(minLength: HV.Space.xl)
                    BrandMark(size: 72)
                    VStack(spacing: HV.Space.xs) {
                        Text(user.firstName.map { "You're on the list, \($0)." } ?? "You're on the list.")
                            .font(.hvHero)
                            .multilineTextAlignment(.center)
                        Text("HyperVault is letting people in a few at a time. Got an invite code? Enter it to come straight in.")
                            .font(.hvBody)
                            .foregroundStyle(Palette.textSecondary)
                            .multilineTextAlignment(.center)
                    }

                    VStack(spacing: HV.Space.s + 2) {
                        TextField("HV-XXXX-XXXX", text: $code)
                            .font(.system(.title3, design: .monospaced, weight: .semibold))
                            .multilineTextAlignment(.center)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .focused($focused)
                            .submitLabel(.go)
                            .onSubmit { redeem() }
                            .hvFieldChrome(isFocused: focused)

                        Button {
                            redeem()
                        } label: {
                            if isWorking { ProgressView().tint(.white) } else { Text("Use this code") }
                        }
                        .buttonStyle(.hvPrimary)
                        .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)

                        PasteButton(payloadType: String.self) { strings in
                            guard let text = strings.first else { return }
                            code = InviteCode.extract(from: text) ?? text
                        }
                        .labelStyle(.titleAndIcon)
                        .buttonBorderShape(.capsule)

                        if let message {
                            Text(message)
                                .font(.hvFootnote)
                                .foregroundStyle(Palette.danger)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: 420)

                    HStack(spacing: HV.Space.l) {
                        Button("Check again") {
                            Task {
                                isWorking = true
                                await model.recheckAccess()
                                isWorking = false
                            }
                        }
                        Button("Sign out") { Task { await model.signOut() } }
                    }
                    .buttonStyle(.hvGhost)
                    .padding(.top, HV.Space.s)
                }
                .padding(HV.Space.l)
                .hvReadableWidth()
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear {
            if code.isEmpty, let pending = model.pendingInviteCode { code = pending }
        }
    }

    private func redeem() {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !isWorking else { return }
        isWorking = true
        message = nil
        Task {
            defer { isWorking = false }
            do {
                let result = try await model.redeemInvite(trimmed)
                if result.isAccepted {
                    Haptics.success()
                } else {
                    message = result.message
                    Haptics.failure()
                }
            } catch {
                message = (error as? HVError)?.userMessage ?? error.localizedDescription
                Haptics.failure()
            }
        }
    }
}
