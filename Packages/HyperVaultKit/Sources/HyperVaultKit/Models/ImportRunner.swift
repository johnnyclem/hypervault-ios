import Foundation

/// Everything an import will send, worked out up front so the screen can say
/// "340 conversations in 7 parts" before anything leaves the phone.
public struct ImportPlan: Sendable {
    public struct Item: Sendable {
        public let document: Int
        public let batch: ImportBatch
    }

    public let documents: [ImportDocument]
    public let items: [Item]
    /// Only a single pasted conversation takes a title (the route ignores it otherwise).
    public let title: String?

    public var conversationTotal: Int { items.reduce(0) { $0 + $1.batch.conversationCount } }

    public init(
        documents: [ImportDocument],
        title: String? = nil,
        maxBatchBytes: Int = ImportInspector.defaultBatchBytes,
        maxBatchConversations: Int = ImportInspector.defaultBatchConversations
    ) {
        self.documents = documents
        self.title = title
        var items: [Item] = []
        for (index, document) in documents.enumerated() where document.isImportable {
            for batch in document.batches(maxBytes: maxBatchBytes, maxConversations: maxBatchConversations) {
                items.append(Item(document: index, batch: batch))
            }
        }
        self.items = items
    }

    func request(document: ImportDocument, batch: ImportBatch) -> ImportRequest {
        ImportRequest(
            data: document.text(for: batch),
            platform: document.kind == .json ? document.platform : nil,
            title: batch.conversationCount == 1 ? title : nil
        )
    }
}

/// An import that stopped part way. Everything before `resumeAt` is in; running
/// again from there is safe (the route replaces a conversation it already has).
public struct ImportRunError: Error, Sendable {
    public let error: HVError
    /// The item to start from again.
    public let resumeAt: Int
    /// What the finished items added up to (a half-done item is counted when it is redone).
    public let totals: ImportTotals
    public let conversationsDone: Int

    public init(error: HVError, resumeAt: Int, totals: ImportTotals, conversationsDone: Int) {
        self.error = error
        self.resumeAt = resumeAt
        self.totals = totals
        self.conversationsDone = conversationsDone
    }

    public var userMessage: String { error.userMessage }
}

/// Sends a plan, batch by batch, adding up what the server says.
public enum ImportRunner {
    /// Whether a refusal means "this request was too heavy" (as opposed to
    /// "no" or "you are offline"): the route's body limit, or a gateway that
    /// gave up waiting on the 60-second route.
    static func isTooHeavy(_ error: HVError) -> Bool {
        guard let status = error.status else { return false }
        return status == 413 || status == 502 || status == 504
    }

    /// Runs `plan` from item `start`. A request the server finds too heavy is
    /// halved and tried again; one conversation too large on its own is counted
    /// as skipped and the run goes on. Any other failure stops the run with an
    /// `ImportRunError` that says where to pick up.
    public static func run(
        plan: ImportPlan,
        start: Int = 0,
        totals startingTotals: ImportTotals = ImportTotals(),
        send: @Sendable (ImportRequest) async throws -> ImportOutcome,
        progress: @Sendable (ImportProgress) -> Void = { _ in }
    ) async throws -> ImportTotals {
        var totals = startingTotals
        var sent = plan.items[..<min(start, plan.items.count)].reduce(0) { $0 + $1.batch.conversationCount }
        let total = plan.conversationTotal
        let itemTotal = plan.items.count

        func report(_ itemsDone: Int) {
            progress(ImportProgress(
                conversationsDone: sent, conversationsTotal: total,
                batchesDone: itemsDone, batchesTotal: itemTotal, totals: totals
            ))
        }
        report(start)

        for position in start..<max(start, plan.items.count) {
            let item = plan.items[position]
            let document = plan.documents[item.document]
            let totalsBefore = totals
            let sentBefore = sent
            var pending = [item.batch]

            func stop(_ error: HVError) -> ImportRunError {
                ImportRunError(error: error, resumeAt: position, totals: totalsBefore, conversationsDone: sentBefore)
            }

            while let batch = pending.popLast() {
                if Task.isCancelled { throw stop(.cancelled) }
                do {
                    let outcome = try await send(plan.request(document: document, batch: batch))
                    totals.add(outcome)
                    sent += batch.conversationCount
                    report(position)
                } catch let error as HVError {
                    guard isTooHeavy(error) else { throw stop(error) }
                    if let (first, second) = document.split(batch) {
                        pending.append(second)
                        pending.append(first)
                    } else if error.status == 413 {
                        // One conversation the route will not take: leave it out, go on.
                        totals.skipped += batch.conversationCount
                        totals.tooLarge += batch.conversationCount
                        sent += batch.conversationCount
                        report(position)
                    } else {
                        throw stop(error)
                    }
                } catch is CancellationError {
                    throw stop(.cancelled)
                }
            }
            report(position + 1)
        }
        return totals
    }
}
