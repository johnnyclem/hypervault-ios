import HyperVaultKit
import SwiftUI

/// The first run: a short story about what HyperVault is, then the way in.
/// The words are the web app's (lib/copy.ts), and the story never uses the
/// words a newcomer should not meet yet.
struct OnboardingFlow: View {
    @Environment(AppModel.self) private var model
    @AppStorage(PrefKey.onboarded) private var onboarded = false
    @State private var page = 0
    @State private var showSignIn = false

    private let pageCount = 4

    var body: some View {
        ZStack {
            AuroraBackground()
            if showSignIn || onboarded {
                SignInScreen(onBack: onboarded ? nil : { withAnimation(.snappy) { showSignIn = false } })
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            } else {
                story
                    .transition(.opacity)
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
            }
            .padding(.horizontal, HV.Space.m)
            .frame(height: 44)

            TabView(selection: $page) {
                WelcomePageKeep().tag(0)
                WelcomePageTalk().tag(1)
                WelcomePageAnyAI().tag(2)
                WelcomePageSecrets().tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .onChange(of: page) { _, _ in Haptics.select() }

            VStack(spacing: HV.Space.m) {
                PageDots(count: pageCount, current: page)
                Button(page == pageCount - 1 ? "Get started" : "Continue") {
                    if page == pageCount - 1 {
                        finishStory()
                    } else {
                        withAnimation(.snappy) { page += 1 }
                    }
                }
                .buttonStyle(.hvPrimary)
                if page == 0 {
                    Button("I already have an account") { finishStory() }
                        .buttonStyle(.hvGhost)
                } else {
                    Color.clear.frame(height: 36)
                }
            }
            .padding(.horizontal, HV.Space.l)
            .padding(.bottom, HV.Space.l)
            .hvReadableWidth()
        }
    }

    private func finishStory() {
        withAnimation(.snappy) { showSignIn = true }
    }
}

struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Color.accentColor : Palette.border)
                    .frame(width: index == current ? 22 : 7, height: 7)
            }
        }
        .animation(.snappy, value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(current + 1) of \(count)")
    }
}

// MARK: Pages

/// One page of the story: art on top, words below.
struct WelcomePage<Art: View>: View {
    let title: String
    let message: String
    @ViewBuilder var art: () -> Art

    var body: some View {
        VStack(spacing: HV.Space.xl) {
            Spacer(minLength: 0)
            art()
                .frame(height: 260)
                .frame(maxWidth: .infinity)
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
            Spacer(minLength: 0)
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
                FloatingCard(symbol: "doc.richtext", label: "Pricing page", tint: Palette.blue, x: -96, y: -64, phase: 0)
                FloatingCard(symbol: "note.text", label: "Trip notes", tint: Palette.violet, x: 100, y: -30, phase: 1.3)
                FloatingCard(symbol: "key.horizontal", label: "Deploy key", tint: Palette.mint, x: -70, y: 78, phase: 2.1)
                BrandMark(size: 104)
            }
        }
    }
}

/// A small card drifting around the mark.
struct FloatingCard: View {
    let symbol: String
    let label: String
    let tint: Color
    let x: CGFloat
    let y: CGFloat
    let phase: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate + phase
            HStack(spacing: 8) {
                HVIconBadge(symbol: symbol, tint: tint, size: 28)
                Text(label).font(.system(.footnote, design: .rounded, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Palette.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 14, x: 0, y: 8)
            .offset(x: x + CGFloat(sin(t / 1.6)) * 6, y: y + CGFloat(cos(t / 1.9)) * 7)
        }
    }
}

/// "You talk to your AI like usual."
struct WelcomePageTalk: View {
    @State private var kept = false

    var body: some View {
        WelcomePage(
            title: "You talk to your AI like usual.",
            message: "HyperVault keeps the thing worth keeping. You only see it when you ask for it."
        ) {
            VStack(alignment: .leading, spacing: HV.Space.s) {
                bubble("Make me a landing page for the bakery.", isUser: true)
                bubble("Done. Here it is.", isUser: false)
                HStack(spacing: HV.Space.s) {
                    Image(systemName: kept ? "checkmark.seal.fill" : "seal")
                        .foregroundStyle(kept ? Palette.success : Palette.textTertiary)
                        .contentTransition(.symbolEffect(.replace))
                    Text(kept ? "Kept. Here's the link." : "Keeping…")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(kept ? Palette.textPrimary : Palette.textSecondary)
                }
                .padding(.horizontal, HV.Space.m)
                .padding(.vertical, HV.Space.s)
                .background(Palette.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(kept ? Palette.success.opacity(0.5) : Palette.border, lineWidth: 1))
                .scaleEffect(kept ? 1 : 0.96)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.horizontal, HV.Space.xl)
            .task {
                while !Task.isCancelled {
                    kept = false
                    try? await Task.sleep(nanoseconds: 1_100_000_000)
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { kept = true }
                    try? await Task.sleep(nanoseconds: 2_600_000_000)
                }
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
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isUser ? AnyShapeStyle(Palette.softGradient) : AnyShapeStyle(Palette.surface))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(isUser ? Color.clear : Palette.border, lineWidth: 1)
            )
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }
}

/// "Not tied to one AI company."
struct WelcomePageAnyAI: View {
    private let names = ["Claude", "ChatGPT", "Gemini", "Grok", "Cursor", "Codex", "Claude Code", "n8n", "curl"]

    var body: some View {
        WelcomePage(
            title: "Not tied to one AI company.",
            message: "Whatever you use to talk to AI keeps to the same place."
        ) {
            FlowLayout(spacing: HV.Space.s) {
                ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                    HVChip(title: name, isSelected: index % 4 == 0)
                }
            }
            .padding(.horizontal, HV.Space.xl)
        }
    }
}

/// "Save a login, a card or a key once."
struct WelcomePageSecrets: View {
    var body: some View {
        WelcomePage(
            title: "Save a login, a card or a key once.",
            message: "The secret parts are never shown again. Your agents use only the ones you allow."
        ) {
            VStack(spacing: HV.Space.s) {
                secretRow(symbol: "person.crop.circle", tint: Palette.blue, title: "Bakery admin", detail: "sam@bakery.co · ••••••••", allowed: "Claude Code")
                secretRow(symbol: "creditcard", tint: Palette.violet, title: "Work card", detail: "Visa •••• 4242", allowed: "Cursor")
                secretRow(symbol: "key.horizontal", tint: Palette.mint, title: "Deploy key", detail: "hv_••••••••••••", allowed: "n8n")
            }
            .padding(.horizontal, HV.Space.xl)
        }
    }

    private func secretRow(symbol: String, tint: Color, title: String, detail: String, allowed: String) -> some View {
        HStack(spacing: HV.Space.s + 2) {
            HVIconBadge(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(.subheadline, design: .rounded, weight: .semibold))
                Text(detail).font(.hvMono).foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            HVTag(text: allowed, tint: tint)
        }
        .padding(HV.Space.s + 2)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: HV.Radius.m, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
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
            var rowHeight: CGFloat = 0
            for index in row {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
                rowHeight = max(rowHeight, size.height)
            }
            y += rowHeight + spacing
        }
    }
}
