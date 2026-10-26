import XCTest
@testable import HyperVaultKit

final class CanvasStateTests: XCTestCase {
    func card(_ slug: String, _ title: String) -> CanvasCard { CanvasState.artifactCard(slug: slug, title: title) }

    func testAddingPutsTheCardLastAndReplacesADuplicate() {
        var cards: [CanvasCard] = []
        cards = CanvasState.reduce(cards, .add(card("a", "Alpha")))
        cards = CanvasState.reduce(cards, .add(card("b", "Beta")))
        cards = CanvasState.reduce(cards, .add(card("a", "Alpha again")))
        XCTAssertEqual(cards.map(\.key), ["artifact:b", "artifact:a"])
        XCTAssertEqual(cards.last?.title, "Alpha again")
    }

    func testTheNinthCardDropsTheOldest() {
        var cards: [CanvasCard] = []
        for index in 1...9 { cards = CanvasState.reduce(cards, .add(card("s\(index)", "T\(index)"))) }
        XCTAssertEqual(cards.count, canvasMaxCards)
        XCTAssertEqual(cards.first?.key, "artifact:s2")
        XCTAssertEqual(cards.last?.key, "artifact:s9")
    }

    func testAKeptCardKeepsItsLinkWhenPulledAgainAsAPlainCard() {
        let kept = KeptThing(slug: "trip", url: "https://hypervault.store/a/trip", kind: .page, form: "note", title: "Trip", visibility: "private", duplicate: false, message: "")
        var cards = [CanvasState.keptCard(kept, origin: URL(string: "https://hypervault.store/")!)]
        XCTAssertEqual(cards[0].kept?.link, "https://hypervault.store/a/trip")
        XCTAssertEqual(cards[0].kept?.line, HVCopy.keptLine)
        XCTAssertTrue(cards[0].kept?.isPrivate ?? false)

        cards = CanvasState.reduce(cards, .add(CanvasState.artifactCard(slug: "trip", title: "Trip")))
        XCTAssertEqual(cards.count, 1)
        XCTAssertNotNil(cards[0].kept, "the link and Copy link must not vanish because it was tapped")
    }

    func testADuplicateKeepSaysSo() {
        let kept = KeptThing(slug: "x", url: "", kind: .page, form: "note", title: "X", visibility: "private", duplicate: true, message: "")
        XCTAssertEqual(CanvasState.keptCard(kept, origin: URL(string: "https://h.test")!).kept?.line, HVCopy.alreadyKeptLine)
    }

