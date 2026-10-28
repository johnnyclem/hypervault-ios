import HyperVaultKit
import SwiftUI
import UIKit

// Small pieces the Library and the page screens share: the icon swatch, the
// visibility mark, the system share sheet, a code view, and a few helpers.

extension Color {
    /// HSL as CSS writes it (hue in degrees, saturation and lightness 0...1), for the
    /// gradients the web derives from a slug.
    init(artifactHue degrees: Double, saturation s: Double, lightness l: Double) {
        let brightness = l + s * min(l, 1 - l)
        let saturation = brightness == 0 ? 0 : 2 * (1 - l / brightness)
        self.init(hue: degrees / 360, saturation: saturation, brightness: brightness)
    }

    init(_ swatch: ArtifactIcon.Swatch) {
        self.init(artifactHue: swatch.hue, saturation: swatch.saturation, lightness: swatch.lightness)
    }
}

/// An artifact's home-screen icon, drawn the way the server draws it: the slug's
/// gradient with the title's initial (or the glyph the person chose). The web's white
/// letter cannot be read on the yellows and greens a slug can hash to, so there the
/// letter is dark; everywhere else it is the web's white.
struct ArtifactGlyph: View {
    let slug: String
    let title: String
    var icon: String?
    var size: CGFloat = 40

    var body: some View {
        let glyph = ArtifactIcon.glyph(icon: icon, title: title)
        let stops = ArtifactIcon.stops(seed: slug)
        let ink = ArtifactIcon.prefersDarkGlyph(seed: slug) ? HVColor.background : Color.white
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(LinearGradient(colors: [Color(stops.first), Color(stops.second)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(glyph)
                .font(.system(size: size * (glyph.count >= 2 ? 0.42 : 0.52), weight: .bold))
                .foregroundStyle(ink)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The lock or key beside a page that is not open to everyone. Public shows nothing.
struct ArtifactVisibilityMark: View {
    let visibility: ArtifactVisibility

    var body: some View {
        switch visibility {
        case .private:
            Image(systemName: "lock.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.textTertiary)
                .accessibilityLabel("Private")
        case .password:
            Image(systemName: "key.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.textTertiary)
                .accessibilityLabel("Password protected")
        case .public:
            EmptyView()
        }
    }
}

extension ArtifactVisibility {
    var symbol: String {
        switch self {
        case .public: return "globe"
        case .private: return "lock.fill"
        case .password: return "key.fill"
        }
    }

    var tint: Color {
        switch self {
        case .public: return Palette.mint
        case .private: return Palette.blue
        case .password: return Palette.amber
        }
    }
}

/// The system share sheet, for places a `ShareLink` cannot go (a swipe action).
struct ArtifactActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// A link to hand to the share sheet; `Identifiable` so a sheet can be driven by it.
struct ArtifactShareTarget: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// A monospaced text view for source: selectable, and editable when asked. A
/// `UITextView` rather than a `TextEditor` because a page can be a megabyte.
struct ArtifactCodeView: UIViewRepresentable {
    @Binding var text: String
    var isEditable = false
    /// What a UI test finds the text view by.
    var identifier: String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .regular))
        view.adjustsFontForContentSizeCategory = true
        view.autocapitalizationType = .none
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.backgroundColor = .clear
        view.textColor = .label
        view.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        view.keyboardDismissMode = .interactive
        view.alwaysBounceVertical = true
        view.delegate = context.coordinator
        view.text = text
        view.isEditable = isEditable
        view.accessibilityIdentifier = identifier
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text { view.text = text }
        if view.isEditable != isEditable { view.isEditable = isEditable }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ArtifactCodeView

        init(_ parent: ArtifactCodeView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            if parent.text != textView.text { parent.text = textView.text }
        }
    }
}

/// A line of the server's own words under a field or a row, in the danger colour.
struct ArtifactErrorLine: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill").hvRowLabel()
            .font(.hvFootnote)
            .foregroundStyle(Palette.danger)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
    }
}

/// A field's hint in a colour that can be read. The system's own placeholder is the faintest grey
/// it has, and under 2:1 on paper. The tertiary grey holds 4.5:1 and is still lighter than what is typed.
func artifactPrompt(_ text: String) -> Text {
    Text(text).foregroundStyle(Palette.textTertiary)
}

extension View {
    /// A header or a footer over a hand-built card, set in from the card's edge the way a grouped
    /// list sets in its own, so a sheet made of cards and a sheet made of lists line up.
    func artifactCardCaption() -> some View {
        padding(.horizontal, HV.Space.m)
    }
}

enum ArtifactPasteboard {
    /// A link or some source: an ordinary copy.
    static func copy(_ text: String) {
        UIPasteboard.general.string = text
    }

    /// A password shown once: it stays on this device and goes away by itself.
    static func copySecret(_ text: String, lifetime: TimeInterval = 120) {
        UIPasteboard.general.setItems(
            [["public.utf8-plain-text": text]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(lifetime)]
        )
    }
}

enum ArtifactErrors {
    /// The server's sentence, or a plain one for anything that is not an `HVError`.
    static func message(_ error: Error) -> String {
        (error as? HVError)?.userMessage ?? error.localizedDescription
    }
}

/// How a screen that loads once shows itself.
enum ArtifactLoad<Value> {
    case loading
    case loaded(Value)
    case failed(String)

    var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }
}

extension AppEnvironment {
    /// Reads the person's own rows from Supabase (their addresses, pins, shares). Nil when this
    /// server reports no Supabase project, in which case those parts simply do not appear.
    var artifactTables: ArtifactTables? {
        guard let config = capabilities.supabase else { return nil }
        return ArtifactTables(config: config, tokens: auth)
    }
}
