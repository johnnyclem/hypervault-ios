import AuthenticationServices
import HyperVaultKit
import SwiftUI

/// The way in. Offers whatever the server's sign-in settings allow.
struct SignInScreen: View {
    @Environment(AppModel.self) private var model
    var onBack: (() -> Void)?

    var body: some View {
        if let auth = model.auth {
            SignInContent(auth: auth, oauthOrigin: model.oauthReturnOrigin, providers: model.providers, onBack: onBack)
        } else {
            LaunchView()
        }
    }
}

struct SignInContent: View {
    let providers: AuthProviders
    var onBack: (() -> Void)?

    @State private var controller: SignInController
    @State private var nonce = AuthNonce.make()
    @State private var showEmail = false

    init(auth: AuthService, oauthOrigin: URL, providers: AuthProviders, onBack: (() -> Void)?) {
        _controller = State(initialValue: SignInController(auth: auth, oauthOrigin: oauthOrigin))
        self.providers = providers
        self.onBack = onBack
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if let onBack {
                    Button(action: onBack) {
                        Image(systemName: HVSymbol.back)
                            .font(.system(.body, weight: .semibold))
                            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Back")
                    .accessibilityIdentifier("signin.back")
                }
                Spacer()
            }
            .padding(.horizontal, HV.Space.xs)
            .frame(height: 44)

            // The way in scrolls when its words need more room than the screen has (a large text size, a small phone):
            // without it the words and the buttons were cut short ("Welcome...", "Continue with e..."). When they fit,
            // it is the same page as before, the mark and the words in the middle and the buttons at the foot.
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        Spacer(minLength: HV.Space.l)

                        VStack(spacing: HV.Space.l) {
                            BrandMark(size: 84)
                            VStack(spacing: HV.Space.xs) {
                                Text("Welcome to HyperVault")
                                    .font(.hvHero)
                                    .multilineTextAlignment(.center)
                                Text("Keep what your AI just made. Only you can open it.")
                                    .font(.hvBody)
                                    .foregroundStyle(Palette.textSecondary)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .padding(.horizontal, HV.Space.xl)

                        Spacer(minLength: HV.Space.l)

                        VStack(spacing: HV.Space.s) {
                            if providers.apple { appleButton }
                            if providers.google { googleButton }
                            if providers.email { emailButton }
                            if !providers.apple && !providers.google && !providers.email {
                                Text("Sign-in is not available on this server right now.")
                                    .font(.hvCallout)
                                    .foregroundStyle(Palette.textSecondary)
                                    .accessibilityIdentifier("signin.unavailable")
                            }

                            if let message = controller.message {
                                Text(message)
                                    .font(.hvFootnote)
                                    .foregroundStyle(Palette.danger)
                                    .multilineTextAlignment(.center)
                                    .padding(.top, HV.Space.xs)
                                    .transition(.opacity)
                            }
                        }
                        .padding(.horizontal, HV.Space.l)
                        .padding(.bottom, HV.Space.l)
                        .hvReadableWidth()
                        .hvAnimation(HV.Motion.entrance, value: controller.message)
                    }
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .sheet(isPresented: $showEmail) {
            EmailCodeSheet(controller: controller)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var appleButton: some View {
        SignInWithAppleButton(.continue) { request in
            request.requestedScopes = [.fullName, .email]
            request.nonce = nonce.hashed
        } onCompletion: { result in
            let raw = nonce.raw
            Task { await controller.handleApple(result, rawNonce: raw) }
        }
        .signInWithAppleButtonStyle(.white)
        .frame(height: 52)
        .clipShape(Capsule())
        .disabled(controller.isWorking)
        .opacity(controller.work == .apple ? 0.6 : 1)
        .accessibilityIdentifier("signin.apple")
    }

    private var googleButton: some View {
        Button {
            Task { await controller.signInWithGoogle() }
        } label: {
            HStack(spacing: HV.Space.s) {
                if controller.work == .google {
                    ProgressView()
                } else {
                    Text("G")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Palette.textPrimary)
                }
                Text("Continue with Google")
            }
        }
        .buttonStyle(.hvSecondary)
        .disabled(controller.isWorking)
        .accessibilityIdentifier("signin.google")
    }

    private var emailButton: some View {
        Button {
            // A line from another way in belongs to the screen behind, not to the form that opens over it.
            controller.clearMessage()
            showEmail = true
        } label: {
            HStack(spacing: HV.Space.s) {
                HVIcon("envelope")
                Text("Continue with email")
            }
        }
        .buttonStyle(.hvSecondary)
        .disabled(controller.isWorking)
        .accessibilityIdentifier("signin.email")
    }
}

/// Email, then the six digits that arrive in it.
struct EmailCodeSheet: View {
    let controller: SignInController
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var code = ""
    @FocusState private var focus: Field?

    private enum Field { case email, code }

    var body: some View {
        VStack(alignment: .leading, spacing: HV.Space.l) {
            HVSheetHeader(
                title: controller.emailSentTo == nil ? "Sign in with email" : "Check your email",
                subtitle: controller.emailSentTo.map { "We sent a six-digit code to \($0)." }
                    ?? "We'll email you a code. A new address becomes a new account.",
                onClose: { dismiss() }
            )

            if controller.emailSentTo == nil {
                // The example is the prompt, not the title: VoiceOver reads the title as the field's name.
                TextField("Email address", text: $email, prompt: .hvPrompt("you@example.com"))
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .email)
                    .submitLabel(.send)
                    .onSubmit { send() }
                    .accessibilityHint(controller.message ?? "")
                    .accessibilityIdentifier("email.address")
                    .hvFieldChrome(isFocused: focus == .email)
                errorLine

                Button {
                    send()
                } label: {
                    if controller.work == .emailSend { ProgressView().tint(.white) } else { Text("Send me a code") }
                }
                .buttonStyle(.hvPrimary)
                .disabled(email.isEmpty || controller.isWorking)
                .accessibilityIdentifier("email.send")
            } else {
                TextField("Six-digit code", text: $code, prompt: .hvPrompt("123456"))
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                    .font(.system(.title2, design: .monospaced, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .focused($focus, equals: .code)
                    .accessibilityHint(controller.message ?? "")
                    .accessibilityIdentifier("email.code")
                    .hvFieldChrome(isFocused: focus == .code)
                    .onChange(of: code) { _, newValue in
                        let digits = newValue.filter(\.isNumber)
                        if digits != newValue { code = digits }
                        if digits.count == 6 { verify() }
                    }
                errorLine

                Button {
                    verify()
                } label: {
                    if controller.work == .emailVerify { ProgressView().tint(.white) } else { Text("Sign in") }
                }
                .buttonStyle(.hvPrimary)
                .disabled(code.count < 6 || controller.isWorking)
                .accessibilityIdentifier("email.verify")

                HStack {
                    Button("Use a different email") {
                        code = ""
                        controller.resetEmail()
                    }
                    .accessibilityIdentifier("email.change")
                    Spacer()
                    Button("Send again") {
                        Task { _ = await controller.sendEmailCode(controller.emailSentTo ?? email) }
                    }
                    .accessibilityIdentifier("email.resend")
                }
                .buttonStyle(.hvGhost)
            }

            Spacer(minLength: 0)
        }
        .padding(HV.Space.l)
        .task { focus = controller.emailSentTo == nil ? .email : .code }
        .onChange(of: controller.emailSentTo) { _, sent in
            focus = sent == nil ? .email : .code
        }
    }

    /// What went wrong, right under the field it is about, so it is the next thing read after the field.
    @ViewBuilder
    private var errorLine: some View {
        if let message = controller.message {
            Text(message).font(.hvFootnote).foregroundStyle(Palette.danger)
                .accessibilityIdentifier("email.error")
        }
    }

    private func send() {
        guard !email.isEmpty else { return }
        Task { _ = await controller.sendEmailCode(email) }
    }

    private func verify() {
        guard code.count == 6 else { return }
        Task { await controller.verifyEmailCode(code) }
    }
}
