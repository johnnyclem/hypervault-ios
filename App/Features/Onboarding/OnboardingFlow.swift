import HyperVaultKit
import SwiftUI

/// The first run: a short story about what HyperVault is, then the way in.
/// The words are lib/copy.ts's, verbatim (`HVCopy`), and the story never uses the
/// words a newcomer should not meet yet. When it says who can use a saved value it
/// names the agents that can read one, never a chat app, which can connect but not read.
struct OnboardingFlow: View {
    @Environment(AppModel.self) private var model
    @AppStorage(PrefKey.onboarded) private var onboarded = false
    @State private var page = 0
    /// The story plays until it has been seen once. After that, including after signing out, the way in comes first.
    @State private var showStory = !UserDefaults.standard.bool(forKey: PrefKey.onboarded)
    /// Back to the story is offered only on the visit that came through it.
    @State private var cameFromStory = false

    private let pageCount = 4

    var body: some View {
        ZStack {
            AuroraBackground()
            if showStory {
                story
                    .transition(.opacity)
            } else {
                SignInScreen(onBack: cameFromStory ? { HV.Motion.animate(HV.Motion.sheet) { showStory = true } } : nil)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            }
        }
    }

    private var story: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Skip") { finishStory() }
                    .buttonStyle(.hvGhost)
                    .opacity(page < pageCount - 1 ? 1 : 0)
                    .accessibilityIdentifier("welcome.skip")
            }
            .padding(.horizontal, HV.Space.m)
            .frame(height: 44)

            TabView(selection: $page) {
                WelcomePageKeep().tag(0)
                WelcomePageTalk(isCurrent: page == 1).tag(1)
                WelcomePageSecrets().tag(2)
                WelcomePageAnyAI().tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .onChange(of: page) { _, _ in Haptics.select() }

            VStack(spacing: HV.Space.m) {
                PageDots(count: pageCount, current: page)
                Button(page == pageCount - 1 ? "Get started" : "Continue") {
                    if page == pageCount - 1 {
                        finishStory()
                    } else {
                        HV.Motion.animate(HV.Motion.sheet) { page += 1 }
                    }
                }
                .buttonStyle(.hvPrimary)
                .accessibilityIdentifier("welcome.continue")
                if page == 0 {
                    Button("I already have an account") { finishStory() }
                        .buttonStyle(.hvGhost)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("welcome.haveAccount")
                } else {
                    // The height of the ghost button on page 1, so the dots and Continue stay where they are when the page turns.
                    Color.clear.frame(height: 44)
                }
            }
            .padding(.horizontal, HV.Space.l)
            .padding(.bottom, HV.Space.l)
            .hvReadableWidth()
        }
    }

    private func finishStory() {
        onboarded = true
        cameFromStory = true
        HV.Motion.animate(HV.Motion.sheet) { showStory = false }
    }
}

struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: HV.Space.hair) {
            ForEach(0..<count, id: \.self) { index in
                // Every dot is the same size; the page you are on is the one that takes the fill, so only a colour changes.
                Capsule()
                    .fill(index == current ? HVColor.primary : Palette.border)
                    .frame(width: HV.Space.xs, height: HV.Space.xs)
            }
        }
        .hvAnimation(HV.Motion.entrance, value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(current + 1) of \(count)")
        .accessibilityIdentifier("welcome.pages")
    }
}

// MARK: Pages

/// One page of the story: art on top, words below.
struct WelcomePage<Art: View>: View {
    let title: String
    let message: String
    @ViewBuilder var art: () -> Art
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // The page scrolls when the words need more room than the screen has (a small phone, a large text
        // size); the art gives way first, and goes entirely at accessibility sizes.
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: HV.Space.xl) {
                    if !dynamicTypeSize.isAccessibilitySize {
                        art()
                            .frame(height: min(300, max(140, proxy.size.height - 300)))
                            .frame(maxWidth: .infinity)
                    }
                    VStack(spacing: HV.Space.s) {
                        Text(title)
                            .font(.hvHero)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(message)
                            .font(.hvBody)
                            .foregroundStyle(Palette.textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, HV.Space.xl)
                }
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .hvReadableWidth()
    }
}

/// "Keep what your AI just made. Only you can open it."
struct WelcomePageKeep: View {
    var body: some View {
        WelcomePage(
            title: "Keep what your AI just made.",
            message: "Only you can open it."
        ) {
            ZStack {
                FloatingCard(symbol: "doc.richtext", label: "Pricing page", x: -74, y: -112)
                FloatingCard(symbol: "note.text", label: "Trip notes", x: 96, y: 90)
                FloatingCard(symbol: HVSymbol.key, label: "Deploy key", x: -84, y: 128)
                BrandMark(size: 104)
            }
        }
    }
}

/// A small card set beside the mark. It holds still.
struct FloatingCard: View {
    let symbol: String
    let label: String
    let x: CGFloat
    let y: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            HVTile(symbol: symbol, size: 28)
            Text(label).font(.system(.footnote, weight: .semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: HV.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: HV.Radius.card, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 14, x: 0, y: 8)
        .offset(x: x, y: y)
    }
}

/// "You talk to your AI like usual."
struct WelcomePageTalk: View {
    /// The two sentences of `HVCopy.productSentence`: the first is the title, the second the line under it.
    static let title = "You talk to your AI like usual."
    static let message = "HyperVault keeps the thing worth keeping, and you only see it when you ask for it."

    /// Whether this is the page the person is on. The pager may start a neighbouring page's task while it is only being
    /// pre-loaded, so the demo is keyed on this and plays when the person arrives. A page shown on its own is current.
    var isCurrent = true

