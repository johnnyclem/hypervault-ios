import HyperVaultKit
import LocalAuthentication
import SafariServices
import SwiftUI
import UniformTypeIdentifiers

// What the screens of Account & keys, the vault and Your address share: how
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
/// silent: a server that cannot record it just shows the card once per device.
enum ConnectOnboarding {
    /// "I'll look around first": the connect card was dismissed. Call it from wherever that card lives.
    static func recordDismissed(client: HVClient) {
        Task { _ = try? await client.send(.recordOnboarding(connectDismissed: true)) }
    }

    /// An agent finished its setup challenge.
    static func recordCompleted(client: HVClient) {
        Task { _ = try? await client.send(.recordOnboarding(connectCompleted: true)) }
    }
}

// MARK: Copying

enum KeysPasteboard {
    /// How long a copied secret stays on the pasteboard.
    static let secretLifetime: TimeInterval = 120

    /// Copies text. A secret (a key, a password, anything that carries one) is kept to this device and
    /// leaves the pasteboard by itself, so it does not ride Universal Clipboard or linger.
    static func copy(_ text: String, secret: Bool) {
        if secret {
            UIPasteboard.general.setItems(
                [[UTType.plainText.identifier: text]],
                options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(secretLifetime)]
            )
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
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                copied = false
            }
        } label: {
            Label(copied ? ConnectCopy.copiedLabel : title, systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .accessibilityLabel(copied ? "Copied" : title)
        .accessibilityHint(accessibilityHint ?? (isSecret ? "Copies to this device only, and clears in two minutes." : ""))
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
    @Environment(\.scenePhase) private var phase

    func body(content: Content) -> some View {
        content.blur(radius: phase == .active ? 0 : 14)
    }
}

extension View {
    /// Blurs a secret while the app is not in the foreground, so the app switcher's snapshot does not show it.
    func keysHidesWhenInactive() -> some View { modifier(KeysHidesWhenInactive()) }
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
        .padding(HV.Space.s + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous).strokeBorder(tint.opacity(0.35), lineWidth: 1))
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

extension Date {
    /// "Oct 24, 2026".
    var keysDay: String { formatted(date: .abbreviated, time: .omitted) }
}

#if DEBUG
/// A preview host that also takes the capabilities a screen reads (the portfolio, the themes, the limits),
/// which `PreviewHost` does not forward.
struct KeysPreviewHost<Content: View>: View {
    @State private var env: AppEnvironment
    @State private var model = AppModel.preview()
    private let content: Content
    private let embedInNavigation: Bool

    init(
        routes: [MockRoute] = [],
        capabilities: Capabilities = Capabilities(),
        delay: TimeInterval = 0.2,
        embedInNavigation: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        _env = State(initialValue: AppEnvironment.preview(routes: routes, delay: delay, capabilities: capabilities))
        self.content = content()
        self.embedInNavigation = embedInNavigation
    }

    var body: some View {
        Group {
            if embedInNavigation {
                NavigationStack { content }
            } else {
                content
            }
        }
        .environment(env)
        .environment(model)
        .tint(Palette.blue)
    }
}
#endif
