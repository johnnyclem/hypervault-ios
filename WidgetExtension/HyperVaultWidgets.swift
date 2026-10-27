import HyperVaultKit
import SwiftUI
import WidgetKit

// MARK: Recent

struct RecentProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecentEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (RecentEntry) -> Void) {
        if context.isPreview {
            completion(.sample)
        } else {
            Task { completion(RecentEntry(date: Date(), state: await WidgetData.load())) }
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecentEntry>) -> Void) {
        Task {
            let entry = RecentEntry(date: Date(), state: await WidgetData.load())
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60))))
        }
    }
}

struct RecentWidgetView: View {
    let entry: RecentEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch entry.state {
            case .signedOut:
                message("Open HyperVault to sign in.")
            case .locked:
                message("Locked. Open HyperVault to see what you kept.")
            case .empty:
                message("Nothing kept yet.")
            case .items(let things):
                list(things)
            }
        }
        .containerBackground(Palette.background, for: .widget)
    }

    private var limit: Int {
        switch family {
        case .systemSmall: return 3
        case .systemMedium: return 3
        case .systemLarge: return 6
        default: return 2
        }
    }

    private func list(_ things: [WidgetThing]) -> some View {
        VStack(alignment: .leading, spacing: family == .accessoryRectangular ? 2 : 8) {
            HStack(spacing: 6) {
                if family != .accessoryRectangular { BrandMark(size: 18) }
                Text("Yours.")
                    .font(.system(.footnote, weight: .bold))
                    .foregroundStyle(family == .accessoryRectangular ? Color.primary : Palette.textSecondary)
            }
            ForEach(things.prefix(limit)) { thing in
                if let link = thing.link, family != .systemSmall, family != .accessoryRectangular {
                    Link(destination: link) { row(thing) }
                } else {
                    row(thing)
                }
            }
            if family == .systemMedium || family == .systemLarge { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(URL(string: "hypervault://tab/yours"))
    }

    private func row(_ thing: WidgetThing) -> some View {
        HStack(spacing: 8) {
            if family != .accessoryRectangular {
                HVIconBadge(symbol: thing.kind.symbol, tint: thing.kind.tint, size: family == .systemSmall ? 22 : 28)
            }
            Text(thing.name)
                .font(.system(family == .accessoryRectangular ? .caption : .subheadline, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                // Names are redacted while the phone is locked, on the Lock Screen and in StandBy, whether or not the app lock is on.
                .privacySensitive()
            Spacer(minLength: 0)
        }
    }

    private func message(_ text: String) -> some View {
        VStack(spacing: 8) {
            BrandMark(size: 30)
            Text(text)
                .font(.system(.footnote, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetURL(URL(string: "hypervault://tab/canvas"))
    }
}

struct RecentWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "store.hypervault.recent", provider: RecentProvider()) { entry in
            RecentWidgetView(entry: entry)
        }
        .configurationDisplayName("Yours.")
        .description("What you kept most recently. Tap one to open it.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
    }
}

// MARK: Keep

struct KeepEntry: TimelineEntry {
    let date: Date
}

struct KeepProvider: TimelineProvider {
    func placeholder(in context: Context) -> KeepEntry { KeepEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (KeepEntry) -> Void) { completion(KeepEntry(date: Date())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<KeepEntry>) -> Void) {
        completion(Timeline(entries: [KeepEntry(date: Date())], policy: .never))
    }
}

struct KeepWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if family == .accessoryCircular {
                ZStack {
                    AccessoryWidgetBackground()
                    Text("H").font(.system(size: 24, weight: .semibold, design: .monospaced)).foregroundStyle(.primary)
                }
            } else if family == .accessoryInline {
                Label("Keep something", systemImage: "tray.and.arrow.down")
            } else {
                VStack(spacing: 10) {
                    BrandMark(size: 46)
                    Text("Keep something")
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .containerBackground(Palette.background, for: .widget)
        .widgetURL(URL(string: "hypervault://keep"))
    }
}

struct KeepWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "store.hypervault.keep", provider: KeepProvider()) { _ in
            KeepWidgetView()
        }
        .configurationDisplayName("Keep")
        .description("Open the canvas, ready to keep something.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryInline])
    }
}

@main
struct HyperVaultWidgetBundle: WidgetBundle {
    var body: some Widget {
        RecentWidget()
        KeepWidget()
    }
}
