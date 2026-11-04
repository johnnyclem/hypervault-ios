import SwiftUI
import UIKit

/// What a worn theme asks of the whole window, as one modifier on the root of each hierarchy (the app's, and the privacy
/// cover's, which is a window of its own).
///
///   * The accent: the web's `primary`, set outright (a Toggle with none draws system green).
///   * The font design a theme asks for (`serif` or `mono`), laid over the system face. `fontDesign` keeps Dynamic Type: it
///     changes the design of the text style the view already asked for, not its size. A stock look and a `system` theme ask
///     for nothing, so those texts are untouched.
///   * The appearance: a theme defines one palette, so a worn theme pins the app light or dark, whatever the phone is set to,
///     because plain `Text`, a `Form`, a navigation title and the keyboard take the system's black or white and a light theme
///     on a dark-set phone would otherwise draw white text on cream. `preferredColorScheme` reaches every SwiftUI view and
///     presentation; the window's `overrideUserInterfaceStyle` reaches what UIKit draws on its own (the keyboard, an alert, a
///     context menu, the share sheet). A stock look sets neither, and leaves the window as it found it.
///   * The window's tint, for the same UIKit chrome, and the tab bar, which keeps its colours on the bar itself.
///
/// Plain `Text` is deliberately not given the theme's `foreground`: a root `foregroundStyle` would also override the tint of
/// every plain `Button` and `Link`. The Kit holds the system label to the floors on the theme's surfaces instead
/// (`StyleKitContract`, "system label on ..."), so it reads.
private struct HVAppStyle: ViewModifier {
    func body(content: Content) -> some View {
        // Read here so that this body is drawn again when the look changes.
        let look = StyleRuntime.shared.snapshot
        content
            .tint(HVColor.primary)
            .fontDesign(look.font.swiftUIDesign)
            .preferredColorScheme(Self.scheme(for: look))
            .background(HVWindowStyle(look: look))
    }

    /// The appearance to pin the hierarchy to, or nil to follow the system. A UI-test launch pins dark so the layout sweeps
    /// measure a dark page; a worn theme pins its own appearance instead.
    private static func scheme(for look: StyleRuntime.Snapshot) -> ColorScheme? {
        #if DEBUG
        if UITestHarness.isActive { return look.appearance?.colorScheme ?? .dark }
        #endif
        return look.appearance?.colorScheme
    }
}

extension View {
    /// The accent, the font design, the appearance and the window of the person's theme (`HVAppStyle`). On the root of the
    /// app and of the privacy cover, once each.
    func hvAppStyle() -> some View {
        modifier(HVAppStyle())
    }
}

/// Reaches the window the hierarchy is in, and sets what SwiftUI cannot: its interface style, its tint and the tab bars in
/// it. It draws nothing. It acts only while a theme is worn, and hands the window back to the system when the theme goes,
/// so a stock look never touches a window (the snapshot tests pin their own).
private struct HVWindowStyle: UIViewRepresentable {
    let look: StyleRuntime.Snapshot

    func makeUIView(context: Context) -> WindowStyleView {
        let view = WindowStyleView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.look = look
        return view
    }

    func updateUIView(_ view: WindowStyleView, context: Context) {
        view.look = look
    }
}

private final class WindowStyleView: UIView {
    var look = StyleRuntime.Snapshot() {
        didSet { apply() }
    }

    /// Whether this view has set the window's style or tint, so it knows what to give back.
    private var overridesStyle = false
    private var tintsWindow = false
    /// What was last applied, so a re-evaluation that changed nothing does not touch the window again.
    private var appliedRevision: Int?
    private weak var appliedWindow: UIWindow?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        apply()
    }

    private func apply() {
        guard let window else { return }
        if window === appliedWindow, appliedRevision == look.revision { return }
        appliedWindow = window
        appliedRevision = look.revision

        let wasThemed = overridesStyle || tintsWindow
        if let appearance = look.appearance {
            window.overrideUserInterfaceStyle = appearance.userInterfaceStyle
            overridesStyle = true
        } else if overridesStyle {
            window.overrideUserInterfaceStyle = .unspecified
            overridesStyle = false
        }
        if let ink = look.window {
            window.tintColor = UIColor.hvDynamic(normal: ink.tint, high: ink.tintHigh)
            tintsWindow = true
        } else if tintsWindow {
            window.tintColor = nil
            tintsWindow = false
        }
        // The tab bar's colours are on the bar, and the system's appearance proxy only reaches bars made after it is set.
        if look.isThemed || wasThemed {
            HVTabBarStyle.refresh(in: window)
        }
    }
}
