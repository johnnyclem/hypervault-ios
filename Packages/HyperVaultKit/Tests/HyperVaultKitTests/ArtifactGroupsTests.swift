import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

/// The rules and the preview are ported from the web's lib/artifacts/__tests__/{group-files,group-preview}.test.ts,
/// the wire from app/api/artifact-groups/**.
final class ArtifactGroupsTests: XCTestCase {
    let base = URL(string: "https://hv.test")!

    func client(_ transport: MockTransport) -> HVClient {
        HVClient(baseURL: base, transport: transport, tokens: StaticTokenProvider(), sleep: { _ in })
    }

    // MARK: Paths

    func testNormalizing() {
        XCTAssertEqual(ArtifactGroupRules.normalize("./index.html"), "index.html")
        XCTAssertEqual(ArtifactGroupRules.normalize("/index.html"), "index.html")
        XCTAssertEqual(ArtifactGroupRules.normalize("  app.js  "), "app.js")
        XCTAssertEqual(ArtifactGroupRules.normalize("styles/app.css"), "styles/app.css")
    }

    func testValidPaths() throws {
        XCTAssertEqual(try ArtifactGroupRules.validate(path: "index.html").get(), "index.html")
        XCTAssertEqual(try ArtifactGroupRules.validate(path: "scripts/app.js").get(), "scripts/app.js")
        XCTAssertEqual(try ArtifactGroupRules.validate(path: "./App.JSX").get(), "App.JSX")
        for ext in ["html", "css", "js", "jsx"] {
            XCTAssertNoThrow(try ArtifactGroupRules.validate(path: "file.\(ext)").get())
        }
    }

    func testInvalidPathsSayWhy() {
        func message(_ path: String) -> String? {
            if case .failure(let error) = ArtifactGroupRules.validate(path: path) { return error.message }
            return nil
        }
        XCTAssertEqual(message("   "), "A file path is required.")
        XCTAssertTrue(message(String(repeating: "a", count: 250) + ".html")?.contains("character path limit") == true)
        XCTAssertTrue(message("index html.html")?.contains("aren't allowed") == true)
        XCTAssertTrue(message("../secrets.html")?.contains("..") == true)
        XCTAssertNotNil(message("styles/"))
        XCTAssertTrue(message("data.json")?.contains("unsupported file type") == true)
        XCTAssertNotNil(message("README"))
        XCTAssertNotNil(message("a//b.js"))
        XCTAssertNotNil(message("back\\slash.js"))
    }

    func testContentSize() {
        XCTAssertNil(ArtifactGroupRules.validate(path: "index.html", content: "<h1>hi</h1>"))
        let error = ArtifactGroupRules.validate(path: "app.js", content: String(repeating: "x", count: ArtifactGroupRules.maxFileBytes + 1))
        XCTAssertTrue(error?.message.contains("per-file limit") == true)
    }

    // MARK: Whole sets

    func testWholeSets() {
        let index = ArtifactGroupFile(path: "index.html", content: "<h1>hi</h1>")
        XCTAssertNil(ArtifactGroupRules.validate(files: [index]))
        XCTAssertNil(ArtifactGroupRules.validate(files: [index, ArtifactGroupFile(path: "styles.css", content: "body{}")]))
        XCTAssertNil(ArtifactGroupRules.validate(files: [ArtifactGroupFile(path: "./index.html", content: "x")]), "a leading ./ still counts as the root index")
        XCTAssertTrue(ArtifactGroupRules.validate(files: [])?.message.contains("At least one file") == true)
        XCTAssertTrue(ArtifactGroupRules.validate(files: [ArtifactGroupFile(path: "styles.css", content: "")])?.message.contains("index.html") == true)
        XCTAssertTrue(ArtifactGroupRules.validate(files: [ArtifactGroupFile(path: "pages/index.html", content: "")])?.message.contains("index.html") == true)
        XCTAssertTrue(ArtifactGroupRules.validate(files: [index, ArtifactGroupFile(path: "app.js", content: ""), ArtifactGroupFile(path: "APP.js", content: "")])?.message.contains("collide") == true)
        XCTAssertTrue(ArtifactGroupRules.validate(files: [index, index])?.message.contains("Duplicate") == true)
        let tooMany = (0..<ArtifactGroupRules.maxFiles).map { ArtifactGroupFile(path: "f\($0).js", content: "") } + [index]
        XCTAssertTrue(ArtifactGroupRules.validate(files: tooMany)?.message.contains("Too many files") == true)
    }

    func testTheTotalSizeCap() {
        let big = String(repeating: "x", count: ArtifactGroupRules.maxFileBytes)
        let files = [ArtifactGroupFile(path: "index.html", content: big)] + (1...4).map { ArtifactGroupFile(path: "f\($0).js", content: big) }
        XCTAssertTrue(ArtifactGroupRules.validate(files: files)?.message.contains("total limit") == true)
    }

