import HyperVaultKit
import LocalAuthentication
import SafariServices
import SwiftUI
import UniformTypeIdentifiers

// What the screens of Agent keys, the vault and Your address share: how
// they reach the account lists, how a secret is copied, how a lock is honoured,
// and how a web page is opened. Nothing here is a screen.

extension AppEnvironment {
    /// PostgREST with this person's own token, for the lists no `/api` route returns (their keys, their
    /// addresses). The web page reads the same tables on the server. Without a Supabase config (a preview)
    /// the ordinary client answers, so canned `/rest/v1/...` routes stand in.
    var keysRest: AccountRest {
        if let supabase = capabilities.supabase {
            return AccountRest(client: HVClient(baseURL: supabase.url, tokens: auth), anonKey: supabase.anonKey)
        }
        return AccountRest(client: client, anonKey: "preview")
    }
}

/// The sentence for an error a screen shows inline: the server's own words.
func keysMessage(for error: Error) -> String {
    (error as? HVError)?.userMessage ?? error.localizedDescription
}

/// First-run state the connect card on the canvas keeps on the profile (PATCH /api/onboarding). Best effort and
/// silent: a server that cannot record it leaves the card dismissed on this phone only (`ConnectCardModel` remembers
/// it here first). Only what the person does is recorded; the app never records that an agent connected, since it has
/// no check of that to go by.
enum ConnectOnboarding {
    /// "I'll look around first": the connect card was dismissed. Sends `{ connect_dismissed: true }` and says whether
    /// the server took it; the caller has no one to tell about a failure, so it may ignore the answer.
    @discardableResult
    static func recordDismissed(client: HVClient) async -> Bool {
        (try? await client.send(.recordOnboarding(connectDismissed: true))) != nil
    }
}

/// The words of the Agent keys screens that more than one place says or that a test pins.
enum KeysCopy {
    /// The Agent keys pane's description, verbatim (brand book, section 4). It is the same whatever the keys have
    /// done: no route reports whether an agent connected, so the web's "N agents connected." is never shown.
    static let paneDescription = "One key per agent. A key is shown once, and comes with a setup challenge the agent completes to prove the link works."

    /// Revoking asks twice, like the web's button: "Revoke", then "Really revoke?", then "Revoking...".
    static let revoke = "Revoke"
    static let reallyRevoke = "Really revoke?"
    static let revoking = "Revoking..."

    static func revokeMessage(for key: AgentKey) -> String {
        "The agent using \(key.displayName ?? key.prefixLabel) stops working at once. This cannot be undone."
    }
}

// MARK: Copying

enum KeysPasteboard {
    /// How long a copied secret stays on the pasteboard.
    static let secretLifetime: TimeInterval = 60

    /// What keeps a secret on this phone and takes it off the pasteboard by itself.
    static func secretOptions(now: Date = Date()) -> [UIPasteboard.OptionsKey: Any] {
        [.localOnly: true, .expirationDate: now.addingTimeInterval(secretLifetime)]
    }

    /// Copies text. A secret (a key, a password, anything that carries one) is kept to this device and
    /// leaves the pasteboard by itself, so it does not ride Universal Clipboard or linger.
    static func copy(_ text: String, secret: Bool) {
        if secret {
            UIPasteboard.general.setItems([[UTType.plainText.identifier: text]], options: secretOptions())
        } else {
            UIPasteboard.general.string = text
        }
    }
}

/// A copy button that says "Copied" for a moment. `isSecret` copies with the expiring, local-only item.
struct KeysCopyButton: View {
    enum Style { case primary, secondary, compact }

    let title: String
    let text: String
    var isSecret = false
    var style: Style = .compact
    var accessibilityHint: String?
    var onCopy: (() -> Void)?

    @State private var copied = false

    var body: some View {
        switch style {
        case .primary: button.buttonStyle(.hvPrimary)
        case .secondary: button.buttonStyle(.hvSecondary)
        // The ghost style has no padding of its own, so its words start where the text above them starts.
        case .compact: button.buttonStyle(.hvGhost)
        }
    }

    private var button: some View {
        Button {
            KeysPasteboard.copy(text, secret: isSecret)
            Haptics.success()
            copied = true
            onCopy?()
            Task {
                try? await Task.sleep(nanoseconds: UInt64(HV.Motion.copiedHold * 1_000_000_000))
                copied = false
            }
        } label: {
            Label(copied ? ConnectCopy.copiedLabel : title, systemImage: copied ? HVSymbol.copied : HVSymbol.copy)
        }
        .accessibilityLabel(copied ? "Copied" : title)
        .accessibilityHint(accessibilityHint ?? (isSecret ? "Copies to this device only, and clears in a minute." : ""))
    }
}

