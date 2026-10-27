import HyperVaultKit
import SwiftUI

/// What Yours lists, in the panel on Home: the four quiet filters, a
/// search by name, and the head of the list in the order things were last used.
@MainActor
@Observable
final class YoursModel {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var recent: [KeptItem] = []
    private(set) var results: [KeptItem] = []
    /// What is on screen is the saved copy, because the refresh did not get through.
    private(set) var isStale = false
    var filter: YoursFilter = .all
    var query = ""

    @ObservationIgnored private let client: HVClient
    @ObservationIgnored private let cache: DiskCache
    @ObservationIgnored private let namespace: String

    /// The most the list reads at once; a search finds the rest.
    static let pageLimit = 50

    init(client: HVClient, cache: DiskCache, namespace: String) {
        self.client = client
        self.cache = cache
        self.namespace = namespace
    }

    var isSearching: Bool { !trimmedQuery.isEmpty }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    /// Items after the Recent head, when the list is the plain, unfiltered one.
    var everythingElse: [KeptItem] {
        guard !isSearching, filter == .all else { return results }
        let head = Set(recent.map(\.id))
        return results.filter { !head.contains($0.id) }
    }

    var isEmptyVault: Bool { phase == .loaded && results.isEmpty && !isSearching && filter == .all }

    /// Loads for the current filter and query. A search waits a beat so typing does not fire a request per letter.
    func reload() async {
        let filter = self.filter
        let text = trimmedQuery
        if text.isEmpty {
            await loadCached(filter)
        } else {
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                let list = try await client.send(.yours(filter: filter, query: text, limit: Self.pageLimit))
                guard filter == self.filter, text == trimmedQuery else { return }
                apply(list, stale: false)
            } catch is CancellationError {
                return
            } catch HVError.cancelled {
                // Typing again replaced this search; the newer one says what it finds.
                return
            } catch {
                fail(error)
            }
        }
    }

    private func loadCached(_ filter: YoursFilter) async {
        let client = self.client
        let stream = cachedLoad(cache: cache, namespace: namespace, key: "yours.\(filter.rawValue)") {
            try await client.send(.yours(filter: filter, limit: Self.pageLimit))
        }
        do {
            for try await loaded in stream {
                guard filter == self.filter, trimmedQuery.isEmpty else { return }
                apply(loaded.value, stale: loaded.isStale && loaded.refreshError != nil)
            }
        } catch is CancellationError {
            return
        } catch HVError.cancelled {
            return
        } catch {
            fail(error)
        }
    }

    private func apply(_ list: YoursList, stale: Bool) {
        recent = list.recent
        results = list.results
        isStale = stale
        phase = .loaded
        // The unfiltered list is the whole of what is kept: it is what system search is given.
        if filter == .all, !isSearching, !stale {
            SpotlightIndexer.index(list.results)
            WidgetRefresh.reload()
        }
    }

    private func fail(_ error: Error) {
        // With something already on screen, keep it and say it is old.
        if phase == .loaded {
            isStale = true
        } else {
            phase = .failed((error as? HVError)?.isOffline == true ? HVCopy.yoursOfflineLine : ((error as? HVError)?.userMessage ?? HVCopy.yoursFailedLine))
        }
    }

    func retry() async {
        phase = .loading
        await reload()
    }

    /// Records an open so Recent follows what was gone back to. Best effort.
    func markOpened(_ item: KeptItem) {
        let client = self.client
        Task { _ = try? await client.send(.markOpened(kind: item.kind, id: item.id)) }
    }
}
