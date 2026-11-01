import HyperVaultKit
import SwiftUI

/// The web's job card as a banner: what finished, what came of it, how many more are waiting, and a way to close it.
struct JobNoticeBanner: View {
    let notice: BackgroundJobNotice
    let waiting: Int
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            words
            footer
        }
        // The banner takes the height its wrapped words need, whatever height its parent offers: a parent that shares
        // its height out (a stack with a Spacer beside the banner) would otherwise squeeze the message down to one
        // line and an ellipsis, and the line that tells what to do next is the one that is lost.
        .fixedSize(horizontal: false, vertical: true)
        .hvCard()
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: HV.Space.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: HV.Space.xs) {
                HVIcon(notice.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(notice.succeeded ? Palette.success : Palette.danger)
                Text(notice.title)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
            }
            Text(notice.message)
                .font(.hvCallout)
                .foregroundStyle(Palette.textSecondary)
        }
        // One element that says what the eye sees, failure and all.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(notice.spoken)
    }

    private var footer: some View {
        HStack {
            if waiting > 0 {
                Text("+\(waiting) more waiting")
                    .font(.hvCaption.monospacedDigit())
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer(minLength: 0)
            Button("Dismiss", action: onDismiss)
                .buttonStyle(.hvGhost)
                .accessibilityIdentifier("jobnotice.dismiss")
        }
        // The button is 44pt high around a line of text, so it brings room of its own under the word. The card's
        // padding below it is trimmed by that much, or the card has more below Dismiss than above the title.
        .padding(.bottom, -HV.Space.xs)
    }
}

/// Where the banner sits on a screen: the current notice, or nothing at all while there is none.
private struct JobNoticeBar: View {
    @Environment(AppEnvironment.self) private var env: AppEnvironment?

    var body: some View {
        if let notices = env?.jobNotices, let notice = notices.current {
            JobNoticeBanner(notice: notice, waiting: notices.waiting, onDismiss: { notices.dismiss(notice.id) })
                .padding(.horizontal, HV.Space.m)
                .padding(.vertical, HV.Space.xs)
                .hvReadableWidth()
        }
    }
}

// MARK: Screens

extension View {
    /// Puts the notices of finished background jobs over this screen while it is showing. It goes on the Home canvas and
    /// the Library, the two places they belong (the web mounts them on the Library alone), and not on a page: the repair
    /// sheet over a page tells its own job.
    func jobNotices() -> some View {
        modifier(JobNoticesModifier())
    }
}

private struct JobNoticesModifier: ViewModifier {
    /// Optional so a screen drawn without the app around it (a preview) asks for nothing.
    @Environment(AppModel.self) private var app: AppModel?
    @Environment(AppEnvironment.self) private var env: AppEnvironment?
    @Environment(\.scenePhase) private var scenePhase
    /// This screen's name in the notices' count: it is counted once however many times it reports.
    @State private var screen = UUID()
    @State private var isShowing = false

    func body(content: Content) -> some View {
        // Showing, in front of the person, out from behind the lock, and on the Home tab, where both screens are.
        let inFront = scenePhase == .active && app?.lock.isLocked == false
        let watching = isShowing && inFront && app?.router.tab == .canvas
        content
            .safeAreaInset(edge: .top, spacing: 0) { JobNoticeBar() }
            .onAppear { isShowing = true }
            .onDisappear {
                isShowing = false
                env?.jobNotices.setWatching(screen, false)
            }
            .onChange(of: watching, initial: true) { _, now in env?.jobNotices.setWatching(screen, now) }
    }
}
