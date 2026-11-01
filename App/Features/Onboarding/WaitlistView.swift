import HyperVaultKit
import SwiftUI

/// Signed in, not yet let in. An invite code opens the door; so does being
/// approved while the app is open ("Check again").
struct WaitlistView: View {
    @Environment(AppModel.self) private var model
    let user: AuthUser

    @State private var code = ""
    @State private var isWorking = false
    @State private var isChecking = false
    @State private var message: String?
    @State private var status: String?
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            AuroraBackground(intensity: 0.8)
            ScrollView {
                VStack(spacing: HV.Space.l) {
                    Spacer(minLength: HV.Space.xl)
                    BrandMark(size: 72)
                    VStack(spacing: HV.Space.xs) {
                        Text("You're on the list")
                            .font(.hvHero)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("waitlist.title")
                        Text("HyperVault is letting people in a few at a time. Got an invite code? Enter it to come straight in.")
                            .font(.hvBody)
                            .foregroundStyle(Palette.textSecondary)
                            .multilineTextAlignment(.center)
                    }

                    VStack(spacing: HV.Space.s) {
                        TextField("Invite code", text: $code, prompt: .hvPrompt("HV-XXXX-XXXX"))
                            .font(.system(.title3, design: .monospaced, weight: .semibold))
                            .multilineTextAlignment(.center)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .focused($focused)
                            .submitLabel(.go)
                            .onSubmit { redeem() }
                            .accessibilityHint(message ?? "")
                            .accessibilityIdentifier("waitlist.code")
                            .hvFieldChrome(isFocused: focused)

                        Button {
                            redeem()
                        } label: {
                            if isWorking { ProgressView().tint(.white) } else { Text("Use this code") }
                        }
                        .buttonStyle(.hvPrimary)
                        .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || isWorking || isChecking)
                        .accessibilityIdentifier("waitlist.redeem")

                        HVPasteButton { strings in
                            guard let text = strings.first else { return }
                            code = InviteCode.extract(from: text) ?? text
                        }

                        if let message {
                            Text(message)
                                .font(.hvFootnote)
                                .foregroundStyle(Palette.danger)
                                .multilineTextAlignment(.center)
                                .accessibilityIdentifier("waitlist.message")
                        }
                    }
                    .frame(maxWidth: 420)

                    VStack(spacing: HV.Space.s) {
                        HStack(spacing: HV.Space.l) {
                            Button {
                                checkAgain()
                            } label: {
                                // The words stay so the buttons do not shift while the spinner shows.
                                Text("Check again")
                                    .opacity(isChecking ? 0 : 1)
                                    .overlay { if isChecking { ProgressView() } }
                            }
                            .disabled(isChecking || isWorking)
                            .accessibilityLabel(isChecking ? "Checking" : "Check again")
                            .accessibilityIdentifier("waitlist.check")
                            Button("Sign out") { Task { await model.signOut() } }
                                .accessibilityIdentifier("waitlist.signout")
                        }
                        .buttonStyle(.hvGhost)

                        if let status {
                            Text(status)
                                .font(.hvFootnote)
                                .foregroundStyle(Palette.textSecondary)
                                .multilineTextAlignment(.center)
                                .accessibilityIdentifier("waitlist.status")
                        }
                    }
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

    /// Asks again whether the person has been let in. If they have, the window moves on and this view goes with it; if
    /// this view is still here afterwards, they are still on the list, and that is said calmly.
    private func checkAgain() {
        guard !isChecking, !isWorking else { return }
        isChecking = true
        message = nil
        status = nil
        Task {
            await model.recheckAccess()
            isChecking = false
            let text = "Still waiting. We'll let you in as soon as you're approved."
            status = text
            AccessibilityNotification.Announcement(text).post()
        }
    }

    private func redeem() {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !isWorking, !isChecking else { return }
        isWorking = true
        message = nil
        status = nil
        Task {
            defer { isWorking = false }
            do {
                let result = try await model.redeemInvite(trimmed)
                if result.isAccepted {
                    Haptics.success()
                } else {
                    reject(result.message)
                }
            } catch {
                reject((error as? HVError)?.userMessage ?? error.localizedDescription)
            }
        }
    }

    /// Shows why the code did not work and says it: the line appears without moving focus, and a view that appears
    /// is not announced.
    private func reject(_ text: String) {
        message = text
        Haptics.failure()
        AccessibilityNotification.Announcement(text).post()
    }
}
