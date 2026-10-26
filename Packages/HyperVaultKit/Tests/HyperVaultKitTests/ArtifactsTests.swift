import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

/// Fixtures are the routes' real output: app/api/artifacts/route.ts (GET, PATCH, DELETE),
/// app/api/save/route.ts, app/api/artifacts/[slug]/{feedback,repair}/route.ts, app/api/jobs/[id]/route.ts.
final class ArtifactsTests: XCTestCase {
    let base = URL(string: "https://hv.test")!

    func client(_ transport: MockTransport) -> HVClient {
        HVClient(baseURL: base, transport: transport, tokens: StaticTokenProvider(), sleep: { _ in })
    }

    // MARK: List

    func testListDecodesTheRoutesRowsAndReadsMissingVisibilityAsPublic() throws {
        let json = """
        {"items":[
         {"slug":"pomodoro-timer-x7k2p9","title":"Pomodoro Timer","type":"react","tags":["timer","focus"],"source_prompt":"Make a pomodoro timer","is_pwa":true,"is_jsx":true,"visibility":"private","icon":"P","created_at":"2026-10-20T10:00:00.123456+00:00","url":"https://hv.test/a/pomodoro-timer-x7k2p9"},
         {"slug":"old-page-abc","title":"Old page","type":"html","tags":null,"source_prompt":null,"is_pwa":false,"is_jsx":false,"created_at":"2025-01-02T03:04:05.000Z","url":"https://hv.test/a/old-page-abc"},
         {"slug":"trip-1","title":"Trip","type":"group","tags":[],"visibility":"password","created_at":"2026-10-01T00:00:00Z"},
         {"slug":"scan-9","title":"Scan","type":"pdf","tags":["agent-setup-challenge"],"visibility":"mystery","created_at":"2026-10-01T00:00:00Z"}
        ]}
        """
        let list = try HVCoding.decoder().decode(ArtifactList.self, from: Data(json.utf8))
        XCTAssertEqual(list.items.map(\.slug), ["pomodoro-timer-x7k2p9", "old-page-abc", "trip-1", "scan-9"])
        XCTAssertEqual(list.items[0].visibility, .private)
        XCTAssertEqual(list.items[0].typeLabel, "react")
        XCTAssertEqual(list.items[0].icon, "P")
        XCTAssertEqual(list.items[1].visibility, .public, "a row from before the privacy migration is public")
        XCTAssertEqual(list.items[1].tags, [])
        XCTAssertEqual(list.items[1].kind, .page)
        XCTAssertEqual(list.items[2].kind, .group)
        XCTAssertTrue(list.items[2].isGroup)
        XCTAssertEqual(list.items[2].visibility, .password)
        XCTAssertEqual(list.items[3].kind, .file)
        XCTAssertTrue(list.items[3].isStoredFile)
        XCTAssertEqual(list.items[3].visibility, .private, "a word this build does not know is private")
        XCTAssertTrue(list.items[3].isBookkeeping)
        XCTAssertFalse(list.items[0].isBookkeeping)
    }

