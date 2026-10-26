import HyperVaultKit
import SwiftUI
import UIKit

/// The ledger page: which ledger, what is current in it, and the few things done
/// from it. The saved copy is shown first and the fresh one after.
@MainActor
@Observable
final class TruthModel {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var ledgers: [TruthLedger] = []
    private(set) var defaultSlug = "default"
    private(set) var activeSlug: String?
    private(set) var overview: TruthOverview?
    private(set) var isShowingSavedCopy = false
    private(set) var isCiteBusy = false

    @ObservationIgnored private let client: HVClient
    @ObservationIgnored private let cache: DiskCache
    @ObservationIgnored private let namespace: String
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var started = false

    init(client: HVClient, cache: DiskCache, namespace: String) {
        self.client = client
        self.cache = cache
        self.namespace = namespace
    }

    var active: TruthLedger? {
        if let activeSlug, let match = ledgers.first(where: { $0.slug == activeSlug }) { return match }
        return overview?.ledger
    }

    var sections: TruthSections { overview?.sections ?? TruthSections(standing: [], unverified: [], history: []) }

    static func sentence(_ error: Error) -> String {
        (error as? HVError)?.userMessage ?? error.localizedDescription
    }

    // MARK: Loading

    func start(preferring slug: String?) async {
        guard !started else { return }
        started = true
        await loadLedgers(preferring: slug)
        await loadOverview(quiet: false)
    }

    func refresh() async {
        await loadLedgers(preferring: activeSlug)
        await loadOverview(quiet: true)
    }

    private func loadLedgers(preferring slug: String?) async {
        let client = self.client
        do {
            let stream = cachedLoad(cache: cache, namespace: namespace, key: "truth.ledgers") { () async throws -> TruthLedgerList in
                try await client.send(.truthLedgers)
            }
            for try await loaded in stream {
                ledgers = loaded.value.ledgers
                defaultSlug = loaded.value.defaultSlug
                if activeSlug == nil || !ledgers.contains(where: { $0.slug == activeSlug }) {
                    activeSlug = loaded.value.choose(preferring: slug)?.slug
                }
                if loaded.isStale { isShowingSavedCopy = true }
            }
        } catch {
            if ledgers.isEmpty { phase = .failed(Self.sentence(error)) }
        }
    }

    private func loadOverview(quiet: Bool) async {
        if case .failed = phase, ledgers.isEmpty { return }
        generation += 1
        let mine = generation
        let client = self.client
        let slug = activeSlug
        if !quiet || overview == nil { phase = .loading }
        do {
            let stream = cachedLoad(cache: cache, namespace: namespace, key: "truth.overview.\(slug ?? "default")") { () async throws -> TruthOverview in
                try await client.send(.truth(ledger: slug))
            }
            for try await loaded in stream {
                guard mine == generation else { return }
                overview = loaded.value
                isShowingSavedCopy = loaded.isStale
                phase = .loaded
            }
        } catch {
            guard mine == generation else { return }
            if overview == nil || !quiet { phase = .failed(Self.sentence(error)) }
        }
    }

    func select(slug: String) async {
        guard slug != activeSlug else { return }
        activeSlug = slug
        overview = nil
        await loadOverview(quiet: false)
    }

    // MARK: Changing

    /// "Cite in chat": put the ledger at the head of every chat turn. Shown at once, put back if refused.
    func setCiteInChat(_ on: Bool) async throws {
        guard let current = overview else { return }
        isCiteBusy = true
        defer { isCiteBusy = false }
        overview = current.withChatTruth(on)
        do {
            _ = try await client.send(.citeTruthInChat(on))
        } catch {
            overview = current
            throw error
        }
    }

    /// A new ledger, then open it.
    func createLedger(slug: String, name: String, kind: TruthLedgerKind) async throws {
        let made = try await client.send(.createTruthLedger(slug: slug, name: name, kind: kind))
        ledgers.append(made.ledger)
        activeSlug = made.ledger.slug
        overview = nil
        let cache = self.cache
        let namespace = self.namespace
        let list = TruthLedgerList(defaultSlug: defaultSlug, ledgers: ledgers)
        Task { await cache.store(list, key: "truth.ledgers", namespace: namespace) }
        await loadOverview(quiet: false)
    }

    /// Drop an entry from a mirror ledger's copy (the stream keeps its lines).
    func removeEntry(_ id: String) async throws {
        _ = try await client.send(.deleteTruthEntry(id: id, ledger: activeSlug))
        await loadOverview(quiet: true)
    }

    /// The ledger's stream as a file, ready for the share sheet.
    func exportStream() async throws -> URL {
        let slug = active?.slug ?? activeSlug ?? "default"
        let data = try await client.send(.exportTruth(ledger: slug))
        return try TruthShareFile.write(data, named: TruthFiles.exportName(slug: slug))
    }

    func importStream(_ text: String) async throws -> TruthImportResult {
        let result = try await client.send(.importTruth(jsonl: text, ledger: activeSlug))
        await loadOverview(quiet: true)
        return result
    }

    func importPage(slug: String?, jsonl: String?) async throws -> TruthPageImportResult {
        let result = try await client.send(.importTruthPage(slug: slug, jsonl: jsonl, ledger: activeSlug))
        await loadOverview(quiet: true)
        return result
    }

    /// Something was written elsewhere (an assertion, a decision): read the ledger again.
    func changed() async {
        await loadOverview(quiet: true)
    }
}

extension TruthOverview {
    /// A copy with the "cite in chat" switch changed.
    func withChatTruth(_ on: Bool) -> TruthOverview {
        TruthOverview(
            ledger: ledger, summary: summary, asOf: asOf, chatTruth: on, sidecar: sidecar, docket: docket, review: review,
            citable: citable, flags: flags, displaced: displaced, entries: entries
        )
    }
}

/// Files made for the share sheet live in the temporary folder, under their own names.
enum TruthShareFile {
    static func write(_ data: Data, named name: String) throws -> URL {
        // What an earlier export left behind, never shared or never cleared.
        PrivateTemporaryFiles.removeStale(prefix: "hv-share-")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hv-share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }
}

struct TruthSharedFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// UIKit's share sheet, for a file the app just made.
struct TruthActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