    func testFillOnlyTouchesACardThatIsStillThere() throws {
        let detail = try HVCoding.decoder().decode(KeptCard.self, from: Data(#"{"id":"m1","kind":"memory","name":"Trip notes","href":"/vault/memory?open=m1","digest":"Paris in May","updated_at":"2026-10-24T01:02:03Z"}"#.utf8))
        let there = CanvasCard(key: "memory:m1", kind: .memory, title: "Trip notes", href: "/vault/memory?open=m1")
        let filled = CanvasState.reduce([there], .fill(key: "memory:m1", detail: detail, subtitle: "Paris in May", title: nil))
        XCTAssertEqual(filled[0].subtitle, "Paris in May")
        XCTAssertEqual(filled[0].ref, CardRef(kind: .memory, id: "m1"))
        XCTAssertEqual(CanvasState.reduce([], .fill(key: "memory:m1", detail: detail, subtitle: nil, title: nil)), [])
    }

    func testHideAndHideAll() {
        let cards = [card("a", "A"), card("b", "B")]
        XCTAssertEqual(CanvasState.reduce(cards, .hide(key: "artifact:a")).map(\.key), ["artifact:b"])
        XCTAssertEqual(CanvasState.reduce(cards, .hide(key: "nope")).count, 2)
        XCTAssertEqual(CanvasState.reduce(cards, .hideAll), [])
    }

    func testNameWords() {
        XCTAssertEqual(CanvasState.nameWords("The Q3 plan!"), "q3 plan")
        XCTAssertEqual(CanvasState.nameWords("  Co-parenting   notes "), "co parenting notes")
        XCTAssertEqual(CanvasState.nameWords("the"), "the")
        XCTAssertEqual(CanvasState.nameWords("Caf\u{00E9} menu"), "caf\u{00E9} menu")
    }

    func testFindCardByName() {
        let cards = [card("a", "Co-parenting notes"), card("b", "Notepad"), card("c", "Trip plan")]
        XCTAssertEqual(CanvasState.findCard(named: "co-parenting notes", in: cards)?.key, "artifact:a")
        XCTAssertEqual(CanvasState.findCard(named: "notes", in: cards)?.key, "artifact:a", "a whole word inside exactly one title")
        XCTAssertNil(CanvasState.findCard(named: "note", in: cards), "notes does not match Notepad, and note is not a whole word")
        let twins = [card("a", "Untitled"), card("b", "Untitled")]
        XCTAssertNil(CanvasState.findCard(named: "untitled", in: twins), "two cards that both fit match nothing")
        XCTAssertNil(CanvasState.findCard(named: "", in: cards))
    }

    func testCardKeysAndHrefs() {
        XCTAssertEqual(CanvasState.itemCardKey(kind: .page, id: "id1", href: "/a/trip-notes-1"), "artifact:trip-notes-1")
        XCTAssertEqual(CanvasState.itemCardKey(kind: .group, id: "id2", href: "/g/site"), "artifact:site")
        XCTAssertEqual(CanvasState.itemCardKey(kind: .memory, id: "m", href: "/x"), "memory:m")
        XCTAssertEqual(CanvasState.itemCardKey(kind: .key, id: "k", href: "/x"), "key:k")
        XCTAssertEqual(CanvasState.artifactCard(slug: "s", title: nil, kind: .group).href, "/g/s")
        XCTAssertEqual(CanvasState.artifactCard(slug: "s", title: "  ").title, "Untitled")
    }

    func testPulledRefsAreTheRowsCardsStandFor() {
        var withRef = card("a", "A")
        withRef.ref = CardRef(kind: .page, id: "row-1")
        XCTAssertEqual(CanvasState.pulledRefs([withRef, card("b", "B")]), [CardRef(kind: .page, id: "row-1")])
    }

    func testDetailLines() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func detail(_ json: String) throws -> KeptCard { try HVCoding.decoder().decode(KeptCard.self, from: Data(json.utf8)) }
        let group = try detail(#"{"id":"g","kind":"group","name":"Site","href":"/g/site","files":[{"path":"index.html","size_bytes":10},{"path":"a.css","size_bytes":5},{"path":"b.js","size_bytes":5},{"path":"c.js","size_bytes":5}]}"#)
        XCTAssertEqual(CanvasState.detailLine(group, now: now), "4 files: index.html, a.css, b.js, ...")
        let key = try detail(#"{"id":"k","kind":"key","name":"OpenAI","href":"/vault/account","agents":[{"id":"a","name":"Claude Code","key_prefix":"hv_abc"}],"available":[],"last_used_at":null}"#)
        XCTAssertEqual(CanvasState.detailLine(key, now: now), "1 agent allowed, Never used")
        let memory = try detail(#"{"id":"m","kind":"memory","name":"Trip","href":"/h","digest":"Paris in May","updated_at":"2026-10-24T01:02:03Z"}"#)
        XCTAssertEqual(CanvasState.detailLine(memory, now: now), "Paris in May")
    }
}

final class PullAndLinkTests: XCTestCase {
    func item(_ id: String, _ name: String) -> KeptItem { KeptItem(id: id, kind: .page, name: name, href: "/a/\(id)") }

    func testPullIsSureOrAsks() {
        XCTAssertEqual(PullResolver.resolve(query: "x", results: []), .none)
        let one = [item("1", "Co-parenting notes")]
        XCTAssertEqual(PullResolver.resolve(query: "parenting", results: one), .one(one[0]), "the only thing that fits")

        let many = [item("1", "Trip plan"), item("2", "Trip plan B"), item("3", "Old trip plan")]
        XCTAssertEqual(PullResolver.resolve(query: "the trip plan", results: many), .one(many[0]), "an exact whole name wins")
        guard case .choose(let items, let more) = PullResolver.resolve(query: "trip", results: many) else { return XCTFail("should ask") }
        XCTAssertEqual(items.count, 3)
        XCTAssertFalse(more)

        let twins = [item("1", "Notes"), item("2", "Notes"), item("3", "Notes from Paris")]
        guard case .choose(let tied, _) = PullResolver.resolve(query: "notes", results: twins) else { return XCTFail("a tie is not broken by recency") }
        XCTAssertEqual(tied.map(\.id), ["1", "2"])

        let lots = (1...8).map { item("\($0)", "Plan \($0)") }
        guard case .choose(let shown, let more2) = PullResolver.resolve(query: "plan", results: lots) else { return XCTFail() }
        XCTAssertEqual(shown.count, PullResolver.maxChoices)
        XCTAssertTrue(more2)
    }

    func testVaultLinks() {
        let origin = URL(string: "https://hypervault.store")
        XCTAssertEqual(VaultLink.parse("https://hypervault.store/a/trip-notes-abc123", origin: origin), .artifact(slug: "trip-notes-abc123"))
        XCTAssertEqual(VaultLink.parse("<https://hypervault.store/g/site>.", origin: origin), .artifact(slug: "site"))
        XCTAssertEqual(VaultLink.parse("https://sam.vault.cool/a/page-1", origin: nil), .artifact(slug: "page-1"))
        XCTAssertEqual(VaultLink.parse("https://preview.example.test/a/x", origin: URL(string: "https://preview.example.test")), .artifact(slug: "x"))
        XCTAssertEqual(
            VaultLink.parse("https://hypervault.store/vault/memory?open=7F1C2D3E-1111-2222-3333-444455556666", origin: origin),
            .memory(id: "7f1c2d3e-1111-2222-3333-444455556666")
        )
        XCTAssertNil(VaultLink.parse("see https://hypervault.store/a/x", origin: origin), "a link inside a sentence is a sentence")
        XCTAssertNil(VaultLink.parse("https://evil.test/a/x", origin: origin))
        XCTAssertNil(VaultLink.parse("https://hypervault.store/vault/library", origin: origin))
        XCTAssertNil(VaultLink.parse("https://hypervault.store/vault/memory?open=nope", origin: origin))
        XCTAssertNil(VaultLink.parse("https://user:pw@hypervault.store/a/x", origin: origin))
        XCTAssertNil(VaultLink.parse("ftp://hypervault.store/a/x", origin: origin))
    }

    /// Every domain in the web's DOMAIN_PORTFOLIO (lib/domains.ts) is a HyperVault host, for the apex and any subdomain.
    func testEveryPortfolioDomainIsOurs() {
        let portfolio = [
            "vault.cool", "agentvault.cloud", "cleon.wiki", "inkbound.ink", "claudedamnit.com", "cleon.casa", "cleon.city",
            "tinderforai.com", "onlywizards.website", "hypervault.store", "ralphy.website", "permaclaw.com", "bo.dy",
            "memory.baby", "memory.delivery", "smallchat.dev",
        ]
        for domain in portfolio {
            XCTAssertEqual(VaultLink.parse("https://x.\(domain)/a/my-game", origin: nil), .artifact(slug: "my-game"), domain)
            XCTAssertEqual(VaultLink.parse("https://\(domain)/g/site", origin: nil), .artifact(slug: "site"), domain)
        }
        XCTAssertEqual(
            VaultLink.parse("https://x.smallchat.dev/vault/memory?open=7f1c2d3e-1111-2222-3333-444455556666", origin: nil),
            .memory(id: "7f1c2d3e-1111-2222-3333-444455556666")
        )
        XCTAssertNil(VaultLink.parse("https://notsmallchat.dev/a/x", origin: nil), "a lookalike is not a subdomain")
    }

    func testPasteStaging() {
        XCTAssertFalse(PasteStaging.shouldStage("a short sentence"))
        XCTAssertFalse(PasteStaging.shouldStage("https://example.com/" + String(repeating: "a", count: 300)), "a link is never staged")
        XCTAssertTrue(PasteStaging.shouldStage(String(repeating: "word ", count: 90)), "long pastes are staged")
        let lines = (1...4).map { "line number \($0) with enough words to count here and there" }.joined(separator: "\n")
        XCTAssertTrue(PasteStaging.shouldStage(lines), "several lines of real length")
        XCTAssertFalse(PasteStaging.shouldStage("a\nb\nc"), "short even over several lines")
    }
}

final class ThinkingAndArtifactTests: XCTestCase {
    func testThinkingIsSplitOut() {
        let split = Thinking.strip("<think>sketch // ... etc</think>The answer is 4.")
        XCTAssertEqual(split.text, "The answer is 4.")
        XCTAssertEqual(split.reasoning, "sketch // ... etc")
        XCTAssertEqual(Thinking.strip("plain reply").reasoning, "")
        XCTAssertEqual(Thinking.strip("Answer<think>cut off mid-thought").text, "Answer")
        XCTAssertEqual(Thinking.strip("lost opener</think>Visible").text, "Visible")
        XCTAssertEqual(Thinking.strip("<THINKING>x</THINKING>y").text, "y")
    }

    let page = "<!doctype html><html><head><title>Bakery</title></head><body><h1>Hello</h1><p>Fresh bread every morning, baked with care.</p></body></html>"

    func testAFullHTMLDocumentInAFenceIsTheArtifact() throws {
        let reply = "Here you go:\n```html\n\(page)\n```\nEnjoy!"
        let artifact = try XCTUnwrap(ChatArtifactExtractor.extract(reply))
        XCTAssertEqual(artifact.kind, .html)
        XCTAssertEqual(artifact.content, page)
        XCTAssertEqual(artifact.title, "Bakery")
        XCTAssertEqual(KeepReply.content(of: reply), page, "a whole HTML document is kept as it is")
    }

    func testJSXIsDetectedAndKeptAsAFencedBlock() throws {
        let code = "import React, { useState } from 'react';\nexport default function PomodoroTimer() {\n  const [n, setN] = useState(0);\n  return <div className=\"t\">{n}</div>;\n}"
        let reply = "Here:\n```tsx\n\(code)\n```"
        let artifact = try XCTUnwrap(ChatArtifactExtractor.extract(reply))
        XCTAssertEqual(artifact.kind, .jsx)
        XCTAssertEqual(artifact.title, "Pomodoro Timer")
        XCTAssertEqual(KeepReply.content(of: reply), "```jsx\n\(code)\n```")
    }

    func testProseIsKeptWholeAndTinyOrEmptyIsNothing() {
        let prose = "Call the dentist. Bring the forms. Ask about the cleaning schedule for next year too."
        XCTAssertNil(ChatArtifactExtractor.extract(prose))
        XCTAssertEqual(KeepReply.content(of: "  \(prose)  "), prose)
        XCTAssertNil(KeepReply.content(of: "   "))
        XCTAssertNil(ChatArtifactExtractor.extract("```html\n<p>hi</p>\n```"), "too small to be a real artifact")
    }

    func testAReplyCutOffMidFenceStillYieldsItsPage() throws {
        let reply = "Sure!\n```html\n\(page)"
        let artifact = try XCTUnwrap(ChatArtifactExtractor.extract(reply))
        XCTAssertEqual(artifact.kind, .html)
    }

    func testReasoningTracesAreNeverTheArtifact() {
        let reply = "<think>```html\n\(page)\n```</think>Done, nothing to keep here really, just talking about it for a bit."
        XCTAssertNil(ChatArtifactExtractor.extract(reply))
    }

    func testJSXDetectorNeverCallsAFullPageJSX() {
        XCTAssertFalse(JSXDetector.detect("<!doctype html><html><script>import React from 'react'</script></html>").isJSX)
        XCTAssertTrue(JSXDetector.detect("const App = () => (<Card className=\"x\" />)\nexport default App").isJSX)
        XCTAssertFalse(JSXDetector.detect("Just a sentence about React and nothing else.").isJSX)
    }
}

final class CanvasChatTests: XCTestCase {
    func client(_ transport: MockTransport) -> HVClient {
        HVClient(baseURL: URL(string: "https://hv.test")!, transport: transport, tokens: StaticTokenProvider("t"), retry: .none)
    }

    func testTheRequestCarriesOnlyWhatTheCanvasMaySay() async throws {
        let transport = MockTransport(routes: [.json(.post, "/api/chat", #"{"conversation_id":"c1","reply":{"id":"r1","role":"assistant","content":"Hello!","truncated":false},"pulled":[{"kind":"memory","id":"m1","title":"Trip notes"},{"kind":"bogus","id":"x","title":"  "}]}"#)])
        let turn = try await client(transport).send(.canvasChat(backendId: "b1", message: "hi", conversationId: nil, pulled: [CardRef(kind: .memory, id: "m1")]))
        XCTAssertEqual(turn, CanvasTurn(conversationId: "c1", replyId: "r1", content: "Hello!", truncated: false, pulledTitles: ["Trip notes"]))

        let body = try JSONSerialization.jsonObject(with: await transport.requests.last?.httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(body?["backend_id"] as? String, "b1")
        XCTAssertEqual(body?["use_recall"] as? Bool, true)
        XCTAssertEqual(body?["use_tools"] as? Bool, false, "the canvas has no UI to show a tool run")
        XCTAssertNil(body?["conversation_id"])
        let pulled = body?["pulled"] as? [[String: String]]
        XCTAssertEqual(pulled, [["kind": "memory", "id": "m1"]])
    }

    func testNoPulledKeyWhenNothingIsOnThePage() async throws {
        let transport = MockTransport(routes: [.json(.post, "/api/chat", #"{"conversation_id":"c1","reply":{"content":"ok"}}"#)])
        _ = try await client(transport).send(.canvasChat(backendId: "b", message: "hi", conversationId: "c0", pulled: []))
        let body = try JSONSerialization.jsonObject(with: await transport.requests.last?.httpBody ?? Data()) as? [String: Any]
        XCTAssertNil(body?["pulled"])
        XCTAssertEqual(body?["conversation_id"] as? String, "c0")
    }

    func testAnEmptyOrUnreadableAnswerIsAFailedTurnNotABlankReply() async {
        for json in [#"{"conversation_id":"c","reply":{"content":"   "}}"#, #"{"reply":{"content":"x"}}"#, #"{"conversation_id":"c"}"#, "not json"] {
            let transport = MockTransport(routes: [.json(.post, "/api/chat", json)])
            do {
                _ = try await client(transport).send(.canvasChat(backendId: "b", message: "hi", conversationId: nil, pulled: []))
                XCTFail("expected a failure for \(json)")
            } catch let error as HVError {
                XCTAssertFalse(error.userMessage.isEmpty)
            } catch {
                XCTFail("wrong error")
            }
        }
    }

    func testReasoningOnlyReplyStillShows() async throws {
        let transport = MockTransport(routes: [.json(.post, "/api/chat", #"{"conversation_id":"c","reply":{"content":"<think>only thinking</think>"}}"#)])
        let turn = try await client(transport).send(.canvasChat(backendId: "b", message: "hi", conversationId: nil, pulled: []))
        XCTAssertEqual(turn.content, "only thinking")
    }

    func testServerSentenceSurvivesAFailure() async {
        let transport = MockTransport(routes: [.failure(.post, "/api/chat", status: 502, message: "The model could not be reached.")])
        do {
            _ = try await client(transport).send(.canvasChat(backendId: "b", message: "hi", conversationId: nil, pulled: []))
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual((error as? HVError)?.userMessage, "The model could not be reached.")
        }
    }

    func testBackendsListKeepsOnlyWhatTheCanvasNeeds() async throws {
        let transport = MockTransport(routes: [.json(.get, "/api/backends", #"{"backends":[{"id":"b1","name":"My Claude","provider":"anthropic","default_model":"claude-opus","key_hint":"sk-…abcd"}],"providers":[]}"#)])
        let backends = try await client(transport).send(.canvasBackends)
        XCTAssertEqual(backends, [CanvasBackend(id: "b1", name: "My Claude", defaultModel: "claude-opus", provider: "anthropic")])
    }
}

final class KeptModelTests: XCTestCase {
    func testYoursListDecodesTheRealShape() throws {
        let json = """
        {"recent":[{"id":"a1","kind":"page","name":"Trip notes","summary":"","updated_at":"2026-10-24T01:02:03.123456+00:00","last_opened_at":null,"href":"/a/trip-notes-1"}],
         "results":[{"id":"a1","kind":"page","name":"Trip notes","summary":"","updated_at":"2026-10-24T01:02:03.123456+00:00","last_opened_at":"2026-10-25T09:00:00Z","href":"/a/trip-notes-1"},
                    {"id":"m1","kind":"memory","name":"Co-parenting","summary":"Schedule and handoffs","updated_at":"2026-10-20T00:00:00Z","last_opened_at":null,"href":"/vault/memory?open=m1"},
                    {"id":"k1","kind":"key","name":"OPENAI_KEY","summary":"1 agent allowed","updated_at":"2026-10-01T00:00:00Z","last_opened_at":null,"href":"/vault/account"},
                    {"id":"x","kind":"hologram","name":"From the future","href":"/a/future"}]}
        """
        let list = try HVCoding.decoder().decode(YoursList.self, from: Data(json.utf8))
        XCTAssertEqual(list.recent.count, 1)
        XCTAssertEqual(list.results.map(\.kind), [.page, .memory, .key, .page], "an unknown kind becomes a page")
        XCTAssertEqual(list.results[0].slug, "trip-notes-1")
        XCTAssertNotNil(list.results[0].lastOpenedAt)
        XCTAssertNil(list.results[1].slug)
        XCTAssertEqual(list.results[3].name, "From the future")
    }

    func testKeepAnswerAndEndpoint() async throws {
        let json = #"{"slug":"call-the-dentist-855py2","url":"https://hypervault.store/a/call-the-dentist-855py2","kind":"page","form":"note","title":"Call the dentist.","visibility":"private","duplicate":false,"message":"Kept. Here's the link."}"#
        let transport = MockTransport(routes: [.json(.post, "/api/keep", json)])
        let client = HVClient(baseURL: URL(string: "https://hv.test")!, transport: transport, tokens: StaticTokenProvider("t"))
        let kept = try await client.send(.keep(content: "Call the dentist.", sourcePrompt: "what to do"))
        XCTAssertEqual(kept.slug, "call-the-dentist-855py2")
        XCTAssertTrue(kept.isPrivate)
        let body = try JSONSerialization.jsonObject(with: await transport.requests.last?.httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(body?["content"] as? String, "Call the dentist.")
        XCTAssertEqual(body?["source_prompt"] as? String, "what to do")
        XCTAssertNil(body?["title"])
    }

    func testYoursQueryAndMarkOpened() async throws {
        let transport = MockTransport(routes: [.json(.get, "/api/yours", #"{"recent":[],"results":[]}"#), .json(.post, "/api/yours/open", #"{"persisted":true}"#)])
        let client = HVClient(baseURL: URL(string: "https://hv.test")!, transport: transport, tokens: StaticTokenProvider("t"))
        _ = try await client.send(.yours(filter: .memory, query: " trip ", limit: 50))
        _ = try await client.send(.markOpened(kind: .memory, id: "m1"))
        let requests = await transport.requests
        XCTAssertEqual(requests[0].url?.query, "kind=memory&q=trip&limit=50")
        let body = try JSONSerialization.jsonObject(with: requests[1].httpBody ?? Data()) as? [String: String]
        XCTAssertEqual(body, ["kind": "memory", "id": "m1"])
    }

    func testCardsDecodePerKind() throws {
        let group = try HVCoding.decoder().decode(KeptCard.self, from: Data(#"{"id":"g","kind":"group","name":"Site","href":"/g/site","updated_at":"2026-10-24T01:02:03Z","files":[{"path":"index.html","size_bytes":1200}]}"#.utf8))
        XCTAssertEqual(group.files.first?.sizeBytes, 1200)
        XCTAssertEqual(group.slug, "site")
        let key = try HVCoding.decoder().decode(KeptCard.self, from: Data(#"{"id":"k","kind":"key","name":"OPENAI_KEY","href":"/vault/account","last_used_at":null,"agents":[{"id":"a1","name":"Claude Code","key_prefix":"hv_abc1234"}],"available":[{"id":"a2","name":"Cursor","key_prefix":"hv_def5678"}]}"#.utf8))
        XCTAssertEqual(key.agents.first?.keyPrefix, "hv_abc1234")
        XCTAssertEqual(key.available.first?.name, "Cursor")
    }
}

/// A host that records what a command asked for.
@MainActor
final class SpyHost: CanvasCommandHost {
    var cards: [CanvasCard] = []
    var origin: URL? = URL(string: "https://hypervault.store")
    var events: [String] = []
    func dispatch(_ action: CanvasAction) {
        switch action {
        case .hideAll: events.append("hideAll")
        case .hide(let key): events.append("hide:\(key)")
        default: break
        }
    }
    func clearThread() { events.append("clearThread") }
    func keepThis() { events.append("keepThis") }
    func show(_ target: ShowTarget) { events.append("show:\(target.rawValue)") }
    func pull(_ query: String) { events.append("pull:\(query)") }
    func pullLink(_ link: VaultLink) { events.append("pullLink:\(link)") }
    func showAgentKeys() { events.append("agentKeys") }
    func help() { events.append("help") }
}

final class CanvasCommandRunnerTests: XCTestCase {
    // The host is main-actor isolated; the test class is not, because a main-actor
    // XCTestCase breaks test discovery on Linux.
    func run(_ body: @MainActor @Sendable () -> Void) async {
        await MainActor.run { body() }
    }

    func testCommandsGoToTheHost() async {
        await run {
            let host = SpyHost()
            XCTAssertTrue(CanvasCommandRunner.run("Show my memories.", host: host))
            XCTAssertTrue(CanvasCommandRunner.run("keep this", host: host))
            XCTAssertTrue(CanvasCommandRunner.run("pull the trip plan onto the page", host: host))
            XCTAssertTrue(CanvasCommandRunner.run("what keys does this agent have?", host: host))
            XCTAssertTrue(CanvasCommandRunner.run("help", host: host))
            XCTAssertEqual(host.events, ["show:memories", "keepThis", "pull:trip plan", "agentKeys", "help"])
        }
    }

    func testHideThatClearsTheCanvasAndTheThread() async {
        await run {
            let host = SpyHost()
            XCTAssertTrue(CanvasCommandRunner.run("hide that", host: host))
            XCTAssertEqual(host.events, ["hideAll", "clearThread"])
        }
    }

    func testHideByNameNeedsExactlyOneCardElseItIsAMessage() async {
        await run {
            let host = SpyHost()
            host.cards = [CanvasState.artifactCard(slug: "t", title: "Trip plan")]
            XCTAssertTrue(CanvasCommandRunner.run("hide the trip plan", host: host))
            XCTAssertEqual(host.events, ["hide:artifact:t"])
            XCTAssertFalse(CanvasCommandRunner.run("hide the sidebar", host: host), "no such card: it goes to chat")
        }
    }

    func testHelpWithACardOnThePageIsAQuestionAboutTheCard() async {
        await run {
            let host = SpyHost()
            host.cards = [CanvasState.artifactCard(slug: "t", title: "Trip plan")]
            XCTAssertFalse(CanvasCommandRunner.run("what does this do", host: host))
            XCTAssertTrue(host.events.isEmpty)
        }
    }

    func testAPastedVaultLinkPullsInsteadOfBeingSent() async {
        await run {
            let host = SpyHost()
            XCTAssertTrue(CanvasCommandRunner.run("https://hypervault.store/a/trip-1", host: host))
            XCTAssertEqual(host.events, ["pullLink:artifact(slug: \"trip-1\")"])
            XCTAssertFalse(CanvasCommandRunner.run("what is https://hypervault.store/a/trip-1", host: host))
        }
    }

    func testOrdinaryMessagesAreNotCommands() async {
        await run {
            let host = SpyHost()
            XCTAssertFalse(CanvasCommandRunner.run("how do I hide a div", host: host))
            XCTAssertFalse(CanvasCommandRunner.run("tell me a story about a vault", host: host))
            XCTAssertTrue(host.events.isEmpty)
        }
    }
}

final class CopyTests: XCTestCase {
    func testAgoLines() {
        XCTAssertEqual(HVCopy.agoLine(seconds: 5), "Just now")
        XCTAssertEqual(HVCopy.agoLine(seconds: -50), "Just now")
        XCTAssertEqual(HVCopy.agoLine(seconds: 5 * 60), "5 min ago")
        XCTAssertEqual(HVCopy.agoLine(seconds: 3 * 3600), "3 hr ago")
        XCTAssertEqual(HVCopy.agoLine(seconds: 30 * 3600), "Yesterday")
        XCTAssertEqual(HVCopy.agoLine(seconds: 5 * 86_400), "5 days ago")
        XCTAssertEqual(HVCopy.agoLine(seconds: 65 * 86_400), "2 months ago")
        XCTAssertEqual(HVCopy.agoLine(seconds: 400 * 86_400), "1 year ago")
    }

    func testBytesAndCounts() {
        XCTAssertEqual(HVCopy.bytesLine(0), "0 B")
        XCTAssertEqual(HVCopy.bytesLine(512), "512 B")
        XCTAssertEqual(HVCopy.bytesLine(2150), "2.1 KB")
        XCTAssertEqual(HVCopy.bytesLine(3 * 1024 * 1024), "3 MB")
        XCTAssertEqual(HVCopy.bytesLine(1_048_575), "1 MB")
        XCTAssertEqual(HVCopy.filesCountLine(1), "1 file")
        XCTAssertEqual(HVCopy.filesCountLine(0), "No files")
        XCTAssertEqual(HVCopy.agentsAllowedLine(0), "No agents allowed")
        XCTAssertEqual(HVCopy.pastedLine(characters: 1234), "Pasted - 1,234 characters")
    }

    func testStarterPromptPointsAtStartMdAndCarriesNoKey() {
        let prompt = HVCopy.starterPrompt(origin: "https://hypervault.store/")
        XCTAssertTrue(prompt.hasPrefix("Read https://hypervault.store/start.md then help me keep one thing in my HyperVault."))
        XCTAssertEqual(prompt.split(separator: "\n").count, 3)
        XCTAssertFalse(prompt.contains("hv_"))
    }
}

final class PasteDiffTests: XCTestCase {
    func testPasteAtTheEnd() {
        XCTAssertEqual(PasteDiff.insertion(old: "Hello ", new: "Hello a long pasted page"), "a long pasted page")
    }

    func testPasteInTheMiddle() {
        XCTAssertEqual(PasteDiff.insertion(old: "ab", new: "a<PASTE>b"), "<PASTE>")
    }

    func testIntoAnEmptyField() {
        XCTAssertEqual(PasteDiff.insertion(old: "", new: "everything"), "everything")
    }

    func testReplacingOrDeletingIsNotAPaste() {
        XCTAssertNil(PasteDiff.insertion(old: "abc", new: "xyz and more"))
        XCTAssertNil(PasteDiff.insertion(old: "hello", new: "hell"))
        XCTAssertNil(PasteDiff.insertion(old: "same", new: "same"))
    }

    func testRepeatedCharactersStillFindTheInsertion() {
        XCTAssertEqual(PasteDiff.insertion(old: "aa", new: "aaaa")?.count, 2)
    }
}