    func testListSurvivesTheCacheRoundTrip() throws {
        let item = ArtifactSummary(slug: "a-1", title: "A", type: "react", tags: ["x"], sourcePrompt: "p", isPwa: true, isJsx: true, visibility: .password, icon: "A", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let data = try HVCoding.encoder(.verbatim).encode(CacheEntry(value: ArtifactList(items: [item]), savedAt: Date()))
        let back = try HVCoding.decoder(.verbatim).decode(CacheEntry<ArtifactList>.self, from: data)
        XCTAssertEqual(back.value.items, [item])
    }

    func testAnEmptyOrFutureServerStillDecodes() throws {
        XCTAssertEqual(try HVCoding.decoder().decode(ArtifactList.self, from: Data("{}".utf8)).items.count, 0)
        let future = try HVCoding.decoder().decode(ArtifactSummary.self, from: Data(#"{"slug":"s","brand_new":{"a":1}}"#.utf8))
        XCTAssertEqual(future.title, "Untitled")
    }

    // MARK: Icon

    func testIconHueMatchesTheWeb() {
        // lib/pwa.ts iconGradient: hash = imul(hash, 31) + charCode, >>> 0, % 360 (values from node).
        XCTAssertEqual(ArtifactIcon.hue(seed: "pomodoro-timer-x7k2p9"), 307)
        XCTAssertEqual(ArtifactIcon.hue(seed: "air-buds-zjliak"), 135)
        XCTAssertEqual(ArtifactIcon.hue(seed: "a"), 97)
        XCTAssertEqual(ArtifactIcon.hue(seed: "trip-notes-\u{e9}"), 253)
        XCTAssertEqual(ArtifactIcon.secondHue(seed: "a"), 139)
        XCTAssertEqual(ArtifactIcon.secondHue(seed: "pomodoro-timer-x7k2p9"), 349)
    }

    func testIconGlyphs() {
        XCTAssertEqual(ArtifactIcon.initial("pomodoro"), "P")
        XCTAssertEqual(ArtifactIcon.initial("  \u{1F680} 3 days"), "3")
        XCTAssertEqual(ArtifactIcon.initial("\u{1F680}\u{1F680}"), "#")
        XCTAssertEqual(ArtifactIcon.normalizedGlyph("  \u{1F680}  "), "\u{1F680}")
        XCTAssertEqual(ArtifactIcon.normalizedGlyph("abcdef"), "ab")
        XCTAssertNil(ArtifactIcon.normalizedGlyph("   "))
        XCTAssertNil(ArtifactIcon.normalizedGlyph(nil))
        XCTAssertEqual(ArtifactIcon.glyph(icon: nil, title: "zebra"), "Z")
        XCTAssertEqual(ArtifactIcon.glyph(icon: "\u{1F4A1}", title: "zebra"), "\u{1F4A1}")
    }

    // MARK: Visibility, delete, icon

    func testSetVisibilitySendsTheSlugAndReadsTheSentence() async throws {
        let transport = MockTransport(routes: [
            .json(.patch, "/api/artifacts", #"{"artifact":{"id":"9b2d","slug":"p-1","title":"P","visibility":"public","icon":null},"message":"“P” is now public — anyone with the link can open it."}"#),
        ])
        let result = try await client(transport).send(.setArtifactVisibility(slug: "p-1", to: .public))
        XCTAssertEqual(result.artifact.visibility, .public)
        XCTAssertTrue(result.message.contains("anyone with the link"))
        let sent = await transport.requests.first
        XCTAssertEqual(sent?.httpMethod, "PATCH")
        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(sent?.httpBody)) as? [String: String]
        XCTAssertEqual(body, ["slug": "p-1", "visibility": "public"])
    }

    func testSetIconNullClearsIt() async throws {
        let transport = MockTransport(routes: [
            .json(.patch, "/api/artifacts", #"{"artifact":{"id":"9b2d","slug":"p-1","title":"P","visibility":"private","icon":null},"message":"back to automatic"}"#),
        ])
        _ = try await client(transport).send(.setArtifactIcon(slug: "p-1", glyph: nil))
        let sent = await transport.requests.first
        let text = String(decoding: try XCTUnwrap(sent?.httpBody), as: UTF8.self)
        XCTAssertTrue(text.contains("\"icon\":null"))
    }

    func testDeleteIgnoresTheEchoedContent() async throws {
        let transport = MockTransport(routes: [
            .json(.delete, "/api/artifacts", #"{"deleted":{"id":"9b2d","slug":"p-1","title":"P","type":"html","content":"<h1>big</h1>"},"message":"Deleted “P” — its link is gone for good."}"#),
        ])
        let result = try await client(transport).send(.deleteArtifact(slug: "p-1"))
        XCTAssertEqual(result.deleted.slug, "p-1")
        XCTAssertTrue(result.message.hasPrefix("Deleted"))
    }

    func testRefusalsKeepTheServersSentence() async {
        let transport = MockTransport(routes: [
            .failure(.patch, "/api/artifacts", status: 403, message: "Only the owner can change the icon."),
            .failure(.delete, "/api/artifacts", status: 404, message: "No artifact matching \"p-1\" in your vault."),
        ])
        do {
            _ = try await client(transport).send(.setArtifactIcon(slug: "p-1", glyph: "P"))
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual((error as? HVError)?.userMessage, "Only the owner can change the icon.")
        }
        do {
            _ = try await client(transport).send(.deleteArtifact(slug: "p-1"))
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual((error as? HVError)?.status, 404)
        }
    }

    // MARK: Save

    func testSaveRequestUsesTheRoutesFieldNames() throws {
        let request = ArtifactSaveRequest(
            content: "<h1>Hi</h1>", title: "Hi", type: "jsx", tags: ["a"], connectTo: ["other-1"],
            makePwa: false, forceHtml: true, mutable: true, visibility: .public, sourcePrompt: "make hi"
        )
        let data = try HVCoding.encoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["content"] as? String, "<h1>Hi</h1>")
        XCTAssertEqual(object["connect_to"] as? [String], ["other-1"])
        XCTAssertEqual(object["make_pwa"] as? Bool, false)
        XCTAssertEqual(object["force_html"] as? Bool, true)
        XCTAssertEqual(object["mutable"] as? Bool, true)
        XCTAssertEqual(object["visibility"] as? String, "public")
        XCTAssertEqual(object["source_prompt"] as? String, "make hi")
        XCTAssertEqual(object["type"] as? String, "jsx")

        let minimal = try JSONSerialization.jsonObject(with: try HVCoding.encoder().encode(ArtifactSaveRequest(content: "x"))) as? [String: Any]
        XCTAssertNil(minimal?["title"], "an untitled save leaves the title out so the server says Untitled")
        XCTAssertNil(minimal?["source_prompt"])
        XCTAssertEqual(minimal?["visibility"] as? String, "private", "new pages are private unless the person says otherwise")
    }

    func testSaveAnswers() async throws {
        let fresh = #"""
        {"url":"https://hv.test/a/hi-abc123","slug":"hi-abc123","is_jsx":true,"is_pwa":true,"visibility":"private","mutable":false,"connections":{"manual":1,"auto":2},"message":"Kept. Here's the link. It was a React component, so it now runs as a page of its own. Only you can open it."}
        """#
        let duplicate = #"""
        {"url":"https://hv.test/a/hi-abc123","slug":"hi-abc123","is_jsx":false,"is_pwa":true,"visibility":"public","mutable":false,"duplicate":true,"message":"Already kept. Here's the link. It is kept as \"Hi\", so no copy was made."}
        """#
        let transport = MockTransport(routes: [.json(.post, "/api/save", fresh)])
        let kept = try await client(transport).send(.saveArtifact(ArtifactSaveRequest(content: "x")))
        XCTAssertEqual(kept.slug, "hi-abc123")
        XCTAssertTrue(kept.isJsx)
        XCTAssertFalse(kept.duplicate)
        XCTAssertEqual(kept.connections, ArtifactSaveResult.Connections(manual: 1, auto: 2))
        XCTAssertTrue(kept.message.hasPrefix("Kept. Here's the link."))

        await transport.add(.json(.post, "/api/save", duplicate))
        let again = try await client(transport).send(.saveArtifact(ArtifactSaveRequest(content: "x")))
        XCTAssertTrue(again.duplicate)
        XCTAssertEqual(again.visibility, .public)
        XCTAssertTrue(again.message.hasPrefix("Already kept."))
    }

    func testSaveRefusalsAreTheRoutesWords() async {
        let transport = MockTransport(routes: [
            .failure(.post, "/api/save", status: 413, message: "Artifact is over the 1 MB limit. Trim embedded assets and try again."),
        ])
        do {
            _ = try await client(transport).send(.saveArtifact(ArtifactSaveRequest(content: "x")))
            XCTFail("expected 413")
        } catch {
            XCTAssertEqual((error as? HVError)?.status, 413)
            XCTAssertTrue((error as? HVError)?.userMessage.contains("1 MB") == true)
        }
    }

    // MARK: Feedback, repair, jobs

    func testFeedback() async throws {
        let transport = MockTransport(routes: [
            .json(.get, "/api/artifacts/p-1/feedback", #"{"feedback":"up"}"#),
            .json(.post, "/api/artifacts/p-1/feedback", #"{"slug":"p-1","feedback":null,"message":"Rating cleared."}"#),
        ])
        let api = client(transport)
        let state = try await api.send(.artifactFeedback(slug: "p-1"))
        XCTAssertEqual(state.feedback, .up)
        let cleared = try await api.send(.rateArtifact(slug: "p-1", nil))
        XCTAssertEqual(cleared.message, "Rating cleared.")
        let sentRequests = await transport.requests
        let text = String(decoding: try XCTUnwrap(sentRequests.last?.httpBody), as: UTF8.self)
        XCTAssertTrue(text.contains("\"feedback\":null"))

        let none = try HVCoding.decoder().decode(ArtifactFeedbackState.self, from: Data(#"{"feedback":null}"#.utf8))
        XCTAssertNil(none.feedback)
    }

    func testRepairStartsAJobAndPollsIt() async throws {
        let transport = MockTransport(routes: [
            MockRoute(.post, "/api/artifacts/p-1/repair") { _ in HTTPResponse(status: 202, data: Data(#"{"job_id":"j1","status":"pending"}"#.utf8)) },
            .json(.get, "/api/jobs/j1", #"{"job":{"id":"j1","kind":"artifact_repair","status":"succeeded","label":"Repairing","result":{"changed":true,"message":"Claude took a pass at it. Reload the artifact to see if it renders now.","source":"<h1/>"},"error":null}}"#),
            .json(.post, "/api/jobs/j1", #"{"ok":true}"#),
        ])
        let api = client(transport)
        let start = try await api.send(.repairArtifact(slug: "p-1", renderError: "SyntaxError: x"))
        XCTAssertEqual(start.jobId, "j1")
        let sentRequests = await transport.requests
        let sent = String(decoding: try XCTUnwrap(sentRequests.first?.httpBody), as: UTF8.self)
        XCTAssertTrue(sent.contains("\"render_error\":\"SyntaxError: x\""))

        let job = try await api.send(.artifactJob(id: "j1"))
        XCTAssertEqual(job.status, .succeeded)
        XCTAssertTrue(job.isFinished)
        XCTAssertEqual(job.result?.changed, true)
        _ = try await api.send(.acknowledgeArtifactJob(id: "j1"))
    }

    func testRepairWithoutABackendSaysSo() async {
        let transport = MockTransport(routes: [
            .json(.post, "/api/artifacts/p-1/repair", #"{"error":"No LLM backend is connected — connect one (OpenAI, Anthropic, a local model, …) from Chat, then try the repair again.","needs_backend":true}"#, status: 400),
        ])
        do {
            _ = try await client(transport).send(.repairArtifact(slug: "p-1"))
            XCTFail("expected 400")
        } catch let error as HVError {
            XCTAssertEqual(error.failure?.body?["needs_backend"]?.bool, true)
            XCTAssertTrue(error.userMessage.contains("No LLM backend"))
        } catch {
            XCTFail("\(error)")
        }
    }

    func testAJobThatIsStillRunningIsNotFinished() throws {
        let job = try HVCoding.decoder().decode(ArtifactJob.self, from: Data(#"{"id":"j","status":"running","result":null,"error":null}"#.utf8))
        XCTAssertFalse(job.isFinished)
        let odd = try HVCoding.decoder().decode(ArtifactJob.self, from: Data(#"{"id":"j","status":"brand_new"}"#.utf8))
        XCTAssertEqual(odd.status, .unknown)
    }
}

/// What an icon and a type are called on screen.
final class ArtifactIconAndTypeNameTests: XCTestCase {
    func testASwatchIsTheColourCSSWouldDraw() {
        // hsl(0, 100%, 50%) is red; hsl(120, 100%, 25%) is a dark green; a grey has no saturation.
        let red = ArtifactIcon.Swatch(hue: 0, saturation: 1, lightness: 0.5).rgb
        XCTAssertEqual([red.red, red.green, red.blue], [1, 0, 0])
        let green = ArtifactIcon.Swatch(hue: 120, saturation: 1, lightness: 0.25).rgb
        XCTAssertEqual(green.red, 0, accuracy: 0.0001)
        XCTAssertEqual(green.green, 0.5, accuracy: 0.0001)
        XCTAssertEqual(green.blue, 0, accuracy: 0.0001)
        let grey = ArtifactIcon.Swatch(hue: 200, saturation: 0, lightness: 0.4).rgb
        XCTAssertEqual(grey.red, 0.4, accuracy: 0.0001)
        XCTAssertEqual(grey.blue, 0.4, accuracy: 0.0001)
    }

    func testStopsAreTheWebsTwoColoursFromTheSlug() {
        let stops = ArtifactIcon.stops(seed: "pomodoro-timer-x7k2p9")
        XCTAssertEqual(stops.first.hue, ArtifactIcon.hue(seed: "pomodoro-timer-x7k2p9"))
        XCTAssertEqual(stops.second.hue, ArtifactIcon.secondHue(seed: "pomodoro-timer-x7k2p9"), accuracy: 0.0001)
        XCTAssertEqual(stops.first.lightness, 0.62)
        XCTAssertEqual(stops.second.lightness, 0.46)
    }

    func testTheGlyphGoesDarkOnlyWhereWhiteCannotBeRead() {
        // Every hue the hash can reach: white is kept only where it holds 3:1 on the brightest part of the tile.
        var dark = 0
        for degrees in 0..<360 {
            let hue = Double(degrees)
            let contrast = ArtifactIcon.whiteGlyphContrast(hue: hue)
            if ArtifactIcon.prefersDarkGlyph(hue: hue) {
                dark += 1
                XCTAssertLessThan(contrast, 3, "hue \(degrees)")
            } else {
                XCTAssertGreaterThanOrEqual(contrast, 3, "hue \(degrees)")
            }
        }
        XCTAssertGreaterThan(dark, 0, "the yellows and greens cannot carry a white letter")
        XCTAssertLessThan(dark, 360, "the blues, purples and pinks still do")
    }

    func testTheYellowGreensThatWereUnreadableGoDark() {
        // The slugs of the two tiles QA measured at under 2:1 ("Lease.pdf" and "Budget 2026 Q4").
        XCTAssertTrue(ArtifactIcon.prefersDarkGlyph(seed: "lease-pdf-123456"))
        XCTAssertTrue(ArtifactIcon.prefersDarkGlyph(seed: "budget-2026-q4"))
        XCTAssertFalse(ArtifactIcon.prefersDarkGlyph(seed: "pomodoro-timer-x7k2p9"))
        XCTAssertFalse(ArtifactIcon.prefersDarkGlyph(seed: "trip-planner-abc123"))
    }

    func testTypesReadAsWordsNotCodes() {
        XCTAssertEqual(ArtifactTypeName.name(type: "react"), "React page")
        XCTAssertEqual(ArtifactTypeName.name(type: "html", isJsx: true), "React page")
        XCTAssertEqual(ArtifactTypeName.name(type: "html"), "HTML page")
        XCTAssertEqual(ArtifactTypeName.name(type: "pdf"), "PDF")
        XCTAssertEqual(ArtifactTypeName.name(type: "image"), "Image")
        XCTAssertEqual(ArtifactTypeName.name(type: "group"), "Group")
        XCTAssertEqual(ArtifactTypeName.name(type: "svg"), "SVG")
        XCTAssertEqual(ArtifactTypeName.name(type: "spreadsheet"), "Spreadsheet")
        XCTAssertEqual(ArtifactTypeName.name(type: ""), "Page")
    }

    func testASlugReadsAsATitleWhenNothingBetterIsKnown() {
        XCTAssertEqual(ArtifactSlugName.readable("pomodoro-timer-x7k2p9"), "Pomodoro timer")
        XCTAssertEqual(ArtifactSlugName.readable("lease-pdf-123456"), "Lease pdf")
        XCTAssertEqual(ArtifactSlugName.readable("budget-2026-q4"), "Budget 2026 q4", "a short last word is not a suffix")
        XCTAssertEqual(ArtifactSlugName.readable("k3m9zz"), "K3m9zz", "a slug of only the suffix is all there is")
        XCTAssertEqual(ArtifactSlugName.readable(""), "")
    }

    func testARowAndASharedRowUseTheSameNames() {
        XCTAssertEqual(ArtifactSummary(slug: "a", title: "A", type: "react", isJsx: true).typeName, "React page")
        XCTAssertEqual(ArtifactSummary(slug: "a", title: "A", type: "react", isJsx: true).typeLabel, "react", "the web's word stays available")
        XCTAssertEqual(SharedWithYouItem(shareId: "s", slug: "a", title: "A", type: "group").typeName, "Group")
    }
}

final class LibraryCopyTests: XCTestCase {
    func testAgoMatchesTheWebsRounding() {
        XCTAssertEqual(LibraryCopy.ago(seconds: 0), "Just now")
        XCTAssertEqual(LibraryCopy.ago(seconds: -30), "Just now")
        XCTAssertEqual(LibraryCopy.ago(seconds: .nan), "Just now")
        XCTAssertEqual(LibraryCopy.ago(seconds: 59), "Just now")
        XCTAssertEqual(LibraryCopy.ago(seconds: 60), "1 min ago")
        XCTAssertEqual(LibraryCopy.ago(seconds: 3_599), "59 min ago")
        XCTAssertEqual(LibraryCopy.ago(seconds: 3_600), "1 hr ago")
        XCTAssertEqual(LibraryCopy.ago(seconds: 86_400), "Yesterday")
        XCTAssertEqual(LibraryCopy.ago(seconds: 86_400 * 3), "3 days ago")
        XCTAssertEqual(LibraryCopy.ago(seconds: 86_400 * 45), "1 month ago")
        XCTAssertEqual(LibraryCopy.ago(seconds: 86_400 * 100), "3 months ago")
        XCTAssertEqual(LibraryCopy.ago(seconds: 86_400 * 400), "1 year ago")
        XCTAssertEqual(LibraryCopy.ago(seconds: 86_400 * 800), "2 years ago")
    }

    func testRowsAreTimedByLastOpenThenLastChange() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let opened = KeptItem(id: "1", kind: .page, name: "A", updatedAt: now.addingTimeInterval(-86_400 * 10), lastOpenedAt: now.addingTimeInterval(-120), href: "/a/a")
        let changed = KeptItem(id: "2", kind: .page, name: "B", updatedAt: now.addingTimeInterval(-7_200), href: "/a/b")
        let neither = KeptItem(id: "3", kind: .page, name: "C", href: "/a/c")
        XCTAssertEqual(LibraryCopy.ago(for: opened, now: now), "2 min ago")
        XCTAssertEqual(LibraryCopy.ago(for: changed, now: now), "2 hr ago")
        XCTAssertNil(LibraryCopy.ago(for: neither, now: now))
    }

    func testEmptyLines() {
        XCTAssertEqual(LibraryCopy.emptyLine(filter: .all, query: ""), "Nothing kept yet.")
        XCTAssertEqual(LibraryCopy.emptyLine(filter: .all, query: "  "), "Nothing kept yet.")
        XCTAssertEqual(LibraryCopy.emptyLine(filter: .all, query: "trip"), "Nothing here.")
        XCTAssertEqual(LibraryCopy.emptyLine(filter: .key, query: ""), "Nothing here.")
        XCTAssertEqual(LibraryCopy.truncated, "These are the most recent. Search by name to find the rest.")
    }
}