    @State private var kept = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// What the demo depends on: it restarts when either one changes.
    private struct DemoKey: Equatable {
        let reduceMotion: Bool
        let isCurrent: Bool
    }

    var body: some View {
        WelcomePage(title: Self.title, message: Self.message) {
            VStack(alignment: .leading, spacing: HV.Space.s) {
                bubble("Make me a landing page for the bakery.", isUser: true)
                bubble("Done. Here it is.", isUser: false)
                HStack(spacing: HV.Space.s) {
                    HVIcon(kept ? "checkmark.seal.fill" : "seal")
                        .foregroundStyle(kept ? Palette.success : Palette.textTertiary)
                        .contentTransition(.symbolEffect(.replace))
                    Text(kept ? HVCopy.keptLine : HVCopy.keepingLine)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(kept ? Palette.textPrimary : Palette.textSecondary)
                }
                .padding(.horizontal, HV.Space.m)
                .padding(.vertical, HV.Space.s)
                .background(Palette.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(kept ? Palette.success.opacity(HV.Tint.border) : Palette.border, lineWidth: 1))
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.horizontal, HV.Space.xl)
            .task(id: DemoKey(reduceMotion: reduceMotion, isCurrent: isCurrent)) {
                // The demo plays once each time the person arrives on the page and then rests on the kept line; with
                // Reduce Motion on it shows that finished state from the start. Off the page it waits at the start.
                if reduceMotion {
                    kept = true
                    return
                }
                kept = false
                guard isCurrent else { return }
                try? await Task.sleep(nanoseconds: 1_100_000_000)
                guard !Task.isCancelled else { return }
                HV.Motion.animate { kept = true }
            }
        }
    }

    private func bubble(_ text: String, isUser: Bool) -> some View {
        Text(text)
            .font(.hvCallout)
            .foregroundStyle(isUser ? Color.white : Palette.textPrimary)
            .padding(.horizontal, HV.Space.m)
            .padding(.vertical, HV.Space.s)
            .background(
                RoundedRectangle(cornerRadius: HV.Radius.l, style: .continuous)
                    .fill(isUser ? Palette.action : Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HV.Radius.l, style: .continuous)
                    .strokeBorder(isUser ? Color.clear : Palette.border, lineWidth: 1)
            )
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }
}

/// "Save a login, a card, your contact info or an API key once." The rows show what stays visible after a save, a name
/// and a short label, and nothing else: the line above them says the rest is never shown again.
struct WelcomePageSecrets: View {
    var body: some View {
        WelcomePage(title: HVCopy.landingVaultSaveLine, message: HVCopy.landingVaultLockLine) {
            VStack(spacing: HV.Space.s) {
                // The tiles the Vault draws for a login, a card and a key.
                secretRow(title: "Bakery admin", label: "sam@bakery.co") { HVTile(monogram: "B") }
                secretRow(title: "Work card", label: "Visa \u{2022}\u{2022}\u{2022}\u{2022} 8317") {
                    HVCardBrandTile(brand: .visa).frame(width: 36, height: 36)
                }
                secretRow(title: "Deploy key", label: nil) { HVTile(symbol: HVSymbol.key) }
            }
            .padding(.horizontal, HV.Space.xl)
        }
    }

    private func secretRow<Tile: View>(title: String, label: String?, @ViewBuilder tile: () -> Tile) -> some View {
        HStack(spacing: HV.Space.s) {
            tile()
            VStack(alignment: .leading, spacing: HV.Space.xxs) {
                Text(title).font(.system(.subheadline, weight: .semibold))
                if let label { Text(label).font(.hvMono).foregroundStyle(Palette.textSecondary) }
            }
            Spacer()
        }
        .padding(HV.Space.m)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: HV.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: HV.Radius.card, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
    }
}

/// "Not tied to one AI company". The chips are the agents that can read a saved value, and only those.
struct WelcomePageAnyAI: View {
    var body: some View {
        WelcomePage(title: HVCopy.landingVaultHeading, message: HVCopy.landingVaultUseLine) {
            FlowLayout(spacing: HV.Space.s) {
                // Nothing here is selected or tappable: the agents that can read a saved value, all drawn the same.
                ForEach(HVCopy.landingVaultReaders, id: \.self) { name in
                    HVChip(title: name, minTarget: 0)
                }
            }
            .padding(.horizontal, HV.Space.xl)
        }
    }
}

/// Lays children out left to right and wraps to a new line, centred.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 320
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                widest = max(widest, x - spacing)
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        widest = max(widest, x - spacing)
        return CGSize(width: min(maxWidth, max(widest, 0)), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // First pass: group subviews into rows.
        var rows: [[Int]] = [[]]
        var widths: [CGFloat] = [0]
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let current = widths[widths.count - 1]
            if current + size.width > bounds.width, !rows[rows.count - 1].isEmpty {
                rows.append([])
                widths.append(0)
            }
            rows[rows.count - 1].append(index)
            widths[widths.count - 1] += size.width + spacing
        }
        var y = bounds.minY
        for (rowIndex, row) in rows.enumerated() {
            let rowWidth = widths[rowIndex] - spacing
            var x = bounds.minX + (bounds.width - rowWidth) / 2
            let sizes = row.map { subviews[$0].sizeThatFits(.unspecified) }
            let rowHeight = sizes.map(\.height).max() ?? 0
            for (position, index) in row.enumerated() {
                let size = sizes[position]
                // Centred on the row's line, so a short child (a label) shares a line with tall ones (the 44pt chips).
                subviews[index].place(at: CGPoint(x: x, y: y + (rowHeight - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += rowHeight + spacing
        }
    }
}
