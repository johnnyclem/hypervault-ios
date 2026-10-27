import SwiftUI

// MARK: Buttons

/// The one filled action on a screen. Full width, brand gradient.
struct HVPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded, weight: .semibold))
            .foregroundStyle(isEnabled ? Color.white : Palette.textSecondary)
            // A label that wraps at a large text size is centred in its capsule, not left on the first line's edge.
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, HV.Space.l)
            .background {
                // Off is a plain raised capsule with its label still readable, not the gradient faded out.
                if isEnabled {
                    Capsule().fill(Palette.softGradient)
                } else {
                    Capsule().fill(Palette.surfaceRaised)
                }
            }
            .overlay(Capsule().strokeBorder(isEnabled ? Color.white.opacity(0.18) : Palette.border, lineWidth: 1))
            .shadow(color: isEnabled ? Palette.blue.opacity(configuration.isPressed ? 0.15 : 0.32) : .clear, radius: 16, x: 0, y: 8)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

/// A quieter action beside the primary one.
struct HVSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded, weight: .semibold))
            .foregroundStyle(isEnabled ? Palette.textPrimary : Palette.textTertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, HV.Space.l)
            .background(Palette.surfaceRaised, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

/// A text-only action.
struct HVGhostButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.subheadline, design: .rounded, weight: .semibold))
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

/// A round icon button, for toolbars and the composer.
struct HVIconButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(prominent ? Color.white : Palette.textPrimary)
            .frame(width: 44, height: 44)
            .background(
                Circle().fill(prominent ? AnyShapeStyle(Palette.softGradient) : AnyShapeStyle(Palette.surfaceRaised))
            )
            .overlay(Circle().strokeBorder(prominent ? Color.white.opacity(0.18) : Palette.border, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == HVPrimaryButtonStyle {
    static var hvPrimary: HVPrimaryButtonStyle { HVPrimaryButtonStyle() }
}

extension ButtonStyle where Self == HVSecondaryButtonStyle {
    static var hvSecondary: HVSecondaryButtonStyle { HVSecondaryButtonStyle() }
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
    func hvCard(padding: CGFloat = HV.Space.m, radius: CGFloat = HV.Radius.l) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
    }

    /// Glass: for the composer, floating bars and sheets only. Lists and cards stay paper.
    func hvGlass(radius: CGFloat = HV.Radius.xl) -> some View {
        self
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Palette.border.opacity(0.7), lineWidth: 1))
    }

    /// The look of an input: raised paper, rounded, a hairline.
    func hvFieldChrome(isFocused: Bool = false) -> some View {
        self
            .padding(.horizontal, HV.Space.m)
            .padding(.vertical, HV.Space.s + 2)
            .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous)
                    .strokeBorder(isFocused ? Color.accentColor.opacity(0.7) : Palette.border, lineWidth: isFocused ? 1.5 : 1)
            )
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
            .foregroundStyle(tint.hvInk())
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
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
            }
            Text(title).font(.system(.subheadline, design: .rounded, weight: .medium))
        }
        .foregroundStyle(isSelected ? Palette.background : Palette.textPrimary)
        .padding(.horizontal, HV.Space.m - 2)
        .padding(.vertical, 8)
        .background(
            Capsule().fill(isSelected ? AnyShapeStyle(Palette.textPrimary) : AnyShapeStyle(Palette.surfaceRaised))
        )
        .overlay(Capsule().strokeBorder(isSelected ? Color.clear : Palette.border, lineWidth: 1))
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .frame(minHeight: minTarget)
        .contentShape(Rectangle())
    }
}

/// A small status tag ("Public", "Private", "Pro").
struct HVTag: View {
    let text: String
    var tint: Color = Palette.textSecondary
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // One line at its own width, except at an accessibility size, where "Agent connected" is wider than the screen:
        // a tag that will not wrap pushes the row it is in past the edges, and the row is cut off on both sides.
        let wraps = dynamicTypeSize.isAccessibilitySize
        Text(text)
            .font(.system(.caption2, design: .rounded, weight: .semibold))
            .foregroundStyle(tint.hvInk())
            .lineLimit(wraps ? nil : 1)
            .fixedSize(horizontal: !wraps, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

struct HVSectionHeader: View {
    let title: String
    var detail: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // At an accessibility size the title has the whole line and the detail sits under it: side by side the detail
        // and whatever else shares the row leave the title a sliver, and a word is broken in two ("PROGR / ESS").
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

    private var titleText: some View {
        Text(title)
            .font(.system(.footnote, design: .rounded, weight: .semibold))
            .foregroundStyle(Palette.textSecondary)
            .textCase(.uppercase)
            .tracking(0.6)
    }

    @ViewBuilder
    private var detailText: some View {
        if let detail {
            Text(detail).font(.hvCaption).foregroundStyle(Palette.textTertiary)
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
                .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
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
                Text(title).font(.hvTitle).fixedSize(horizontal: false, vertical: true)
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
                    Image(systemName: "xmark")
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
    @ViewBuilder var field: () -> Field

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(.footnote, design: .rounded, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
            field().hvFieldChrome(isFocused: isFocused)
            if let footnote {
                Text(footnote).font(.hvCaption).foregroundStyle(Palette.textSecondary)
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
            .listRowSeparatorTint(Palette.hairline)
    }
}

extension Text {
    /// A field's hint in the tertiary grey. The system's own placeholder is under 2:1 on raised paper, so
    /// a field that has a label above it passes this as its `prompt:`.
    static func hvPrompt(_ text: String) -> Text {
        Text(text).foregroundStyle(Palette.textTertiary)
    }
}

