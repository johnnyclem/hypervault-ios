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

    var body: some View {
        ZStack {
            AuroraBackground()
            BrandMark(size: 92)
                .scaleEffect(breathe ? 1.04 : 0.98)
                .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: breathe)
        }
        .onAppear { breathe = true }
        .accessibilityLabel("HyperVault is opening")
    }
}

/// The server could not be reached and nothing is cached to open from.
struct UnreachableView: View {
    @Environment(AppModel.self) private var model
    let message: String

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
                }
                Button("Try again") {
                    Task { await model.retry() }
                }
                .buttonStyle(.hvPrimary)
                .frame(maxWidth: 280)
            }
            .padding(HV.Space.xl)
        }
    }
}
