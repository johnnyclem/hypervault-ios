import SwiftUI
import WidgetKit

// STUB: the real widgets arrive with the native extras.
struct PlaceholderEntry: TimelineEntry {
    let date: Date
}

struct PlaceholderProvider: TimelineProvider {
    func placeholder(in context: Context) -> PlaceholderEntry { PlaceholderEntry(date: Date()) }

    func getSnapshot(in context: Context, completion: @escaping (PlaceholderEntry) -> Void) {
        completion(PlaceholderEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PlaceholderEntry>) -> Void) {
        completion(Timeline(entries: [PlaceholderEntry(date: Date())], policy: .never))
    }
}

struct KeepWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "store.hypervault.keep", provider: PlaceholderProvider()) { _ in
            VStack {
                BrandMark(size: 40)
                Text("Keep").font(.hvHeadline)
            }
            .containerBackground(Palette.background, for: .widget)
            .widgetURL(URL(string: "hypervault://keep"))
        }
        .configurationDisplayName("Keep")
        .description("Open the canvas to keep something.")
        .supportedFamilies([.systemSmall])
    }
}

@main
struct HyperVaultWidgetBundle: WidgetBundle {
    var body: some Widget {
        KeepWidget()
    }
}
