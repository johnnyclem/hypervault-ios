import Foundation
import HyperVaultKit
import WidgetKit

/// One thing a widget shows. Never a key.
struct WidgetThing: Codable, Identifiable, Hashable {
    let id: String
    let kind: KeptKind
    let name: String
    let link: URL?
}

struct RecentEntry: TimelineEntry {
    enum State { case signedOut, empty, items([WidgetThing]) }

    let date: Date
    let state: State

    var things: [WidgetThing] {
        if case .items(let things) = state { return things }
        return []
    }

    static var sample: RecentEntry {
        RecentEntry(date: Date(), state: .items([
            WidgetThing(id: "1", kind: .page, name: "Bakery landing page", link: nil),
            WidgetThing(id: "2", kind: .memory, name: "Co-parenting schedule", link: nil),
            WidgetThing(id: "3", kind: .group, name: "Portfolio site", link: nil),
            WidgetThing(id: "4", kind: .page, name: "Trip to Lisbon", link: nil),
            WidgetThing(id: "5", kind: .memory, name: "Meeting notes", link: nil),
            WidgetThing(id: "6", kind: .page, name: "Pricing experiment", link: nil),
        ]))
    }
}

/// Reads what was kept most recently, with the session the app left in the shared Keychain, and
/// remembers the last good answer so a widget still has something to say offline.
enum WidgetData {
    private static let cacheKey = "hv.widget.recent"

    static func load() async -> RecentEntry.State {
        guard let (client, _) = SharedConfig.makeClient() else { return .signedOut }
        do {
            let list = try await client.send(.yours(filter: .all, limit: 12))
            let things = list.recent
                .filter { $0.kind != .key }
                .prefix(6)
                .map { WidgetThing(id: $0.id, kind: $0.kind, name: $0.name, link: $0.appLink) }
            let array = Array(things)
            remember(array)
            return array.isEmpty ? .empty : .items(array)
        } catch let error as HVError where error == .unauthorized {
            return .signedOut
        } catch {
            let cached = remembered()
            return cached.isEmpty ? .empty : .items(cached)
        }
    }

    private static func remember(_ things: [WidgetThing]) {
        SharedConfig.defaults.set(try? JSONEncoder().encode(things), forKey: cacheKey)
    }

    private static func remembered() -> [WidgetThing] {
        guard let data = SharedConfig.defaults.data(forKey: cacheKey) else { return [] }
        return (try? JSONDecoder().decode([WidgetThing].self, from: data)) ?? []
    }
}
