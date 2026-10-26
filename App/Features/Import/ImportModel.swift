import HyperVaultKit
import SwiftUI
import UIKit

/// Keeps the screen awake while at least one import is sending. Each run takes one hold and gives it back
/// exactly once, when it ends however it ends, so a run that outlives its screen cannot leave the timer off,
/// and a run that ends cannot switch it back on under a newer one.
@MainActor
enum ImportAwake {
    private(set) static var holds = 0

    static func hold() {
        holds += 1
        UIApplication.shared.isIdleTimerDisabled = true
    }

    static func release() {
        holds = max(0, holds - 1)
        if holds == 0 { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

/// What a screen would strand if it were dropped part way through an import: the run, and the temporary copies
/// of an export that hold the person's whole history. The model holds this alone, so it goes when the model
/// does: the run is cancelled and the copies are removed. A tab switch keeps the screen, and so the import.
private final class ImportLeftovers {
    var task: Task<Void, Never>?
    var files: [URL] = []

    deinit {
        task?.cancel()
        ImportFileReader.remove(files)
    }
}

/// The Import screen's state, from "which service?" to "all in". Reading a
/// file, sending it in parts and picking up after a failure all live here.
@MainActor
@Observable
final class ImportModel {
    enum Stage: Equatable {
        case choose
        case reading
        case review
        case sending
        case done
        /// Stopped part way (a failure, or the person stopped it).
        case stopped(String)
    }

    private(set) var stage: Stage = .choose
    var source: ImportPlatform?
    var pasted = ""
    var pasteTitle = ""
    private(set) var documents: [ImportDocument] = []
    private(set) var notes: [String] = []
    private(set) var readError: String?
    private(set) var plan: ImportPlan?
    private(set) var progress: ImportProgress?
    private(set) var totals = ImportTotals()
    private(set) var resumeAt = 0
    private(set) var startedAt: Date?

    @ObservationIgnored private let client: HVClient
    @ObservationIgnored private let limit: Int
    @ObservationIgnored private let announcer: SpeechAnnouncer
    @ObservationIgnored private let leftovers = ImportLeftovers()

    private var temporaryFiles: [URL] {
        get { leftovers.files }
        set { leftovers.files = newValue }
    }

    private var task: Task<Void, Never>? {
        get { leftovers.task }
        set { leftovers.task = newValue }
    }

    init(client: HVClient, importBytes: Int, announcer: SpeechAnnouncer = VoiceOverAnnouncer.shared) {
        self.client = client
        self.limit = importBytes
        self.announcer = announcer
    }

    // MARK: Review

    var conversationCount: Int { documents.reduce(0) { $0 + $1.conversationCount } }
    var totalBytes: Int { documents.reduce(0) { $0 + $1.byteCount } }
    var platform: ImportPlatform { documents.first?.platform ?? source ?? .other }
    var sampleTitles: [String] { Array(documents.flatMap(\.sampleTitles).prefix(3)) }
    var partCount: Int { plan?.items.count ?? 0 }
    var mismatchedChoice: ImportPlatform? {
        documents.first(where: \.disagrees).flatMap { $0.chosen }
    }

    /// What to call the file in the review: its name, or "3 files" for several.
    var fileName: String? {
        guard !isPaste, let first = documents.first, !first.name.isEmpty else { return nil }
        return documents.count > 1 ? "\(documents.count) files" : first.name
    }

    /// A pasted transcript is a single conversation and can be titled.
    var isPaste: Bool { documents.first?.kind == .transcript }

    // MARK: Reading

    func read(_ urls: [URL]) {
        guard stage == .choose || stage == .review || isStoppedOrDone else { return }
        reset(keepSource: true)
        stage = .reading
        let chosen = source
        task = Task {
            do {
                let result = try await ImportFileReader.read(urls, chosen: chosen)
                finishReading(result)
            } catch is CancellationError {
                stage = .choose
            } catch {
                readError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                stage = .choose
            }
        }
    }

    /// Pasted text is read as a transcript (or as JSON, if that is what was pasted).
    func readPasted() {
        let text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        reset(keepSource: true)
        let document = ImportInspector.inspect(text: text, hint: source)
        finishReading(ImportReadResult(documents: [document]))
    }

    private func finishReading(_ result: ImportReadResult) {
        documents = result.documents
        notes = result.notes
        temporaryFiles = result.temporaryFiles
        let importable = documents.filter(\.isImportable)
        if importable.isEmpty {
            // Nothing will be sent, so nothing is kept.
            cleanUp()
            readError = ImportInspector.nothingFoundMessage
            plan = nil
            stage = documents.isEmpty ? .choose : .review
            return
        }
        readError = nil
        plan = makePlan()
        stage = .review
    }

    private func makePlan() -> ImportPlan {
        ImportPlan(
            documents: documents,
            title: isPaste ? pasteTitle : nil,
            maxBatchBytes: min(limit, ImportInspector.defaultBatchBytes)
        )
    }

    func backToChoose() {
        reset(keepSource: true)
    }

    // MARK: Sending

    func start() {
        guard stage == .review, plan != nil else { return }
        plan = makePlan()
        totals = ImportTotals()
        resumeAt = 0
        run(from: 0)
        let count = conversationCount
        announcer.announce("Importing \(count) conversation\(count == 1 ? "" : "s"). Keep HyperVault open.")
    }

    /// Picks up where a stopped import left off.
    func resume() {
        guard case .stopped = stage else { return }
        run(from: resumeAt)
        announcer.announce("Continuing the import. Keep HyperVault open.")
    }

    func stop() {
        task?.cancel()
    }

    private func run(from start: Int) {
        guard let plan else { return }
        stage = .sending
        startedAt = startedAt ?? Date()
        ImportAwake.hold()
        let client = self.client
        let startingTotals = totals
        // The run holds the model weakly: a screen that is gone stops it (see ImportLeftovers), and what ends
        // it, with or without a model to tell, gives the screen back its sleep.
        task = Task { [weak self] in
            let grace = ToolsBackgroundGrace(name: "Import history")
            defer {
                grace.end()
                ImportAwake.release()
            }
            do {
                let finished = try await ImportRunner.run(
                    plan: plan, start: start, totals: startingTotals,
                    send: { request in try await client.send(.importHistory(request)) },
                    progress: { update in Task { @MainActor in self?.progress = update } }
                )
                self?.finish(finished)
            } catch let stop as ImportRunError {
                self?.halt(stop)
            } catch {
                self?.halt(ImportRunError(
                    error: (error as? HVError) ?? .transport(error.localizedDescription),
                    resumeAt: start, totals: startingTotals, conversationsDone: 0
                ))
            }
        }
    }

    private func finish(_ finished: ImportTotals) {
        totals = finished
        stage = .done
        Haptics.success()
        cleanUp()
        announcer.announce("Import finished. \(finished.summary(platform: platform))")
    }

    private func halt(_ stop: ImportRunError) {
        totals = stop.totals
        resumeAt = stop.resumeAt
        progress = ImportProgress(
            conversationsDone: stop.conversationsDone,
            conversationsTotal: plan?.conversationTotal ?? 0,
            batchesDone: stop.resumeAt, batchesTotal: plan?.items.count ?? 0, totals: stop.totals
        )
        let total = plan?.conversationTotal ?? 0
        let progressSentence = "\(stop.totals.imported) of \(total) conversations are in. You can continue it."
        if case .cancelled = stop.error {
            stage = .stopped("You stopped the import.")
            announcer.announce("Import stopped. \(progressSentence)")
        } else {
            stage = .stopped(stop.userMessage)
            Haptics.failure()
            announcer.announce("The import stopped. \(stop.userMessage) \(progressSentence)")
        }
    }

    // MARK: Reset

    private var isStoppedOrDone: Bool {
        switch stage {
        case .stopped, .done: return true
        default: return false
        }
    }

    func startOver() {
        reset(keepSource: false)
    }

    private func reset(keepSource: Bool) {
        task?.cancel()
        task = nil
        cleanUp()
        documents = []
        notes = []
        plan = nil
        progress = nil
        totals = ImportTotals()
        resumeAt = 0
        startedAt = nil
        readError = nil
        stage = .choose
        if !keepSource { source = nil; pasted = ""; pasteTitle = "" }
    }

    private func cleanUp() {
        ImportFileReader.remove(temporaryFiles)
        temporaryFiles = []
    }
}

#if DEBUG
extension ImportModel {
    /// Skips the file picker: the documents are as if just read.
    func previewSeedDocuments(_ seeded: [ImportDocument]) {
        finishReading(ImportReadResult(documents: seeded))
    }

    /// Puts the screen in a state a preview or a snapshot can show.
    func previewSeed(_ seed: ImportPreviewHost.Seed) {
        source = .chatgpt
        switch seed {
        case .choose:
            break
        case .paste:
            source = .other
        case .review, .sending, .done, .stopped:
            let history = ImportInspector.inspect(Data(ImportFixtures.chatgpt(count: 340).utf8), name: "conversations.json", hint: .chatgpt)
            documents = [history]
            notes = ["Looked through 9 JSON files in export.zip and used 1."]
            plan = ImportPlan(documents: documents, maxBatchBytes: 600_000)
            stage = .review
            guard seed != .review else { return }
            let total = plan?.conversationTotal ?? 0
            switch seed {
            case .sending:
                progress = ImportProgress(conversationsDone: 120, conversationsTotal: total, batchesDone: 2, batchesTotal: plan?.items.count ?? 0, totals: ImportTotals())
                stage = .sending
            case .done:
                var finished = ImportTotals()
                finished.add(ImportOutcome(platform: .chatgpt, imported: total - 3, skipped: 3, messages: 4_120))
                totals = finished
                stage = .done
            default:
                var partial = ImportTotals()
                partial.add(ImportOutcome(platform: .chatgpt, imported: 120, skipped: 0, messages: 1_480))
                totals = partial
                progress = ImportProgress(conversationsDone: 120, conversationsTotal: total, batchesDone: 2, batchesTotal: plan?.items.count ?? 0, totals: partial)
                stage = .stopped("The server had a problem. Try again in a moment.")
            }
        case .nothing:
            documents = [ImportInspector.inspect(Data(#"{"user":{"userId":"u"},"sessions":[]}"#.utf8), name: "prodmcauthmgmtapi.json")]
            notes = ["Looked through 3 JSON files in x-archive.zip and found no conversations."]
            plan = nil
            stage = .review
        }
    }
}

enum ImportFixtures {
    /// What people actually ask, so the review screen shows titles that read like a history and not a counter.
    private static let titles = [
        "Planning a week in Lisbon", "Fix my cover letter", "Why is my sourdough flat?", "SQL window functions, explained",
        "Names for a bakery", "Tax receipts checklist", "Rust lifetimes, again", "A toast for Dad's 60th",
        "Weekend hike near Boulder", "Rewrite this email, politely", "Compare standing desks", "Garden bed layout for shade",
        "Practice Spanish: ordering food", "Debug a flaky CI test", "Summarise this contract", "Birthday ideas for a ten-year-old",
        "How does a heat pump work?", "Draft a project update", "Meal prep for a busy week", "Photo editing basics",
        "Learn chess openings", "Budget for a kitchen remodel", "Explain compound interest", "Gift ideas under fifty dollars",
    ]

    /// ChatGPT-shaped conversations, enough to make several parts.
    static func chatgpt(count: Int) -> String {
        let items = (0..<count).map { i in
            #"{"title":"\#(titles[i % titles.count])","conversation_id":"c\#(i)","current_node":"a","mapping":{"a":{"id":"a","message":null,"parent":null,"children":[]}},"pad":"\#(String(repeating: "x", count: 4_000))"}"#
        }
        return "[" + items.joined(separator: ",") + "]"
    }
}
#endif
