import HyperVaultKit
import XCTest
@testable import HyperVault

/// "Fix it": the repair sheet follows its own job while it is open and hands the job to the job notices when it is not.
@MainActor
final class ArtifactRepairModelTests: XCTestCase {
    private let base = URL(string: "https://hv.test")!

    private func routes(finished: FinishedFlag, result: String = "null") -> [MockRoute] {
        [
            .json(.post, "/api/artifacts/trip-1/repair", #"{"job_id":"j1","status":"pending"}"#, status: 202),
            MockRoute(.get, "/api/jobs/j1") { _ in
                let body = repairJobJSON(finished.isSet ? "succeeded" : "running", result: result)
                return HTTPResponse(status: 200, headers: ["content-type": "application/json"], data: Data(body.utf8))
            },
            .json(.post, "/api/jobs/j1", #"{"ok":true}"#),
        ]
    }

    private func model(_ transport: HTTPTransport) -> ArtifactRepairModel {
        let client = HVClient(baseURL: base, transport: transport, tokens: StaticTokenProvider(), retry: .none)
        return ArtifactRepairModel(client: client, slug: "trip-1", pollInterval: 5_000_000)
    }

    private func eventually(_ what: String, file: StaticString = #filePath, line: UInt = #line, _ condition: () async -> Bool) async {
        for _ in 0..<300 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Never happened: \(what)", file: file, line: line)
    }

    func testAFinishedRepairIsShownAndAcknowledgedByTheSheetThatStartedIt() async {
        let finished = FinishedFlag()
        finished.set()
        let transport = MockTransport(routes: routes(
            finished: finished,
            result: #"{"changed":true,"message":"My Claude took a pass at it \#u{2014} reload the artifact to see if it renders now."}"#
        ))
        let model = model(transport)
        await model.run(renderError: nil)
        XCTAssertEqual(model.phase, .done(changed: true, message: "My Claude took a pass at it \u{2014} reload the artifact to see if it renders now."))
        let acknowledged = await acknowledgements(transport)
        XCTAssertEqual(acknowledged.count, 1)
    }

    private func repairBody(_ transport: MockTransport) async -> [String: Any]? {
        let sent = await transport.requests.filter { $0.url?.path == "/api/artifacts/trip-1/repair" }
        guard let data = sent.last?.httpBody else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    func testWithMoreThanOneModelTheChosenOneRepairsTheOtherIsNeverNamed() async {
        let finished = FinishedFlag()
        finished.set()
        let transport = MockTransport(routes: routes(finished: finished) + [
            .json(.get, "/api/backends", #"{"backends":[{"id":"b1","name":"My Claude","provider":"anthropic"},{"id":"b2","name":"My GPT","provider":"openai"}],"providers":[]}"#),
        ])
        let model = model(transport)
        await model.loadBackends()
        XCTAssertEqual(model.backends.map(\.id), ["b1", "b2"])
        XCTAssertEqual(model.selectedBackendID, "b1", "the first is chosen until the person chooses")
        XCTAssertFalse(model.needsModel)
        model.selectedBackendID = "b2"
        await model.run(renderError: nil)
        let body = await repairBody(transport)
        XCTAssertEqual(body?["backend_id"] as? String, "b2")
    }

    func testWithOneModelTheServerIsLeftToUseIt() async {
        let finished = FinishedFlag()
        finished.set()
        let transport = MockTransport(routes: routes(finished: finished) + [
            .json(.get, "/api/backends", #"{"backends":[{"id":"b1","name":"My Claude","provider":"anthropic"}],"providers":[]}"#),
        ])
        let model = model(transport)
        await model.loadBackends()
        XCTAssertEqual(model.selectedBackendID, "b1")
        await model.run(renderError: nil)
        let body = await repairBody(transport)
        XCTAssertNil(body?["backend_id"], "nobody chose, so nothing is named")
    }

    func testWithNoModelTheSheetKnowsBeforeTheAttemptAndAListThatCouldNotBeReadDoesNotSayThat() async {
        let none = model(MockTransport(routes: [.json(.get, "/api/backends", #"{"backends":[],"providers":[]}"#)]))
        await none.loadBackends()
        XCTAssertTrue(none.needsModel)

        let unknown = model(MockTransport(routes: [.failure(.get, "/api/backends", status: 500, message: "Boom.")]))
        await unknown.loadBackends()
        XCTAssertFalse(unknown.needsModel, "not knowing is not the same as having none: the attempt is left to the server")
        XCTAssertFalse(unknown.backendsKnown)
    }

    func testASheetThatIsClosedStopsAskingAfterTheJob() async {
        let finished = FinishedFlag()
        let transport = MockTransport(routes: routes(finished: finished))
        let model = model(transport)
        let run = Task { await model.run(renderError: nil) }
        await eventually("the first look at the job") { await self.looks(transport) >= 1 }

        // The job never finishes in this test (`finished` is not set), so the run returning at all is the proof that it stopped
        // asking once nobody was waiting.
        model.stopWaiting()
        await run.value

        XCTAssertEqual(model.phase, .running, "it did not give up with a verdict either")
        let acknowledged = await acknowledgements(transport)
        XCTAssertTrue(acknowledged.isEmpty)
    }

    func testAResultThatArrivesAfterTheSheetWasClosedIsNotMarkedAsSeen() async {
        let finished = FinishedFlag()
        let hold = RequestHold()
        await hold.arm()
        let mock = MockTransport(routes: routes(finished: finished))
        let transport = HeldTransport(base: mock, hold: hold, holds: { $0.httpMethod == "GET" })
        let model = model(transport)
        let run = Task { await model.run(renderError: nil) }
        await eventually("a look at the job on its way") { await hold.waiting == 1 }

        // The look is already out, and the job finishes while it is: the answer is "done", and nobody is there to read it.
        model.stopWaiting()
        finished.set()
        await hold.release()
        await run.value

        let acknowledged = await acknowledgements(mock)
        XCTAssertTrue(acknowledged.isEmpty, "nobody saw the result, so it is left for the job notices to tell of")
        XCTAssertEqual(model.phase, .running)
    }

    private func looks(_ transport: MockTransport) async -> Int {
        await transport.requests.filter { $0.httpMethod == "GET" && $0.url?.path == "/api/jobs/j1" }.count
    }

    private func acknowledgements(_ transport: MockTransport) async -> [URLRequest] {
        await transport.requests.filter { $0.httpMethod == "POST" && $0.url?.path == "/api/jobs/j1" }
    }
}

/// `GET /api/jobs/[id]` for the repair job (`app/api/jobs/[id]/route.ts`).
private func repairJobJSON(_ status: String, result: String) -> String {
    #"{"job":{"id":"j1","kind":"artifact_repair","status":"\#(status)","label":"Repairing","result":\#(result),"error":null}}"#
}

/// A flag the mock routes can read from any thread.
private final class FinishedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}
