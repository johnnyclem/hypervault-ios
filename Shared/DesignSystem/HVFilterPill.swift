import SwiftUI

/// A count beside a name: footnote size, monospaced digits so it does not jitter as it changes, in `muted-foreground`.
struct HVCount: View {
    let value: Int

    init(_ value: Int) {
        self.value = value
    }

    var body: some View {
        Text("\(value)")
            .font(.footnote.monospacedDigit())
            .foregroundStyle(HVColor.mutedForeground)
    }
}

/// A filter with its count (handoff 4.2): a 32pt capsule inside a 44pt area that answers a tap. The selected one is
/// `muted` with a `foreground` label in medium weight, and carries the selected trait, so it is never colour alone;
/// the others are `muted-foreground` on nothing. VoiceOver reads "<title>, <count>".
struct HVFilterPill: View {
    let title: String
    let count: Int
    var isSelected = false
    let action: () -> Void

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
                HVCount(count)
            }
            .padding(.horizontal, HV.Space.s)
            // 32pt at the default size; it grows with the text rather than clipping it.
            .frame(minHeight: 32)
            .background(isSelected ? HVColor.muted : Color.clear, in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        // A default button would tint the label with the accent colour.
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count)")
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
