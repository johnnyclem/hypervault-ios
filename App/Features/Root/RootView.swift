import HyperVaultKit
import SwiftUI

/// Decides what the whole window shows: the launch moment, the first-run flow,
/// the waitlist, or the app.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            // A cover hides the app from the eye only. While locked, the app is also hidden from VoiceOver and switched
            // off, so Switch Control, Full Keyboard Access and a keyboard that is still up cannot reach what is behind it.
            // The shield is not treated so: it is up for a moment whenever the app is not frontmost, and switching the app
            // off then would drop the focus of the field the person is typing in.
            ZStack {
                content
                ToastHost(center: model.toasts)
            }
            .accessibilityHidden(model.lock.isLocked)
            .disabled(model.lock.isLocked)
            if model.lock.isLocked {
                LockScreen(lock: model.lock).transition(.opacity)
            } else if model.lock.isShielded {
                PrivacyShield().transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: model.phase)
        .animation(.easeInOut(duration: 0.2), value: model.lock.isLocked)
        .onChange(of: scenePhase) { _, phase in model.lock.scenePhaseChanged(phase) }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .launching:
            LaunchView()
                .transition(.opacity)
        case .unreachable(let message):
            UnreachableView(message: message)
                .transition(.opacity)
        case .signedOut:
            OnboardingFlow()
                .transition(.opacity)
        case .waitlisted(let user):
            WaitlistView(user: user)
                .transition(.opacity)
        case .ready:
            if let env = model.env {
                MainTabView()
                    .environment(env)
                    .id(env.user.id)
                    .transition(.opacity)
            }
        }
    }
}

/// The moment between tapping the icon and the app: the mark on quiet colour.
struct LaunchView: View {
    @State private var breathe = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            AuroraBackground()
            BrandMark(size: 92)
                .scaleEffect(reduceMotion ? 1 : (breathe ? 1.04 : 0.98))
                .animation(reduceMotion ? nil : .easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: breathe)
        }
        .onAppear { breathe = true }
        .accessibilityLabel("HyperVault is opening")
    }
}

/// The server could not be reached and nothing is cached to open from. When the app is pointed at an address of
/// the person's own choosing, this is also the way back to the server the app ships with.
struct UnreachableView: View {
    @Environment(AppModel.self) private var model
    let message: String

    @State private var isSwitching = false

    var body: some View {
        ZStack {
            AuroraBackground(intensity: 0.6)
            VStack(spacing: HV.Space.l) {
                BrandMark(size: 64)
                VStack(spacing: HV.Space.xs) {
                    Text("Can't reach HyperVault")
                        .font(.hvTitle)
                    Text(message)
                        .font(.hvCallout)
                        .foregroundStyle(Palette.textSecondary)
                        .multilineTextAlignment(.center)
                    if !model.isOnDefaultServer {
                        Text("This phone is set to \(Self.name(of: model.server)).")
                            .font(.hvFootnote)
                            .foregroundStyle(Palette.textTertiary)
                            .multilineTextAlignment(.center)
                    }
                }
                VStack(spacing: HV.Space.s) {
                    Button("Try again") {
                        Task { await model.retry() }
                    }
                    .buttonStyle(.hvPrimary)
                    .frame(maxWidth: 280)
                    .disabled(isSwitching)

                    if !model.isOnDefaultServer {
                        Button {
                            Task {
                                isSwitching = true
                                await model.resetServer()
                                isSwitching = false
                            }
                        } label: {
                            if isSwitching { ProgressView() } else { Text("Use \(Self.name(of: SharedConfig.defaultServer)) instead") }
                        }
                        .buttonStyle(.hvGhost)
                        .disabled(isSwitching)
                    }
                }
            }
            .padding(HV.Space.xl)
        }
    }

    private static func name(of server: ServerConfig) -> String {
        server.baseURL.host() ?? server.baseURL.absoluteString
    }
}