// MARK: Locking

enum KeysBiometricGate {
    /// Whether Settings' lock is on.
    static var isOn: Bool { UserDefaults.standard.bool(forKey: PrefKey.biometricLock) }

    /// Asks for Face ID or the passcode before a screen that adds or replaces a secret, but only when the
    /// lock is on in Settings. Off, or on a phone that cannot ask, it lets the person through.
    @MainActor
    static func confirm(reason: String) async -> Bool {
        guard isOn else { return true }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return true }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}

// MARK: Web pages

/// A page of the web app or a person's own address, shown in Safari. Payment and the pages that live on
/// the web are opened here rather than rebuilt.
struct KeysWebPage: Identifiable, Equatable {
    let url: URL
    var id: String { url.absoluteString }

    init?(_ url: URL?) {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        self.url = url
    }
}

struct KeysSafariSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

// MARK: Small pieces

private struct KeysHidesWhenInactive: ViewModifier {
    let enabled: Bool
    @State private var hidden = false

    func body(content: Content) -> some View {
        content
            .blur(radius: enabled && hidden ? 14 : 0)
            // Resigning active is what comes just before the app switcher takes its picture.
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in hidden = true }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in hidden = false }
    }
}

extension View {
    /// Blurs a secret while the app is leaving the foreground, so the app switcher's snapshot does not show it.
    func keysHidesWhenInactive(_ enabled: Bool = true) -> some View { modifier(KeysHidesWhenInactive(enabled: enabled)) }
}

/// A calm notice with a tint: the amber "untested" and "the URL is the key" warnings, and the like.
struct KeysNotice: View {
    let text: String
    var symbol = "exclamationmark.triangle.fill"
    var tint: Color = Palette.warning

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: HV.Space.s) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .font(.hvFootnote)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(HV.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(HV.Tint.fill), in: RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous).strokeBorder(tint.opacity(HV.Tint.border), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// A line of text in the server's voice under a field or an action, red when it is a problem.
struct KeysInlineMessage: View {
    let text: String
    var isError = true

    var body: some View {
        Text(text)
            .font(.hvFootnote)
            .foregroundStyle(isError ? Palette.danger : Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A large title at ordinary sizes and an inline one at accessibility sizes, where a large title is cut
/// off mid-phrase ("Account & ke...") and takes a third of the first screen.
private struct KeysTitleDisplay: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        content.navigationBarTitleDisplayMode(dynamicTypeSize.isAccessibilitySize ? .inline : .large)
    }
}

extension View {
    func keysLargeTitle() -> some View { modifier(KeysTitleDisplay()) }
}

/// A row's leading mark and its words. Side by side while there is room; at accessibility sizes the mark goes
/// above the words, so a name or an address is not wrapped into a narrow column beside it. The trailing view
/// (a tag, a time) is for the side-by-side layout: a row that has one puts it under its words itself when
/// `dynamicTypeSize.isAccessibilitySize`.
struct KeysRowLayout<Mark: View, Words: View, Trailing: View>: View {
    var alignment: VerticalAlignment
    let mark: Mark
    let words: Words
    let trailing: Trailing

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        alignment: VerticalAlignment = .center,
        @ViewBuilder mark: () -> Mark,
        @ViewBuilder words: () -> Words,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.alignment = alignment
        self.mark = mark()
        self.words = words()
        self.trailing = trailing()
    }

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: HV.Space.xs) {
                mark
                words
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: alignment, spacing: HV.Space.s) {
                mark
                words
                Spacer(minLength: HV.Space.xs)
                trailing
            }
        }
    }
}

extension KeysRowLayout where Trailing == EmptyView {
    init(alignment: VerticalAlignment = .center, @ViewBuilder mark: () -> Mark, @ViewBuilder words: () -> Words) {
        self.init(alignment: alignment, mark: mark, words: words) { EmptyView() }
    }
}

/// The disclosure mark for a row that opens something without being a NavigationLink (a sheet, another
/// tab), drawn the way the system draws its own so the two kinds of row read alike.
struct KeysChevron: View {
    /// A quarter turn down, for a row that is open.
    var isOpen = false

    var body: some View {
        Image(systemName: HVSymbol.open)
            .font(.system(.footnote, weight: .semibold))
            .foregroundStyle(Palette.textTertiary)
            .rotationEffect(.degrees(isOpen ? 90 : 0))
            .accessibilityHidden(true)
    }
}

extension Date {
    /// "Oct 24, 2026".
    var keysDay: String { formatted(date: .abbreviated, time: .omitted) }
}
