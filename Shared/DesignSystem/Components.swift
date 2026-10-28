import SwiftUI

// MARK: Buttons

private extension View {
    /// The box a filled button's label sits in: full width, at least 52pt high, with room above and below for a label
    /// that wraps at a large text size. A label of one line is shorter than the minimum by more than that room, so at
    /// the normal sizes the padding is not seen and the label stays centred as it was.
    func hvButtonLabelBox() -> some View {
        self
            .padding(.vertical, HV.Space.s)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, HV.Space.l)
    }
}

/// The one filled action on a screen. Full width, flat `primary`, 8pt corners and no glow, as the web's default button.
///
/// The label is bold on purpose: white on `primary` is 3.68:1, which is under the 4.5:1 body text needs and over the
/// 3:1 that bold text needs (a recorded exception, held by `DesignContrastTests`). Pressed is a dimmer fill, not a
/// spring, so there is nothing to turn off for Reduce Motion.
struct HVPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.hvButton)
            .foregroundStyle(isEnabled ? HVColor.primaryForeground : Palette.textSecondary)
            // A label that wraps at a large text size is centred in its box, not left on the first line's edge.
            .multilineTextAlignment(.center)
            .hvButtonLabelBox()
            // Off is a plain raised box with its label still readable, not the fill faded out.
            .background(isEnabled ? HVColor.primary : Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: HV.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: HV.Radius.control, style: .continuous).strokeBorder(isEnabled ? Color.clear : Palette.controlBorder, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// A quieter action beside the primary one: `muted` with a control border, the web's secondary button.
struct HVSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.hvHeadline)
            .foregroundStyle(isEnabled ? Palette.textPrimary : Palette.textTertiary)
            .multilineTextAlignment(.center)
            .hvButtonLabelBox()
            .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: HV.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: HV.Radius.control, style: .continuous).strokeBorder(Palette.controlBorder, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// The filled action that cannot be undone: the primary button in `destructive`, with white text as the web has it.
/// White on `destructive` is 3.76:1, so the label is bold here too.
struct HVDestructiveButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.hvButton)
            .foregroundStyle(isEnabled ? Color.white : Palette.textSecondary)
            .multilineTextAlignment(.center)
            .hvButtonLabelBox()
            .background(isEnabled ? HVColor.destructive : Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: HV.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: HV.Radius.control, style: .continuous).strokeBorder(isEnabled ? Color.clear : Palette.controlBorder, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// A text-only action.
struct HVGhostButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.subheadline, weight: .semibold))
            .foregroundStyle(ink(for: configuration.role))
            .padding(.horizontal, HV.Space.s)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.55 : 1)
    }

    private func ink(for role: ButtonRole?) -> AnyShapeStyle {
        if !isEnabled { return AnyShapeStyle(Palette.textTertiary) }
        return role == .destructive ? AnyShapeStyle(Palette.danger) : AnyShapeStyle(TintShapeStyle())
    }
}

/// A round icon button, for toolbars and the composer. Pressed is a small spring; with Reduce Motion on it is a dimmer
/// fill instead, as the other styles have it.
struct HVIconButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(prominent ? Color.white : Palette.textPrimary)
            .frame(width: 44, height: 44)
            .background(
                Circle().fill(prominent ? AnyShapeStyle(Palette.softGradient) : AnyShapeStyle(Palette.surfaceRaised))
            )
            .overlay(Circle().strokeBorder(prominent ? Color.white.opacity(0.18) : Palette.border, lineWidth: 1))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.85 : 1)
            .hvAnimation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == HVPrimaryButtonStyle {
    static var hvPrimary: HVPrimaryButtonStyle { HVPrimaryButtonStyle() }
}

extension ButtonStyle where Self == HVSecondaryButtonStyle {
    static var hvSecondary: HVSecondaryButtonStyle { HVSecondaryButtonStyle() }
}

extension ButtonStyle where Self == HVDestructiveButtonStyle {
    static var hvDestructive: HVDestructiveButtonStyle { HVDestructiveButtonStyle() }
}

extension ButtonStyle where Self == HVGhostButtonStyle {
    static var hvGhost: HVGhostButtonStyle { HVGhostButtonStyle() }
}

extension ButtonStyle where Self == HVIconButtonStyle {
    static var hvIcon: HVIconButtonStyle { HVIconButtonStyle() }
    static var hvIconProminent: HVIconButtonStyle { HVIconButtonStyle(prominent: true) }
}

