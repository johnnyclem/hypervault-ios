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
        HV.Motion.animate(.spring(response: 0.35, dampingFraction: 0.82)) { current = toast }
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
        HV.Motion.animate { current = nil }
    }
}

/// Overlays the current toast. Put it once, at the root.
///
/// It sits below the navigation bar and not over it: the host fills the safe area, whose top edge is where the bar
/// starts, and the bar's buttons (Back, the toolbar's icons) are in its first 44 points. A toast drawn there hides the
/// button a person may reach for next, so it begins under them. Only the toast itself answers a touch (the space round
/// it is not a tap target), so the screen under it stays live while it is up.
struct ToastHost: View {
    let center: ToastCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The height of the system navigation bar on iPhone, which does not grow with the text size. On iPad the tab bar can
    /// sit above the navigation bar, and the toast may then land on the lower of the two: not handled here, a device check.
    static let barHeight: CGFloat = 44

    var body: some View {
        VStack {
            if let toast = center.current {
                card(toast)
                    .padding(.horizontal, HV.Space.m)
                    // The room for the bar and a gap under it. It is outside the tap and the accessibility element,
                    // so the strip over the bar's buttons is not part of the toast.
                    .padding(.top, Self.barHeight + HV.Space.xs)
                    // Under Reduce Motion the toast fades; it does not slide in.
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
            Spacer()
        }
        .allowsHitTesting(center.current != nil)
        .animation(reduceMotion ? HV.Motion.entrance : Animation.spring(response: 0.35, dampingFraction: 0.82), value: center.current)
    }

    private func card(_ toast: Toast) -> some View {
        HStack(spacing: HV.Space.s) {
            HVIcon(toast.symbol).foregroundStyle(toast.tint)
            Text(toast.message)
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
                .multilineTextAlignment(.leading)
                .lineLimit(3)
        }
        .padding(.horizontal, HV.Space.m)
        .padding(.vertical, HV.Space.s)
        .hvGlass(radius: HV.Radius.floating)
        .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 8)
        .onTapGesture { center.dismiss(toast.id) }
        // One element that says what the eye sees, error and all, and that a double tap dismisses.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(toast.spoken)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Dismisses this message")
        .accessibilityAction { center.dismiss(toast.id) }
    }
}
