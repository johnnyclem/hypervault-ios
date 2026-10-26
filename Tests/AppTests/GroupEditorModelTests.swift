import HyperVaultKit
import XCTest
@testable import HyperVault

/// Saving a group is one request per file. These run it against a stand-in for the web's group routes that
/// answers as they do (409 for a path that is there, 404 for one that is gone, 413 past the caps), so a save
/// that stops half way shows whether the next one can finish it.
@MainActor
final class GroupEditorModelTests: XCTestCase {
    private func editor(_ server: GroupEditorTestServer) async -> GroupEditorModel {
        let transport = MockTransport(routes: [server.route])
        let client = HVClient(baseURL: URL(string: "https://hv.test")!, transport: transport, tokens: StaticTokenProvider(), retry: .none)
        let model = GroupEditorModel(client: client, slug: GroupEditorTestServer.slug)
        await model.load()
        return model
    }

    func testASaveThatStopsHalfWayIsFinishedByTheNextOne() async {
        let server = GroupEditorTestServer(files: ["index.html": "<h1>hi</h1>"])
        let model = await editor(server)
        XCTAssertNil(model.addFile("a.css"))
        XCTAssertNil(model.addFile("b.css"))
        model.setContent("a{}", of: "a.css")
        model.setContent("b{}", of: "b.css")
        server.failOnce(.post, ending: "/files", content: "b{}")

        let first = await model.save()
        XCTAssertNil(first)
        XCTAssertEqual(model.error?.hasPrefix("Couldn't add \"b.css\""), true)
        XCTAssertTrue(model.isDirty)
        XCTAssertEqual(server.files["a.css"], "a{}", "the step before it went through")

        let second = await model.save()
        XCTAssertEqual(second, GroupEditorTestServer.slug)
        XCTAssertNil(model.error)
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(server.files, ["index.html": "<h1>hi</h1>", "a.css": "a{}", "b.css": "b{}"])
        XCTAssertEqual(server.count(.post, ending: "/files"), 3, "a.css once, b.css twice: the retry did not send a.css again")
        XCTAssertEqual(server.refusals, [], "nothing was refused for being there already")
    }

    func testAnAddWhoseAnswerWasLostIsSavedNotAddedAgain() async {
        let server = GroupEditorTestServer(files: ["index.html": "<h1>hi</h1>"])
        let model = await editor(server)
        XCTAssertNil(model.addFile("a.css"))
        model.setContent("a{}", of: "a.css")
        // The server took the file; the answer never came back.
        server.failOnce(.post, ending: "/files", content: "a{}", afterApplying: true)

        let slug = await model.save()
        XCTAssertEqual(slug, GroupEditorTestServer.slug, "the group already holds everything, so it is saved")
        XCTAssertNil(model.error)
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(server.files["a.css"], "a{}")
        XCTAssertEqual(server.count(.post, ending: "/files"), 1)
        XCTAssertEqual(server.refusals, [])
    }

    func testARemoveWhoseAnswerWasLostIsNotRemovedAgain() async {
        let server = GroupEditorTestServer(files: ["index.html": "<h1>hi</h1>", "old.js": "1", "older.js": "2"])
        let model = await editor(server)
        model.remove("old.js")
        model.remove("older.js")
        server.failOnce(.delete, ending: "/files/old.js", afterApplying: true)

        let first = await model.save()
        XCTAssertNil(first)
        XCTAssertEqual(model.error?.hasPrefix("Couldn't remove \"old.js\""), true)

        let second = await model.save()
        XCTAssertEqual(second, GroupEditorTestServer.slug)
        XCTAssertEqual(server.files, ["index.html": "<h1>hi</h1>"])
        XCTAssertEqual(server.refusals, [], "no 404 for a file that was already gone")
    }

    func testTheTitleIsNotSentAgainAfterItWentThrough() async {
        let server = GroupEditorTestServer(files: ["index.html": "x"])
        let model = await editor(server)
        model.title = "Renamed"
        XCTAssertNil(model.addFile("a.css"))
        server.failOnce(.post, ending: "/files", content: "")

        let first = await model.save()
        XCTAssertNil(first)
        let second = await model.save()
        XCTAssertEqual(second, GroupEditorTestServer.slug)
        XCTAssertEqual(server.count(.patch, ending: GroupEditorTestServer.slug), 1)
        XCTAssertFalse(model.isDirty)
    }

    func testARenameThatOnlyChangesCaseSaves() async {
        let server = GroupEditorTestServer(files: ["index.html": "x", "readme.css": "r"])
        let model = await editor(server)
        XCTAssertNil(model.rename("readme.css", to: "Readme.css"))

        let slug = await model.save()
        XCTAssertEqual(slug, GroupEditorTestServer.slug, model.error ?? "")
        XCTAssertEqual(server.files, ["index.html": "x", "Readme.css": "r"])
        XCTAssertEqual(server.refusals, [])
    }

    func testASwapInAFullGroupSaves() async {
        var files = ["index.html": "x"]
        for number in 1..<ArtifactGroupRules.maxFiles { files["f\(number).js"] = "1" }
        let server = GroupEditorTestServer(files: files)
        let model = await editor(server)
        model.remove("f9.js")
        XCTAssertNil(model.addFile("swap.js"))

        let slug = await model.save()
        XCTAssertEqual(slug, GroupEditorTestServer.slug, model.error ?? "")
        XCTAssertNotNil(server.files["swap.js"])
        XCTAssertNil(server.files["f9.js"])
        XCTAssertEqual(server.refusals, [])
    }

