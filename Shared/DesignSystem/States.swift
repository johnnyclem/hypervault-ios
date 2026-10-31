import SwiftUI

/// Nothing here yet, said warmly, with the next step when there is one.
struct HVEmptyState: View {
    let symbol: String
    let title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: HV.Space.m) {
            ZStack {
                Circle().fill(Palette.surfaceRaised).frame(width: 84, height: 84)
                Image(systemName: symbol)
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(Palette.textSecondary)
            }
            .accessibilityHidden(true)
            VStack(spacing: HV.Space.xs) {
                Text(title).font(.hvTitle3).multilineTextAlignment(.center)
                if let message {
                    Text(message)
                        .font(.hvCallout)
                        .foregroundStyle(Palette.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.hvGhost)
            }
        }
        .padding(HV.Space.xl)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
    }
}

/// An empty list said in one line, in a dashed box: the web's empty state for a pane (handoff 4.9). The line is the
/// whole message, so it should say what the list will hold and not only that it is empty.
struct HVEmptyBox: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.hvSubheadline)
            .foregroundStyle(Palette.textSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(HV.Space.wide)
            .overlay(
                RoundedRectangle(cornerRadius: HV.Radius.surface, style: .continuous)
                    .strokeBorder(Palette.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
    }
}

/// A load that failed, in the server's own words, with a way to try again.
struct HVErrorState: View {
    let message: String
    /// The glyph: a plain notice by default; pass `wifi.exclamationmark` for a connection that failed.
    var symbol = "exclamationmark.circle"
    var retryTitle = "Try again"
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: HV.Space.m) {
            ZStack {
                Circle().fill(Palette.surfaceRaised).frame(width: 84, height: 84)
                Image(systemName: symbol)
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(Palette.textSecondary)
            }
            .accessibilityHidden(true)
            Text(message)
                .font(.hvCallout)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
            if let retry {
                Button(retryTitle, action: retry).buttonStyle(.hvGhost)
            }
        }
        .padding(HV.Space.xl)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
    }
}

/// A spinner with an optional line under it.
struct HVLoadingState: View {
    var message: String?

    var body: some View {
        VStack(spacing: HV.Space.s) {
            ProgressView()
            if let message {
                Text(message).font(.hvFootnote).foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(HV.Space.xl)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// A placeholder block that breathes while content loads.
struct HVSkeleton: View {
    var height: CGFloat = 18
    var width: CGFloat?
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: height / 2.5, style: .continuous)
            .fill(Palette.skeleton)
            .frame(width: width, height: height)
            .opacity(dim ? 0.55 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
            }
            .accessibilityHidden(true)
    }
}

/// Rows of skeletons shaped like a list.
struct HVListSkeleton: View {
    var rows = 6
    @ScaledMetric private var scaledTile: CGFloat

    init(rows: Int = 6) {
        self.rows = rows
        _scaledTile = ScaledMetric(wrappedValue: HV.rowTile, relativeTo: .body)
    }

    var body: some View {
        let tile = HV.glyphBox(scaled: scaledTile, base: HV.rowTile)
        VStack(spacing: HV.Space.m) {
            ForEach(0..<rows, id: \.self) { _ in
                // The shape of an `HVRow`: a tile (`HV.rowTile`, 36, which grows with the type as the row's does), 12 to
                // the words, and a title line and a subtitle line that add up to the tile's height.
                HStack(spacing: HV.Space.s) {
                    HVSkeleton(height: tile, width: tile)
                    VStack(alignment: .leading, spacing: HV.Space.xs) {
                        HVSkeleton(height: 16, width: 176)
                        HVSkeleton(height: 12, width: 112)
                    }
                    Spacer()
                }
            }
        }
        .padding(.horizontal, HV.Space.m)
        .padding(.vertical, HV.Space.s)
        .accessibilityLabel("Loading")
    }
}

/// A one-line notice that what is on screen is the saved copy.
struct HVStaleBanner: View {
    var message = "Showing the saved copy"

    var body: some View {
        HStack(spacing: HV.Space.xs) {
            HVIcon("icloud.slash").font(.system(.caption, weight: .semibold))
            Text(message).font(.hvCaption)
        }
        .foregroundStyle(Palette.textSecondary)
        .padding(.horizontal, HV.Space.s)
        .padding(.vertical, 6)
        .background(Palette.surfaceRaised, in: Capsule())
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
