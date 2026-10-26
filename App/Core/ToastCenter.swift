import HyperVaultKit
import SwiftUI

/// A short message that appears over the top of the screen and goes away by itself.
struct Toast: Identifiable, Equatable {
    enum Style { case info, success, error }

    let id = UUID()
    var message: String
    var style: Style

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
@MainActor
@Observable
final class ToastCenter {
    private(set) var current: Toast?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    func show(_ message: String, style: Toast.Style = .info) {
        let toast = Toast(message: message, style: style)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { current = toast }
        switch style {
        case .success: Haptics.success()
        case .error: Haptics.failure()
        case .info: break
        }
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: style == .error ? 4_500_000_000 : 3_000_000_000)
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
                        .font(.system(.subheadline, design: .rounded, weight: .medium))
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
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isStaticText)
            }
            Spacer()
        }
        .allowsHitTesting(center.current != nil)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: center.current)
    }
}