    func testAFailedReadAfterAFailedStepKeepsTheEditsAndWhatLanded() async {
        let server = GroupEditorTestServer(files: ["index.html": "x"])
        let model = await editor(server)
        XCTAssertNil(model.addFile("a.css"))
        XCTAssertNil(model.addFile("b.css"))
        server.failOnce(.post, ending: "/files", content: "")
        server.failReads = true

        let first = await model.save()
        XCTAssertNil(first)
        XCTAssertEqual(model.files.map(\.path), ["index.html", "a.css", "b.css"], "the person's edits stay")
        XCTAssertTrue(model.isDirty)

        server.failReads = false
        let second = await model.save()
        XCTAssertEqual(second, GroupEditorTestServer.slug)
        XCTAssertEqual(server.refusals, [])
    }
}

/// The web's group file routes, as far as a save meets them: what the group holds, the refusals it gives, and
/// a failure that can be set up to happen once, with or without the change having been made first.
final class GroupEditorTestServer: @unchecked Sendable {
    static let slug = "trip-1"

    enum Verb: String { case get = "GET", post = "POST", put = "PUT", delete = "DELETE", patch = "PATCH" }

    private struct Fault {
        let verb: Verb
        let ending: String
        let content: String?
        let afterApplying: Bool
    }

    private let lock = NSLock()
    private var held: [String: String]
    private var faults: [Fault] = []
    private var seen: [(Verb, String)] = []
    private var refused: [String] = []
    private var readsFail = false

    init(files: [String: String]) {
        held = files
    }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var files: [String: String] { locked { held } }
    /// The refusals the real routes give for a path already there or already gone; a save that knows better never meets one.
    var refusals: [String] { locked { refused } }
    var failReads: Bool {
        get { locked { readsFail } }
        set { locked { readsFail = newValue } }
    }

    func failOnce(_ verb: Verb, ending: String, content: String? = nil, afterApplying: Bool = false) {
        locked { faults.append(Fault(verb: verb, ending: ending, content: content, afterApplying: afterApplying)) }
    }

    func count(_ verb: Verb, ending: String) -> Int {
        locked { seen.filter { $0.0 == verb && $0.1.hasSuffix(ending) }.count }
    }

    var route: MockRoute {
        MockRoute(nil, "/api/artifact-groups/\(Self.slug)*") { [self] request in respond(to: request) }
    }

    private func respond(to request: URLRequest) -> HTTPResponse {
        let verb = Verb(rawValue: request.httpMethod ?? "GET") ?? .get
        let path = request.url?.path ?? ""
        let body = (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        let fileRoot = "/api/artifact-groups/\(Self.slug)/files"

        return locked { () -> HTTPResponse in
            seen.append((verb, path))
            if verb == .get, readsFail { return failure(503, "Try again.") }

            let fault = faults.firstIndex { $0.verb == verb && path.hasSuffix($0.ending) && ($0.content == nil || $0.content == body["content"] as? String) }
            let failing = fault.map { faults.remove(at: $0) }
            if let failing, !failing.afterApplying { return failure(503, "The connection dropped.") }
            let answer = apply(verb, path: path, body: body, fileRoot: fileRoot)
            return failing == nil ? answer : failure(503, "The connection dropped.")
        }
    }

    private func apply(_ verb: Verb, path: String, body: [String: Any], fileRoot: String) -> HTTPResponse {
        switch verb {
        case .get:
            let list = held.keys.sorted().map { #"{"path":"\#($0)","content":\#(json(held[$0] ?? "")),"size_bytes":\#((held[$0] ?? "").utf8.count)}"# }
            return ok(#"{"slug":"\#(Self.slug)","title":"Trip","tags":[],"visibility":"private","files":[\#(list.joined(separator: ","))]}"#)
        case .patch:
            return ok(#"{"message":"Updated."}"#)
        case .post:
            let name = body["path"] as? String ?? ""
            let content = body["content"] as? String ?? ""
            if held.count >= ArtifactGroupRules.maxFiles { return refuse(413, "The group is full.") }
            if let clash = held.keys.first(where: { $0.lowercased() == name.lowercased() }) {
                return refuse(409, clash == name ? "\"\(name)\" already exists." : "\"\(name)\" collides with \"\(clash)\".")
            }
            held[name] = content
            return ok(#"{"message":"Added."}"#)
        case .put:
            let name = String(path.dropFirst(fileRoot.count + 1))
            guard held[name] != nil else { return refuse(404, "\"\(name)\" doesn't exist.") }
            held[name] = body["content"] as? String ?? ""
            return ok(#"{"message":"Saved."}"#)
        case .delete:
            let name = String(path.dropFirst(fileRoot.count + 1))
            guard held.removeValue(forKey: name) != nil else { return refuse(404, "\"\(name)\" doesn't exist.") }
            return ok(#"{"message":"Removed."}"#)
        }
    }

    private func refuse(_ status: Int, _ message: String) -> HTTPResponse {
        refused.append(message)
        return failure(status, message)
    }

    private func failure(_ status: Int, _ message: String) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["content-type": "application/json"], data: Data(#"{"error":\#(json(message))}"#.utf8))
    }

    private func ok(_ text: String) -> HTTPResponse {
        HTTPResponse(status: 200, headers: ["content-type": "application/json"], data: Data(text.utf8))
    }

    private func json(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text], options: []),
              let array = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(array.dropFirst().dropLast())
    }
}
