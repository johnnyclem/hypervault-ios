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
        // The dark letter is a fixed ink: `HVColor.background` is the page, which is near-white in the light look, and a pale
        // letter on a yellow or green tile is under 2:1.
        let ink = ArtifactIcon.prefersDarkGlyph(seed: slug) ? Color(hex: 0x0B0F14) : Color.white
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
            mark.accessibilityLabel("Private")
        case .password:
            mark.accessibilityLabel("Password protected")
        case .public:
            EmptyView()
        }
    }

    /// The outline glyph `ArtifactVisibility.symbol` names, at the size of the caption it sits beside.
    private var mark: some View {
        Image(systemName: visibility.symbol)
            .font(.hvCaption.weight(.semibold))
            .foregroundStyle(Palette.textTertiary)
    }
}

extension ArtifactVisibility {
    /// Outline glyphs only, and the lock and the key are the ones the vault and a key draw everywhere else.
    var symbol: String {
        switch self {
        case .public: return "globe"
        case .private: return HVSymbol.vault
        case .password: return HVSymbol.key
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
    /// Drawn inside the field while it is empty, so it cannot sit in front of a tap.
    var placeholder: String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = CodeTextView()
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
        view.placeholder = placeholder
        view.refreshPlaceholder()
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text { view.text = text }
        if view.isEditable != isEditable { view.isEditable = isEditable }
        if let code = view as? CodeTextView {
            code.placeholder = placeholder
            code.refreshPlaceholder()
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ArtifactCodeView

        init(_ parent: ArtifactCodeView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            if parent.text != textView.text { parent.text = textView.text }
            (textView as? CodeTextView)?.refreshPlaceholder()
        }
    }
}

/// The page that holds this field waits to see whether a touch is a drag, and a tap that ends
/// during the wait is never delivered here, so the field never becomes first responder. A tap
/// recognizer on that page sees the touch immediately and focuses the field.
private final class CodeTextView: UITextView {
    var placeholder: String? {
        didSet { placeholderLabel.text = placeholder }
    }

    private let watchedScrolls = NSHashTable<UIScrollView>.weakObjects()
    private let placeholderLabel: UILabel = {
        let label = UILabel()
        label.numberOfLines = 0
        label.isUserInteractionEnabled = false
        label.isAccessibilityElement = false
        label.textColor = UIColor(named: "muted-foreground") ?? .secondaryLabel
        return label
    }()

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        isSelectable = true
        delaysContentTouches = false
        placeholderLabel.font = font
        addSubview(placeholderLabel)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isSelectable = true
        delaysContentTouches = false
        addSubview(placeholderLabel)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.contains(point)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        watchScrolls()
    }

    func refreshPlaceholder() {
        placeholderLabel.isHidden = placeholder == nil || !text.isEmpty
        placeholderLabel.font = font
        accessibilityHint = text.isEmpty ? placeholder : nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = textContainerInset
        let pad = textContainer.lineFragmentPadding
        let width = max(0, bounds.width - inset.left - inset.right - pad * 2)
        let size = placeholderLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        placeholderLabel.frame = CGRect(x: inset.left + pad, y: inset.top, width: width, height: size.height)
        watchScrolls()
    }

    func focus(at point: CGPoint) {
        guard isEditable, bounds.contains(point) else { return }
        if !isFirstResponder { _ = becomeFirstResponder() }
        if let position = closestPosition(to: point) {
            selectedTextRange = textRange(from: position, to: position)
        }
    }

    private func watchScrolls() {
        guard window != nil else { return }
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? UIScrollView {
                scroll.delaysContentTouches = false
                if !watchedScrolls.contains(scroll) {
                    let relay = CodeScrollTap(textView: self)
                    let tap = UITapGestureRecognizer(target: relay, action: #selector(CodeScrollTap.tapped))
                    tap.cancelsTouchesInView = false
                    tap.delaysTouchesBegan = false
                    tap.delaysTouchesEnded = false
                    tap.delegate = relay
                    objc_setAssociatedObject(tap, &CodeScrollTap.retainKey, relay, .OBJC_ASSOCIATION_RETAIN)
                    scroll.addGestureRecognizer(tap)
                    watchedScrolls.add(scroll)
                }
            }
            ancestor = view.superview
        }
    }
}

/// Held by the page's tap recognizer. It does not keep the text view alive.
private final class CodeScrollTap: NSObject, UIGestureRecognizerDelegate {
    static var retainKey: UInt8 = 0
    weak var textView: CodeTextView?

    init(textView: CodeTextView) {
        self.textView = textView
    }

    @objc func tapped(_ recognizer: UITapGestureRecognizer) {
        guard let textView else { return }
        textView.focus(at: recognizer.location(in: textView))
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
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
