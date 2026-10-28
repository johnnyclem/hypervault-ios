import SwiftUI

/// A fixed column for the symbol of a row. It is `width` points at the default text size and grows with the type, as
/// the symbol drawn in it does: a column that stays put while the symbol grows lets the symbol spill out of it, past
/// the margin of the row and onto the words.
struct HVIconSlot: ViewModifier {
    @ScaledMetric private var width: CGFloat

    init(width: CGFloat) {
        _width = ScaledMetric(wrappedValue: width, relativeTo: .body)
    }

    func body(content: Content) -> some View {
        content.frame(width: width)
    }
}

extension View {
    /// Sets the symbol of a row in a column of its own that scales with the type (see `HVIconSlot`).
    func hvIconSlot(_ width: CGFloat = 24) -> some View {
        modifier(HVIconSlot(width: width))
    }

    /// For a `Label` that is a row of a list or a card: a button, a link, a note. Up to the accessibility sizes it is
    /// the system's own label, untouched. From there the words are long enough to wrap, and the system sets the second
    /// line back under the symbol, so the symbols no longer make a column and the lines of one name do not start
    /// together. Here the symbol keeps a column of its own and every line of the words starts beside it.
    ///
    /// `role` is the role of the button the label is in. The system tints the symbol of a row in a list with the accent
    /// whatever the role and colours only the words of a destructive one, so the symbol and the words read as two
    /// intents. A destructive label asks for it here: both are `danger`, and the readable grey when the row is off.
    func hvRowLabel(role: ButtonRole? = nil) -> some View {
        modifier(HVRowLabelModifier(role: role))
    }
}

private struct HVRowLabelModifier: ViewModifier {
    let role: ButtonRole?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            inked(content.labelStyle(HVHangingLabelStyle()))
        } else {
            inked(content)
        }
    }

    @ViewBuilder
    private func inked<Inner: View>(_ content: Inner) -> some View {
        if role == .destructive {
            content.foregroundStyle(isEnabled ? AnyShapeStyle(Palette.danger) : AnyShapeStyle(Palette.textTertiary))
        } else {
            content
        }
    }
}

/// The symbol in its own column, scaled with the type, and the words beside it. The first line of the words sits on the
/// symbol's baseline and the lines after it start where it does. The symbol is decoration, as in the system's label.
private struct HVHangingLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: HV.Space.s) {
            configuration.icon
                .hvIconSlot(28)
                .accessibilityHidden(true)
            configuration.title
        }
    }
}
