import SwiftUI

/// A count beside a name, or a short fact set the same way ("2 of 3 on", a plan): footnote size, monospaced digits so it
/// does not jitter as it changes, in `muted-foreground`. A count or a plan is quiet text, not a tag; `HVTag` is for a
/// status.
struct HVCount: View {
    let text: String

    init(_ value: Int) {
        self.text = "\(value)"
    }

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.footnote.monospacedDigit())
            .foregroundStyle(HVColor.mutedForeground)
    }
}

/// A filter, with its count when it has one (handoff 4.2): a 32pt capsule inside a 44pt area that answers a tap. The
/// selected one is `muted` with a `foreground` label in medium weight, and carries the selected trait, so it is never
/// colour alone; the others are `muted-foreground` on nothing. VoiceOver reads "<title>, <count>", or "<title>" alone
/// when there is no count. This is the one filter in the app: a chip that is not a filter is `HVChip`.
struct HVFilterPill: View {
    let title: String
    /// Nil draws no number and is not spoken ("All", "Open"); pass nil rather than 0 for a filter that has no count.
    var count: Int? = nil
    var isSelected = false
    let action: () -> Void

    init(title: String, count: Int? = nil, isSelected: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.count = count
        self.isSelected = isSelected
        self.action = action
    }

    /// What VoiceOver says: the title, then the count when there is one.
    static func spokenLabel(title: String, count: Int?) -> String {
        guard let count else { return title }
        return "\(title), \(count)"
    }

    var body: some View {
        Button {
            Haptics.select()
            action()
        } label: {
            HStack(spacing: HV.Space.hair) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(isSelected ? .medium : .regular)
                    .foregroundStyle(isSelected ? HVColor.foreground : HVColor.mutedForeground)
                if let count {
                    HVCount(count)
                }
            }
            .padding(.horizontal, HV.Space.s)
            // 32pt at the default size; it grows with the text rather than clipping it.
            .frame(minHeight: 32)
            .background(isSelected ? HVColor.muted : Color.clear, in: Capsule())
            // A short word with no count ("All") is narrower than a finger, so the room around it counts too.
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        // A default button would tint the label with the accent colour.
        .buttonStyle(.plain)
        .accessibilityLabel(Self.spokenLabel(title: title, count: count))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview("Filter pills") {
    ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: HV.Space.hair) {
            HVFilterPill(title: "All", count: 9, isSelected: true) {}
            HVFilterPill(title: "Logins", count: 4) {}
            HVFilterPill(title: "Cards", count: 2) {}
            HVFilterPill(title: "Contact info", count: 1) {}
            HVFilterPill(title: "Keys", count: 2) {}
        }
        .padding(.horizontal, HV.Space.m)
    }
    .hvScreenBackground()
}

#Preview("Filter pills, no count") {
    ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: HV.Space.hair) {
            HVFilterPill(title: "All", isSelected: true) {}
            HVFilterPill(title: "Open") {}
            HVFilterPill(title: "Unread", count: 3) {}
            HVFilterPill(title: "Done") {}
        }
        .padding(.horizontal, HV.Space.m)
    }
    .hvScreenBackground()
}
