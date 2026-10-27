import HyperVaultKit
import SwiftUI

/// A short message that appears over the top of the screen and goes away by itself.
struct Toast: Identifiable, Equatable {
    enum Style { case info, success, error }

    let id = UUID()
    var message: String
    var style: Style

    /// What VoiceOver says: the words, and that it was an error, which the icon alone shows to the eye.
    var spoken: String {
        style == .error ? "Error. \(message)" : message
    }

    var symbol: String {
        switch style {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch style {
        case .info: return Palette.blue
        case .success: return Palette.success
        case .error: return Palette.danger
        }
    }
}

/// Where non-blocking feedback goes. Errors from the API are shown with the
/// server's own sentence; nothing here ever needs dismissing.
///
/// This is the app's one channel for results, and a view that appears is not announced, so every toast is also
/// spoken. VoiceOver and Switch Control take longer to reach and to read a message than the eye does, so it
/// stays up longer for them.
@MainActor
@Observable
final class ToastCenter {
    private(set) var current: Toast?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?
    @ObservationIgnored private let announcer: SpeechAnnouncer
    @ObservationIgnored private let usesAssistiveTechnology: @MainActor () -> Bool

    init(
        announcer: SpeechAnnouncer = VoiceOverAnnouncer.shared,
        usesAssistiveTechnology: @escaping @MainActor () -> Bool = { UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning }
    ) {
        self.announcer = announcer
        self.usesAssistiveTechnology = usesAssistiveTechnology
    }

    /// How long a toast stays up, in seconds. About ten characters a second is a comfortable speaking pace; on top of
    /// that goes time to find the message and to act on it.
    nonisolated static func hold(style: Toast.Style, message: String, assistive: Bool) -> TimeInterval {
        guard assistive else { return style == .error ? 4.5 : 3 }
        return min(20, max(10, 4 + Double(message.count) / 10))
    }

    func show(_ message: String, style: Toast.Style = .info) {
        let toast = Toast(message: message, style: style)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { current = toast }
        switch style {
        case .success: Haptics.success()
        case .error: Haptics.failure()
        case .info: break
        }
        announcer.announce(toast.spoken)
        let hold = Self.hold(style: style, message: message, assistive: usesAssistiveTechnology())
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss(toast.id)
        }
    }

    func success(_ message: String) { show(message, style: .success) }

    /// Shows an error. A cancelled request is not an error worth showing.
    func show(error: Error) {
        if let hv = error as? HVError {
            if case .cancelled = hv { return }
            show(hv.userMessage, style: .error)
        } else if error is CancellationError {
            return
        } else {
            show(error.localizedDescription, style: .error)
        }
    }

    func dismiss(_ id: UUID? = nil) {
        guard id == nil || current?.id == id else { return }
        withAnimation(.easeOut(duration: 0.2)) { current = nil }
    }
}

/// Overlays the current toast. Put it once, at the root.
struct ToastHost: View {
    let center: ToastCenter

    var body: some View {
        VStack {
            if let toast = center.current {
                HStack(spacing: HV.Space.s) {
                    Image(systemName: toast.symbol).foregroundStyle(toast.tint)
                    Text(toast.message)
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(Palette.textPrimary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                }
                .padding(.horizontal, HV.Space.m)
                .padding(.vertical, HV.Space.s + 2)
                .hvGlass(radius: 22)
                .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 8)
                .padding(.horizontal, HV.Space.m)
                .padding(.top, HV.Space.xs)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture { center.dismiss(toast.id) }
                // One element that says what the eye sees, error and all, and that a double tap dismisses.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(toast.spoken)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Dismisses this message")
                .accessibilityAction { center.dismiss(toast.id) }
            }
            Spacer()
        }
        .allowsHitTesting(center.current != nil)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: center.current)
    }
}