// MARK: Surfaces

extension View {
    /// A card: paper with a hairline border.
    func hvCard(padding: CGFloat = HV.Space.m, radius: CGFloat = HV.Radius.card) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
    }

    /// Glass: for the composer, floating bars and sheets only. Lists and cards stay paper.
    func hvGlass(radius: CGFloat = HV.Radius.xl) -> some View {
        modifier(HVGlassModifier(shape: RoundedRectangle(cornerRadius: radius, style: .continuous)))
    }

    /// Glass in a shape of its own, a capsule say.
    func hvGlass<S: InsettableShape>(in shape: S) -> some View {
        modifier(HVGlassModifier(shape: shape))
    }

    /// The look of an input, as the web's `Input`: the page's own colour inside a control border, 8pt corners and at
    /// least 44pt high. Focus is a ring at half strength, and an invalid field is outlined in `destructive` (and says
    /// why in words beside it: colour is never the only sign).
    func hvFieldChrome(isFocused: Bool = false, isInvalid: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: HV.Radius.control, style: .continuous)
        let edge: Color = isInvalid ? HVColor.destructive : (isFocused ? HVColor.ring.opacity(0.5) : Palette.controlBorder)
        return self
            .padding(.horizontal, HV.Space.s)
            .padding(.vertical, HV.Space.s)
            .frame(minHeight: 44)
            .background(HVColor.background, in: shape)
            .overlay(shape.strokeBorder(edge, lineWidth: isFocused ? 2 : 1))
    }
}

/// Glass is `.glassEffect` on iOS 26. Under Reduce Transparency it is solid `card` with a border instead, since a
/// material that cannot be seen through is only a muddy fill.
struct HVGlassModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(HVColor.card, in: shape)
                .overlay(shape.strokeBorder(Palette.border, lineWidth: 1))
        } else {
            content.glassEffect(.regular, in: shape)
        }
    }
}

// MARK: Pieces

/// A small tinted icon in a rounded square: the leading mark of a row.
struct HVIconBadge: View {
    let symbol: String
    var tint: Color = Palette.blue
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A pill for filters and tags.
struct HVChip: View {
    let title: String
    var symbol: String?
    var isSelected = false
    /// The height of the area that answers a tap. The pill is shorter than a finger, so the room around it counts
    /// (nothing is drawn there); pass 0 where a chip is only drawn, never tapped.
    var minTarget: CGFloat = 44

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                HVIcon(symbol).font(.system(size: 12, weight: .semibold))
            }
            Text(title).font(.system(.subheadline, weight: .medium))
        }
        .foregroundStyle(isSelected ? Palette.background : Palette.textPrimary)
        .padding(.horizontal, HV.Space.m - 2)
        .padding(.vertical, 8)
        .background(
            Capsule().fill(isSelected ? AnyShapeStyle(Palette.textPrimary) : AnyShapeStyle(Palette.surfaceRaised))
        )
        .overlay(Capsule().strokeBorder(isSelected ? Color.clear : Palette.border, lineWidth: 1))
        .hvAnimation(.easeOut(duration: 0.15), value: isSelected)
        .frame(minHeight: minTarget)
        .contentShape(Rectangle())
    }
}

/// A small status tag ("Public", "Private", "Pro"), drawn as the web's status chips are: the colour as text, the same
/// colour at 10% as the fill and at 40% as the border. Pass `Palette.success` or `Palette.warning` (emerald-400 and
/// amber-400) for a state; the words always say what the colour means.
struct HVTag: View {
    let text: String
    var tint: Color = Palette.textSecondary
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // One line at its own width, except at an accessibility size, where "Agent connected" is wider than the screen:
        // a tag that will not wrap pushes the row it is in past the edges, and the row is cut off on both sides.
        let wraps = dynamicTypeSize.isAccessibilitySize
        Text(text)
            .font(.system(.caption, weight: .semibold))
            .foregroundStyle(tint)
            .lineLimit(wraps ? nil : 1)
            .fixedSize(horizontal: !wraps, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.10), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.4), lineWidth: 1))
    }
}

