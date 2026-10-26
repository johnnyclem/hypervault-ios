import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

/// Shapes are the web importers' own (lib/imports/*.ts); the route is app/api/import/route.ts.
final class ImportTests: XCTestCase {
    // MARK: Fixtures

    /// lib/imports/chatgpt.ts: a tree in `mapping`, the visible thread ends at `current_node`.
    /// The first title holds characters that trip up a naive scanner.
    let chatgpt = """
    [{"title":"Trip \\"planning\\" [draft], part 1","create_time":1727000000.5,"update_time":1727000500,"conversation_id":"c-1","current_node":"n2","default_model_slug":"gpt-4o",
      "mapping":{"n0":{"id":"n0","message":null,"parent":null,"children":["n1"]},
                 "n1":{"id":"n1","message":{"author":{"role":"user"},"content":{"content_type":"text","parts":["Where in May? ]}, \\\\"]}},"parent":"n0","children":["n2"]},
                 "n2":{"id":"n2","message":{"author":{"role":"assistant"},"content":{"content_type":"text","parts":["Lisbon."]}},"parent":"n1","children":[]}}},
     {"title":"Fix my regex","conversation_id":"c-2","current_node":"m1","mapping":{"m1":{"id":"m1","message":null,"parent":null,"children":[]}}}]
    """

    /// lib/imports/claude.ts
    let claude = """
    [{"uuid":"u-1","name":"Meal plan","created_at":"2026-05-01T10:00:00.000000+00:00","chat_messages":[{"uuid":"m","sender":"human","text":"Plan my week"},{"uuid":"n","sender":"assistant","text":"Monday: pasta"}]},
     {"uuid":"u-2","name":"","chat_messages":[]},
     {"uuid":"u-3","name":"Poem","chat_messages":[{"sender":"human","text":"Write a poem"}]}]
    """

    /// lib/imports/grok.ts
    let grok = #"[{"conversation_id":"g-1","title":"Orbit maths","create_time":"1727000000","responses":[{"sender":"human","message":"Hi"},{"sender":"grok","message":"Hello"}]}]"#

    /// lib/imports/gemini.ts: Takeout activity, newest first, one entry per prompt.
    let gemini = """
    [{"header":"Gemini Apps","title":"Prompted What is a monad?","time":"2026-05-02T09:00:00.000Z","safeHtmlItem":[{"html":"<p>A burrito.</p>"}]},
     {"header":"Gemini Apps","title":"Prompted Name a color","time":"2026-05-02T08:00:00.000Z"},
     {"header":"Gemini Apps","title":"Prompted ","time":"2026-05-02T07:00:00.000Z"},
     {"header":"Gemini Apps","title":"Prompted Plan a trip","time":"2026-05-01T20:00:00.000Z"}]
    """

    func inspect(_ text: String, hint: ImportPlatform? = nil) -> ImportDocument {
        ImportInspector.inspect(Data(text.utf8), name: "export.json", hint: hint)
    }

    // MARK: Recognising exports