    func testOnlyTheRootIndexIsProtected() {
        XCTAssertFalse(ArtifactGroupRules.isRemovable("index.html"))
        XCTAssertFalse(ArtifactGroupRules.isRemovable("./index.html"))
        XCTAssertTrue(ArtifactGroupRules.isRemovable("pages/index.html"))
        XCTAssertTrue(ArtifactGroupRules.isRemovable("app.js"))
    }

    func testFilesSortIndexFirst() {
        let sorted = ArtifactGroupRules.sorted(["styles.css", "app.js", "index.html", "a/b.js", "app10.js", "app2.js"].map { ArtifactGroupFile(path: $0, content: "") })
        XCTAssertEqual(sorted.map(\.path), ["index.html", "a/b.js", "app.js", "app2.js", "app10.js", "styles.css"])
    }

    func testTheStarterGroupIsValid() {
        XCTAssertNil(ArtifactGroupRules.validate(files: ArtifactGroupRules.starterFiles))
        XCTAssertEqual(ArtifactGroupRules.starterFiles.map(\.path), ["index.html", "styles.css", "app.js"])
    }

    // MARK: Preview

    let files = [
        ArtifactGroupFile(path: "index.html", content: "<html></html>"),
        ArtifactGroupFile(path: "styles.css", content: "body{margin:0}"),
        ArtifactGroupFile(path: "app.js", content: "console.log(1);"),
        ArtifactGroupFile(path: "scripts/app.jsx", content: "const App = () => null;"),
    ]

    func preview(_ html: String) -> String { ArtifactGroupPreview.document(indexHTML: html, files: files) }