struct HVSectionHeader: View {
    let title: String
    var detail: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // At an accessibility size the title has the whole line and the detail sits under it: side by side the detail
        // and whatever else shares the row leave the title a sliver, and a word is broken in two ("Progr / ess").
        Group {
            if dynamicTypeSize.isAccessibilitySize, detail != nil {
                VStack(alignment: .leading, spacing: 2) {
                    titleText
                    detailText
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    titleText
                    Spacer(minLength: 0)
                    detailText
                }
            }
        }
        .accessibilityAddTraits(.isHeader)
    }

    // Sentence case in the foreground colour, as the web's section headings are. A List or Form upper-cases the text of a
    // section header by default; `textCase(nil)` hands it back.
    private var titleText: some View {
        Text(title)
            .font(.system(.subheadline, weight: .semibold))
            .foregroundStyle(HVColor.foreground)
            .textCase(nil)
    }

    @ViewBuilder
    private var detailText: some View {
        if let detail {
            Text(detail).font(.hvCaption).foregroundStyle(Palette.textTertiary).textCase(nil)
        }
    }
}

/// A person's initial in a coloured circle, or their photo when there is one.
struct HVAvatar: View {
    let name: String
    var imageURL: URL?
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            Circle().fill(Palette.avatarGradient)
            Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(.white)
            if let imageURL {
                AsyncImage(url: imageURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    }
                }
                .clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A row in a list of things: badge, title, subtitle, trailing detail.
struct HVRow<Trailing: View>: View {
    let symbol: String
    var tint: Color = Palette.blue
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        symbol: String,
        tint: Color = Palette.blue,
        title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: HV.Space.s + 2) {
            HVIconBadge(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.hvBody)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                }
            }
            Spacer(minLength: HV.Space.xs)
            trailing()
        }
        .contentShape(Rectangle())
    }
}

extension HVRow where Trailing == EmptyView {
    init(symbol: String, tint: Color = Palette.blue, title: String, subtitle: String? = nil) {
        self.init(symbol: symbol, tint: tint, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// The header of a sheet: a title, an optional subtitle and a close button.
struct HVSheetHeader: View {
    let title: String
    var subtitle: String?
    var onClose: (() -> Void)?

    var body: some View {
        HStack(alignment: .top) {
            // Never cut short: a sheet with the keyboard up is short, and a header squeezed to one line read
            // "Sign in wi..." at a large text size.
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.hvHeadline).fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .font(.hvSubheadline)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: HVSymbol.close)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: 30, height: 30)
                        .background(Palette.surfaceRaised, in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Close")
            }
        }
    }
}

/// A field with its label above it. A placeholder alone is not a label: it is faint and it goes the
/// moment someone types, so a form of several fields uses this.
struct HVLabeledField<Field: View>: View {
    let title: String
    var footnote: String?
    /// Pass the field's focus so its border shows the ring a bare `hvFieldChrome` would.
    var isFocused = false
    /// The field's value is refused: it is outlined in `destructive`, and the footnote (say what is wrong in it) is too.
    var isInvalid = false
    /// Whether the footnote is destructive, when that should differ from the field's edge: a footnote that states a rule
    /// stays plain while the field is refused for another reason (a name the server found taken). Nil follows `isInvalid`.
    var isFootnoteInvalid: Bool?
    @ViewBuilder var field: () -> Field

    var body: some View {
        VStack(alignment: .leading, spacing: HV.Space.hair) {
            Text(title)
                .font(.system(.footnote, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
            field().hvFieldChrome(isFocused: isFocused, isInvalid: isInvalid)
            if let footnote {
                Text(footnote)
                    .font(.hvFootnote)
                    .foregroundStyle((isFootnoteInvalid ?? isInvalid) ? HVColor.destructive : Palette.textSecondary)
            }
        }
    }
}

extension View {
    /// A list row on paper with a hairline between rows: the look every grouped or plain list shares.
    /// Without it a dark list takes the system's neutral grey, which sits wrong on the blue-black page.
    func hvListRow() -> some View {
        self
            .listRowBackground(Palette.surface)
            .listRowSeparatorTint(Palette.divider)
    }
}

extension Text {
    /// A field's hint in the tertiary grey. The system's own placeholder is under 2:1 on raised paper, so
    /// a field that has a label above it passes this as its `prompt:`.
    static func hvPrompt(_ text: String) -> Text {
        Text(text).foregroundStyle(Palette.textTertiary)
    }
}