    func testRecognisesChatGPT() {
        let document = inspect(chatgpt)
        XCTAssertEqual(document.detected, .chatgpt)
        XCTAssertEqual(document.platform, .chatgpt)
        XCTAssertEqual(document.conversationCount, 2, "brackets and quotes inside strings must not confuse the scan")
        XCTAssertEqual(document.sampleTitles, [#"Trip "planning" [draft], part 1"#, "Fix my regex"])
        XCTAssertTrue(document.isImportable)
        XCTAssertEqual(document.kind, .json)
    }

    func testRecognisesClaudeGrokAndGemini() {
        let claude = inspect(claude)
        XCTAssertEqual(claude.detected, .claude)
        XCTAssertEqual(claude.conversationCount, 3, "the route reports empty ones as skipped, so they are counted here")
        XCTAssertEqual(claude.sampleTitles, ["Meal plan", "Poem"])

        let grok = inspect(grok)
        XCTAssertEqual(grok.detected, .grok)
        XCTAssertEqual(grok.conversationCount, 1)

        let gemini = inspect(gemini)
        XCTAssertEqual(gemini.detected, .gemini)
        XCTAssertEqual(gemini.conversationCount, 2, "one conversation per day, and an empty prompt is dropped")
        XCTAssertEqual(gemini.sampleTitles.first, "What is a monad?")
    }

    func testAnObjectWrapperAndASingleConversationAreUnwrapped() {
        let wrapped = inspect(#"{"version":2,"conversations":\#(grok)}"#)
        XCTAssertEqual(wrapped.detected, .grok)
        XCTAssertEqual(wrapped.conversationCount, 1)

        let single = inspect(#"{"conversation_id":"x","title":"One","responses":[{"sender":"human","message":"Hi"}]}"#)
        XCTAssertEqual(single.detected, .grok)
        XCTAssertEqual(single.conversationCount, 1)
    }

    func testPlainMessagesJSONIsAccepted() {
        let document = inspect(#"[{"title":"Mine","messages":[{"role":"user","content":"hi"}]}]"#)
        XCTAssertEqual(document.detected, .other)
        XCTAssertEqual(document.platform, .other)
        XCTAssertEqual(document.conversationCount, 1)
    }

    func testJSONThatIsNotAHistoryHoldsNothing() {
        // A Grok archive also holds account and billing files (docs/imports/grok-x-archive-analysis.md).
        let account = inspect(#"{"user":{"userId":"u","email":"a@b.co"},"sessions":[],"teams":[]}"#)
        XCTAssertNil(account.detected)
        XCTAssertEqual(account.conversationCount, 0)
        XCTAssertFalse(account.isImportable)
        XCTAssertTrue(account.batches().isEmpty)

        XCTAssertEqual(inspect(#"{"balance_map":{"t":0}}"#).conversationCount, 0)
        XCTAssertEqual(inspect("[1,2,3]").conversationCount, 0)
        XCTAssertEqual(inspect("[]").conversationCount, 0)
    }

    func testABrokenFileIsReadAsTranscriptLikeTheRouteDoes() {
        let document = inspect(#"[{"title": "cut off"#)
        XCTAssertEqual(document.kind, .transcript)
        XCTAssertEqual(document.conversationCount, 0)
    }

    func testByteOrderMarkAndWhitespaceAreSkipped() {
        var bytes = Data([0xEF, 0xBB, 0xBF])
        bytes.append(Data("\n  \(grok)\n".utf8))
        let document = ImportInspector.inspect(bytes, name: "x.json")
        XCTAssertEqual(document.detected, .grok)
        XCTAssertEqual(document.conversationCount, 1)
    }

    func testAMismatchBetweenChoiceAndFileIsFlagged() {
        let document = inspect(claude, hint: .chatgpt)
        XCTAssertTrue(document.disagrees)
        XCTAssertEqual(document.platform, .claude, "what the file is wins over what was picked")
        XCTAssertFalse(inspect(claude, hint: .claude).disagrees)
        XCTAssertFalse(inspect(claude).disagrees)
    }

    // MARK: Pasted transcripts

    func testTranscriptLabelsMatchTheRoutesParser() {
        let text = """
        Copied from my phone
        User: how do I center a div
        Assistant: with flexbox —
        use `display: flex`.

        ## Human：and vertically?
        **ChatGPT:** `align-items: center`
        You : thanks
        user2: not a label
        """
        let messages = ImportTranscript.messages(in: text)
        XCTAssertEqual(messages.map(\.role), ["user", "assistant", "user", "assistant", "user"])
        XCTAssertEqual(messages[0].content, "how do I center a div")
        XCTAssertEqual(messages[1].content, "with flexbox —\nuse `display: flex`.")
        XCTAssertEqual(messages[2].content, "and vertically?")
        XCTAssertTrue(messages[4].content.hasPrefix("thanks"))
        XCTAssertTrue(messages[4].content.contains("user2: not a label"), "not a label, so it continues the message")
    }

    func testTranscriptDocument() {
        let document = ImportInspector.inspect(text: "Me: hello\nClaude: hi there")
        XCTAssertEqual(document.kind, .transcript)
        XCTAssertEqual(document.conversationCount, 1)
        XCTAssertEqual(document.messageCount, 2)
        XCTAssertEqual(document.platform, .other)
        XCTAssertEqual(document.batches().count, 1)

        let nothing = ImportInspector.inspect(text: "just some words without any speaker")
        XCTAssertEqual(nothing.conversationCount, 0)
        XCTAssertTrue(nothing.batches().isEmpty)
        XCTAssertEqual(
            ImportInspector.nothingFoundMessage,
            "Couldn't find any conversations in that data. Upload the conversations.json from your platform's export, or paste a transcript with User:/Assistant: labels."
        )
    }

    // MARK: Batches

    /// `count` ChatGPT-shaped conversations of roughly `weight` bytes each.
    func chatgptHistory(count: Int, weight: Int = 200) -> String {
        let filler = String(repeating: "x", count: weight)
        let items = (0..<count).map { #"{"title":"T\#($0)","conversation_id":"c\#($0)","current_node":"a","mapping":{"a":{"id":"a","message":null,"parent":null,"children":[]}},"pad":"\#(filler)"}"# }
        return "[" + items.joined(separator: ",\n") + "]"
    }

    func ids(in text: String) throws -> [String] {
        let array = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
        return array.compactMap { $0["conversation_id"] as? String }
    }

    func testBatchesRespectTheConversationCap() throws {
        let document = inspect(chatgptHistory(count: 120))
        XCTAssertEqual(document.conversationCount, 120)
        let batches = document.batches(maxBytes: 10_000_000, maxConversations: 50)
        XCTAssertEqual(batches.map(\.conversationCount), [50, 50, 20])
        let all = try batches.flatMap { try ids(in: document.text(for: $0)) }
        XCTAssertEqual(all, (0..<120).map { "c\($0)" }, "every conversation, once, in order")
    }

    func testBatchesRespectTheByteCapAndKeepAnOversizeConversationAlone() throws {
        var items = (0..<5).map { #"{"conversation_id":"c\#($0)","mapping":{},"pad":"\#(String(repeating: "y", count: 400))"}"# }
        items.insert(#"{"conversation_id":"huge","mapping":{},"pad":"\#(String(repeating: "z", count: 5_000))"}"#, at: 2)
        let document = inspect("[" + items.joined(separator: ",") + "]")
        let batches = document.batches(maxBytes: 1_200, maxConversations: 50)
        let sets = try batches.map { try ids(in: document.text(for: $0)) }
        XCTAssertEqual(sets, [["c0", "c1"], ["huge"], ["c2", "c3"], ["c4"]])
        for batch in batches where batch.conversationCount > 1 {
            XCTAssertLessThanOrEqual(batch.byteCount, 1_200 + 8)
        }
    }

    func testAGeminiDayIsNeverSplit() throws {
        let entries = (0..<30).map { i -> String in
            let day = i < 20 ? "2026-05-02" : "2026-05-0\(3 + i % 3)"
            return #"{"header":"Gemini Apps","title":"Prompted question \#(i)","time":"\#(day)T10:00:00.000Z"}"#
        }
        let document = inspect("[" + entries.joined(separator: ",") + "]")
        XCTAssertEqual(document.detected, .gemini)
        XCTAssertEqual(document.conversationCount, 4)
        let batches = document.batches(maxBytes: 600, maxConversations: 50)
        XCTAssertGreaterThan(batches.count, 1)
        var daysSeen: [String: Int] = [:]
        for batch in batches {
            let array = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(document.text(for: batch).utf8)) as? [[String: Any]])
            let days = Set(array.compactMap { ($0["time"] as? String).map { String($0.prefix(10)) } })
            for day in days { daysSeen[day, default: 0] += 1 }
        }
        XCTAssertTrue(daysSeen.values.allSatisfy { $0 == 1 }, "each day appears in exactly one request: \(daysSeen)")
    }

    func testSplittingHalvesABatch() throws {
        let document = inspect(chatgptHistory(count: 7))
        let batch = try XCTUnwrap(document.batches().first)
        let (first, second) = try XCTUnwrap(document.split(batch))
        XCTAssertEqual(first.conversationCount, 3)
        XCTAssertEqual(second.conversationCount, 4)
        XCTAssertEqual(try ids(in: document.text(for: first)) + ids(in: document.text(for: second)), (0..<7).map { "c\($0)" })
        let single = document.batches(maxBytes: 10_000_000, maxConversations: 1)[0]
        XCTAssertNil(document.split(single))
    }

    func testTheTextOfABatchIsValidJSONTheRouteWouldDetect() throws {
        let document = inspect(chatgpt)
        let batch = try XCTUnwrap(document.batches().first)
        let again = ImportInspector.inspect(Data(document.text(for: batch).utf8))
        XCTAssertEqual(again.detected, .chatgpt)
        XCTAssertEqual(again.conversationCount, 2)
    }

    // MARK: Runner

    func testRunnerAddsUpEveryBatch() async throws {
        let document = inspect(chatgptHistory(count: 120))
        let plan = ImportPlan(documents: [document], maxBatchBytes: 10_000_000, maxBatchConversations: 50)
        XCTAssertEqual(plan.items.count, 3)
        XCTAssertEqual(plan.conversationTotal, 120)

        let seen = Counter()
        let fractions = Locked<[Double]>([])
        let totals = try await ImportRunner.run(
            plan: plan,
            send: { request in
                seen.bump()
                XCTAssertEqual(request.platform, "chatgpt")
                return outcome(count(in: request), skipped: 1)
            },
            progress: { update in fractions.mutate { $0.append(update.fraction) } }
        )
        XCTAssertEqual(seen.value, 3)
        XCTAssertEqual(totals.imported, 120)
        XCTAssertEqual(totals.skipped, 3)
        XCTAssertEqual(totals.messages, 480)
        XCTAssertEqual(totals.batches, 3)
        let reported = fractions.value
        XCTAssertEqual(reported.first, 0)
        XCTAssertEqual(reported.last, 1)
        XCTAssertEqual(reported, reported.sorted(), "progress only moves forward")
        XCTAssertEqual(totals.summary(platform: .chatgpt), "Imported 120 conversations (480 messages) from ChatGPT. Open Chat to continue them on any backend.")
    }

    func testTheFinishLineGroupsBigNumbersAndSaysOneInTheSingular() {
        let english = Locale(identifier: "en_US")
        var big = ImportTotals()
        big.add(ImportOutcome(platform: .chatgpt, imported: 1_337, skipped: 0, messages: 4_120))
        XCTAssertEqual(
            big.summary(platform: .chatgpt, locale: english),
            "Imported 1,337 conversations (4,120 messages) from ChatGPT. Open Chat to continue them on any backend."
        )

        var one = ImportTotals()
        one.add(ImportOutcome(platform: .other, imported: 1, skipped: 0, messages: 1))
        XCTAssertEqual(
            one.summary(platform: .other, locale: english),
            "Imported 1 conversation (1 message). Open Chat to continue them on any backend."
        )
    }

    func testARequestTheServerFindsTooHeavyIsHalved() async throws {
        let document = inspect(chatgptHistory(count: 40))
        let plan = ImportPlan(documents: [document], maxBatchBytes: 10_000_000, maxBatchConversations: 50)
        let sizes = Locked<[Int]>([])
        let totals = try await ImportRunner.run(plan: plan, send: { request in
            let n = count(in: request)
            sizes.mutate { $0.append(n) }
            if n > 12 { throw HVError.api(APIFailure(status: 504, message: "Gateway timeout")) }
            return outcome(n)
        })
        XCTAssertEqual(totals.imported, 40)
        XCTAssertEqual(sizes.value.first, 40)
        XCTAssertTrue(sizes.value.dropFirst().allSatisfy { $0 <= 20 })
        XCTAssertEqual(totals.skipped, 0)
    }

    func testOneConversationTooLargeOnItsOwnIsSkippedAndTheRunGoesOn() async throws {
        let document = inspect(chatgptHistory(count: 3))
        let plan = ImportPlan(documents: [document], maxBatchBytes: 10_000_000, maxBatchConversations: 50)
        let totals = try await ImportRunner.run(plan: plan, send: { request in
            if request.data.contains(#""c1""#) { throw HVError.api(APIFailure(status: 413, message: "That is too large.")) }
            return outcome(count(in: request))
        })
        XCTAssertEqual(totals.imported, 2)
        XCTAssertEqual(totals.skipped, 1)
        XCTAssertEqual(totals.tooLarge, 1)
    }

    func testAFailureStopsWithWhereToResume() async throws {
        let document = inspect(chatgptHistory(count: 120))
        let plan = ImportPlan(documents: [document], maxBatchBytes: 10_000_000, maxBatchConversations: 50)
        let calls = Counter()
        do {
            _ = try await ImportRunner.run(plan: plan, send: { request in
                calls.bump()
                if calls.value == 2 { throw HVError.api(APIFailure(status: 500, message: "The server had a problem. Try again in a moment.")) }
                return outcome(count(in: request))
            })
            XCTFail("expected the run to stop")
        } catch let stop as ImportRunError {
            XCTAssertEqual(stop.resumeAt, 1)
            XCTAssertEqual(stop.totals.imported, 50, "only what finished before the failed item")
            XCTAssertEqual(stop.conversationsDone, 50)
            XCTAssertEqual(stop.userMessage, "The server had a problem. Try again in a moment.")

            // Picking up again sends the rest and ends with the full count.
            let resumed = try await ImportRunner.run(plan: plan, start: stop.resumeAt, totals: stop.totals, send: { request in
                outcome(count(in: request))
            })
            XCTAssertEqual(resumed.imported, 120)
        }
    }

    func testOfflineIsNotMistakenForTooHeavy() async {
        let document = inspect(chatgptHistory(count: 10))
        let plan = ImportPlan(documents: [document])
        let calls = Counter()
        do {
            _ = try await ImportRunner.run(plan: plan, send: { _ in
                calls.bump()
                throw HVError.transport("offline")
            })
            XCTFail("expected a stop")
        } catch let stop as ImportRunError {
            XCTAssertTrue(stop.error.isOffline)
            XCTAssertEqual(calls.value, 1, "no pointless halving while offline")
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testCancellationStopsWithTheTotalsSoFar() async {
        let document = inspect(chatgptHistory(count: 120))
        let plan = ImportPlan(documents: [document], maxBatchBytes: 10_000_000, maxBatchConversations: 50)
        let calls = Counter()
        do {
            _ = try await ImportRunner.run(plan: plan, send: { request in
                calls.bump()
                if calls.value == 2 { throw CancellationError() }
                return outcome(count(in: request))
            })
            XCTFail("expected a stop")
        } catch let stop as ImportRunError {
            XCTAssertEqual(stop.error, .cancelled)
            XCTAssertEqual(stop.resumeAt, 1)
            XCTAssertEqual(stop.totals.imported, 50)
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testATranscriptCarriesItsTitleAndNoPlatform() async throws {
        let document = ImportInspector.inspect(text: "User: hi\nAssistant: hello")
        let plan = ImportPlan(documents: [document], title: "  Greeting ")
        let captured = Locked<ImportRequest?>(nil)
        _ = try await ImportRunner.run(plan: plan, send: { request in
            captured.mutate { $0 = request }
            return outcome(1)
        })
        let request = try XCTUnwrap(captured.value)
        XCTAssertNil(request.platform)
        XCTAssertEqual(request.title, "Greeting")
        XCTAssertEqual(request.data, "User: hi\nAssistant: hello")
    }

    func testTheRequestIsWrittenForTheRoute() async throws {
        let transport = MockTransport(routes: [.json(.post, "/api/import", #"{"platform":"chatgpt","imported":2,"skipped":0,"messages":8,"message":"Imported 2 conversations (8 messages) from chatgpt. Open /chat to continue them on any backend."}"#)])
        let api = HVClient(baseURL: URL(string: "https://hv.test")!, transport: transport, tokens: StaticTokenProvider())
        let outcome = try await api.send(.importHistory(ImportRequest(data: "[1]", platform: .chatgpt)))
        XCTAssertEqual(outcome.platform, .chatgpt)
        XCTAssertEqual(outcome.imported, 2)
        XCTAssertEqual(outcome.messages, 8)
        let sent = await transport.requests
        XCTAssertEqual(String(decoding: sent[0].httpBody ?? Data(), as: UTF8.self), #"{"data":"[1]","platform":"chatgpt"}"#)
        XCTAssertEqual(sent[0].timeoutInterval, 100)
    }

    func testRefusalsKeepTheServersWords() async {
        let transport = MockTransport(routes: [
            .failure(.post, "/api/import", status: 400, message: ImportInspector.nothingFoundMessage),
        ])
        let api = HVClient(baseURL: URL(string: "https://hv.test")!, transport: transport, tokens: StaticTokenProvider())
        do {
            _ = try await api.send(.importHistory(ImportRequest(data: "x")))
            XCTFail("expected 400")
        } catch let error as HVError {
            XCTAssertEqual(error.userMessage, ImportInspector.nothingFoundMessage)
        } catch {
            XCTFail("wrong error \(error)")
        }
    }
}

func outcome(_ imported: Int, skipped: Int = 0, messages: Int? = nil) -> ImportOutcome {
    ImportOutcome(platform: .chatgpt, imported: imported, skipped: skipped, messages: messages ?? imported * 4)
}

/// How many conversations a request carries.
func count(in request: ImportRequest) -> Int {
    (try? JSONSerialization.jsonObject(with: Data(request.data.utf8)) as? [Any])?.count ?? 0
}

/// A value several closures may touch, for tests.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func mutate(_ change: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        change(&stored)
    }
}