    func testPreviewInlinesLocalFiles() {
        XCTAssertEqual(preview(#"<head><link rel="stylesheet" href="styles.css"></head>"#), "<head><style>body{margin:0}</style></head>")
        XCTAssertEqual(preview(#"<script src="app.js"></script>"#), "<script>console.log(1);</script>")
        XCTAssertEqual(
            preview(#"<script type="text/babel" src="scripts/app.jsx" data-presets="react"></script>"#),
            #"<script type="text/babel" data-presets="react">const App = () => null;</script>"#
        )
        XCTAssertEqual(preview(#"<script src="./app.js"></script>"#), "<script>console.log(1);</script>")
        XCTAssertEqual(preview(#"<script src="/app.js"></script>"#), "<script>console.log(1);</script>")
        XCTAssertEqual(preview("<script src='app.js'></script>"), "<script>console.log(1);</script>")
        XCTAssertEqual(
            preview(#"<link rel="stylesheet" href="styles.css"><script src="app.js"></script>"#),
            "<style>body{margin:0}</style><script>console.log(1);</script>"
        )
    }

    func testPreviewLeavesWhatItCannotInlineAlone() {
        let cdn = #"<script src="https://unpkg.com/react@18/umd/react.production.min.js"></script>"#
        XCTAssertEqual(preview(cdn), cdn)
        let relative = #"<script src="//cdn.example.com/lib.js"></script>"#
        XCTAssertEqual(preview(relative), relative)
        let icon = #"<link rel="icon" href="favicon.ico">"#
        XCTAssertEqual(preview(icon), icon)
        let missing = #"<script src="missing.js"></script>"#
        XCTAssertEqual(preview(missing), missing)
        let data = #"<script src="data:text/javascript,1"></script>"#
        XCTAssertEqual(preview(data), data)
    }

    func testPreviewTakesDollarSignsAndBackslashesVerbatim() {
        let tricky = [ArtifactGroupFile(path: "app.js", content: #"const price = "$1"; const re = /\d+$/; "$&""#)]
        let out = ArtifactGroupPreview.document(indexHTML: #"<script src="app.js"></script>"#, files: tricky)
        XCTAssertEqual(out, #"<script>const price = "$1"; const re = /\d+$/; "$&"</script>"#)
    }

    // MARK: Wire

    func testGroupDetailAndList() async throws {
        let detail = #"""
        {"slug":"trip-1","title":"Trip","tags":["demo"],"visibility":"private","url":"https://hv.test/g/trip-1","created_at":"2026-10-01T00:00:00.000Z",
         "files":[{"path":"index.html","content":"<h1>hi</h1>","size_bytes":11},{"path":"app.js","content":"1","size_bytes":1}]}
        """#
        let list = #"{"items":[{"id":"g1","slug":"trip-1","title":"Trip","tags":["demo"],"visibility":"private","created_at":"2026-10-01T00:00:00.000Z","url":"https://hv.test/g/trip-1"}]}"#
        let transport = MockTransport(routes: [
            .json(.get, "/api/artifact-groups/trip-1", detail),
            .json(.get, "/api/artifact-groups", list),
        ])
        let api = client(transport)
        let group = try await api.send(.artifactGroup(slug: "trip-1"))
        XCTAssertEqual(group.files.map(\.path), ["index.html", "app.js"])
        XCTAssertEqual(group.files[0].sizeBytes, 11)
        XCTAssertEqual(group.visibility, .private)
        let items = try await api.send(.artifactGroups).items
        XCTAssertEqual(items.map(\.slug), ["trip-1"])
    }

    func testCreateSendsEveryFile() async throws {
        let transport = MockTransport(routes: [
            .json(.post, "/api/artifact-groups", #"{"slug":"trip-1","title":"Trip","url":"https://hv.test/g/trip-1","visibility":"private","files":["index.html","app.js"],"message":"\"Trip\" is live at https://hv.test/g/trip-1 — edit files any time with the artifact-group file endpoints."}"#),
        ])
        let made = try await client(transport).send(.createArtifactGroup(title: "Trip", files: ArtifactGroupRules.starterFiles, tags: ["demo"], visibility: .private))
        XCTAssertEqual(made.slug, "trip-1")
        let first = await firstRequest(transport)
        let sent = try XCTUnwrap(first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(sent.httpBody)) as? [String: Any])
        XCTAssertEqual(body["title"] as? String, "Trip")
        XCTAssertEqual(body["visibility"] as? String, "private")
        XCTAssertEqual((body["files"] as? [[String: String]])?.map { $0["path"] ?? "" }, ["index.html", "styles.css", "app.js"])
    }

    func testFileCallsUseTheNestedPathAsItIs() async throws {
        let transport = MockTransport(routes: [
            .json(.put, "/api/artifact-groups/trip-1/files/styles/app.css", #"{"path":"styles/app.css","size_bytes":4,"message":"Wrote \"styles/app.css\" in \"Trip\"."}"#),
            .json(.post, "/api/artifact-groups/trip-1/files", #"{"path":"x.js","size_bytes":0,"message":"Added \"x.js\" to \"Trip\"."}"#),
            .json(.delete, "/api/artifact-groups/trip-1/files/old.js", #"{"deleted":"old.js","message":"Removed \"old.js\" from \"Trip\"."}"#),
            .json(.patch, "/api/artifact-groups/trip-1", #"{"slug":"trip-1","title":"Trip 2","tags":[],"visibility":"public","url":"u","message":"Updated \"Trip 2\"."}"#),
            .json(.delete, "/api/artifact-groups/trip-1", #"{"deleted":{"slug":"trip-1"},"message":"Deleted \"Trip\" — its link is gone for good."}"#),
        ])
        let api = client(transport)
        _ = try await api.send(.writeGroupFile(slug: "trip-1", path: "styles/app.css", content: "body{}"))
        _ = try await api.send(.addGroupFile(slug: "trip-1", path: "x.js", content: ""))
        _ = try await api.send(.deleteGroupFile(slug: "trip-1", path: "old.js"))
        let updated = try await api.send(.updateArtifactGroup(slug: "trip-1", title: "Trip 2", visibility: .public))
        XCTAssertTrue(updated.message.contains("Trip 2"))
        let deleted = try await api.send(.deleteArtifactGroup(slug: "trip-1"))
        XCTAssertTrue(deleted.message.hasPrefix("Deleted"))
        let requests = await transport.requests
        XCTAssertEqual(requests.map { $0.url?.path }, [
            "/api/artifact-groups/trip-1/files/styles/app.css", "/api/artifact-groups/trip-1/files",
            "/api/artifact-groups/trip-1/files/old.js", "/api/artifact-groups/trip-1", "/api/artifact-groups/trip-1",
        ])
        let patch = String(decoding: try XCTUnwrap(requests[3].httpBody), as: UTF8.self)
        XCTAssertFalse(patch.contains("tags"), "an untouched field is not sent")
    }

    func testTheRootIndexRefusalIsTheRoutesWords() async {
        let transport = MockTransport(routes: [
            .failure(.delete, "/api/artifact-groups/trip-1/files/index.html", status: 400, message: "index.html is required \u{2014} every group needs a root index.html, so it can be edited but not removed."),
        ])
        do {
            _ = try await client(transport).send(.deleteGroupFile(slug: "trip-1", path: "index.html"))
            XCTFail("expected 400")
        } catch {
            XCTAssertEqual((error as? HVError)?.status, 400)
        }
    }

    func firstRequest(_ transport: MockTransport) async -> URLRequest? {
        await transport.requests.first
    }
}
