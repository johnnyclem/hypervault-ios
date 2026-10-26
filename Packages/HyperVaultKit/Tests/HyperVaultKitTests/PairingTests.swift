import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

/// The person's side of pairing: app/api/pair/{approve,deny}/route.ts, lib/pairing/{approver,codes}.ts.
final class PairingTests: XCTestCase {
    func client(_ transport: MockTransport, base: String = "https://hypervault.store") -> HVClient {
        HVClient(baseURL: URL(string: base)!, transport: transport, tokens: StaticTokenProvider(), retry: .none)
    }

    // MARK: Codes

    func testNormalizeMatchesTheServer() {
        XCTAssertEqual(PairingCode.normalize("bcdf-2346"), "BCDF2346")
        XCTAssertEqual(PairingCode.normalize(" BCDF 2346 "), "BCDF2346")
        XCTAssertEqual(PairingCode.normalize("bcdf_2346"), "BCDF2346")
        XCTAssertEqual(PairingCode.normalize("BCDF2346"), "BCDF2346")
        // No vowels, no 0/O, no 1/I/L.
        for bad in ["", "BCDF-234", "BCDF-23467", "ABCD-2346", "BCDF-2340", "BCDF-2341", "BCDF-23LL", "BCDF-23!6", String(repeating: "B", count: 40)] {
            XCTAssertNil(PairingCode.normalize(bad), bad)
        }
        XCTAssertEqual(PairingCode.format("BCDF2346"), "BCDF-2346")
    }

    func testEveryCharacterOfTheAlphabetIsAccepted() {
        XCTAssertEqual(PairingCode.alphabet.count, 27)
        let all = Array(PairingCode.alphabet)
        for start in stride(from: 0, to: all.count - 8, by: 4) {
            let code = String(all[start..<start + 8])
            XCTAssertEqual(PairingCode.normalize(code), code)
        }
    }

    func testExtractFindsACodeInALinkOrASentence() {
        XCTAssertEqual(PairingCode.extract(from: "bcdf2346"), "BCDF-2346")
        XCTAssertEqual(PairingCode.extract(from: "https://hypervault.store/pair?code=BCDF-2346"), "BCDF-2346")
        XCTAssertEqual(PairingCode.extract(from: "hypervault://pair?user_code=bcdf-2346"), "BCDF-2346")
        XCTAssertEqual(PairingCode.extract(from: "Your code is BCDF-2346, enter it now."), "BCDF-2346")
        XCTAssertNil(PairingCode.extract(from: "hello there"))
        XCTAssertNil(PairingCode.extract(from: ""))
    }

    // MARK: The Origin the server insists on

    func testOriginIsTheServersOriginWithAnyPort() {
        XCTAssertEqual(PairingCode.origin(of: URL(string: "https://hypervault.store")!), "https://hypervault.store")
        XCTAssertEqual(PairingCode.origin(of: URL(string: "https://hypervault.store/")!), "https://hypervault.store")
        XCTAssertEqual(PairingCode.origin(of: URL(string: "https://my.host:8443/base")!), "https://my.host:8443")
        XCTAssertEqual(PairingCode.origin(of: URL(string: "http://localhost:3000")!), "http://localhost:3000")
    }

    func testApproveAndDenySendTheOriginAndTheCode() async throws {
        let transport = MockTransport(routes: [
            .json(.post, "/api/pair/approve", #"{"approved":true,"label":"Claude Code on Sam's Mac"}"#),
            .json(.post, "/api/pair/deny", #"{"denied":true}"#),
        ])
        let hv = client(transport)
        let origin = PairingCode.origin(of: hv.baseURL)
        let approved = try await hv.send(.pairApprove(userCode: "BCDF-2346", origin: origin))
        XCTAssertTrue(approved.approved)
        XCTAssertEqual(approved.label, "Claude Code on Sam's Mac")
        let denied = try await hv.send(.pairDeny(userCode: "BCDF-2346", origin: origin))
        XCTAssertTrue(denied.denied)

        for path in ["/api/pair/approve", "/api/pair/deny"] {
            let requests = await transport.requests(matching: path)
            let request = try XCTUnwrap(requests.first)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://hypervault.store", "isSameOriginPost wants an Origin that names the host")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer preview-token")
            XCTAssertNil(request.value(forHTTPHeaderField: "X-HyperVault-Key"), "an agent key must never ride along")
            let body = try HVCoding.decoder(.verbatim).decode(JSONValue.self, from: try XCTUnwrap(request.httpBody))
            XCTAssertEqual(body, ["user_code": "BCDF-2346"])
        }
    }

    // MARK: Failures

    func testSwitchedOffIsToldApartFromANeverHeardOfCode() async {
        // Pairing off: every route is a bare 404 `Not found.` (lib/pairing/http.ts notFound).
        let off = MockTransport(routes: [.failure(.post, "/api/pair/approve", status: 404, message: "Not found.")])
        // Pairing on, a code nobody is waiting on (lib/copy.ts PAIR_NOT_FOUND_LINE).
        let unknown = MockTransport(routes: [.failure(.post, "/api/pair/approve", status: 404, message: PairingCopy.notFoundLine)])
        for (transport, expected) in [(off, PairingFailure.unavailable), (unknown, PairingFailure.refused(PairingCopy.notFoundLine))] {
            do {
                _ = try await client(transport).send(.pairApprove(userCode: "BCDF-2346", origin: "https://hypervault.store"))
                XCTFail("expected a refusal")
            } catch {
                XCTAssertEqual(PairingFailure.classify(error), expected)
            }
        }
    }

    func testTheServersOwnSentencesComeThrough() async {
        let cases: [(Int, String)] = [
            (410, "That code has run out. Ask your AI tool for a new one."),
            (409, "That code was already answered. Ask your AI tool for a new one if you need one."),
            (429, "Too many tries. Wait a while, or ask your AI tool for a new code."),
            (403, "That request did not come from this site."),
            (400, PairingCopy.badCodeLine),
        ]
        for (status, message) in cases {
            let transport = MockTransport(routes: [.failure(.post, "/api/pair/approve", status: status, message: message)])
            do {
                _ = try await client(transport).send(.pairApprove(userCode: "BCDF-2346", origin: "https://hypervault.store"))
                XCTFail("expected a refusal")
            } catch {
                XCTAssertEqual(PairingFailure.classify(error), .refused(message))
            }
        }
    }

    func testAnOfflineFailureIsTheNothingChangedLine() {
        XCTAssertEqual(PairingFailure.classify(HVError.transport("offline")), .refused(PairingCopy.offlineLine))
        XCTAssertEqual(PairingFailure.classify(URLError(.badURL)), .refused(PairingCopy.failedLine))
    }

    // MARK: The probe

    func testTheProbeSaysWhetherPairingIsOn() async {
        // On: the handler wants a device_code and answers 400 (a 503 when it is not set up, which is still "on").
        for status in [400, 503] {
            let on = MockTransport(routes: [.failure(.post, "/api/pair/poll", status: status, message: "device_code is required: the one POST /api/pair/start gave you.")])
            let isOn = await PairingAvailability.probe(client: client(on))
            XCTAssertEqual(isOn, true, "\(status)")
        }
        // Off: a bare 404.
        let off = MockTransport(routes: [.failure(.post, "/api/pair/poll", status: 404, message: "Not found.")])
        let isOff = await PairingAvailability.probe(client: client(off))
        XCTAssertEqual(isOff, false)
        // Offline: no answer either way.
        let offline = HVClient(baseURL: URL(string: "https://hypervault.store")!, transport: ThrowingTransport(), tokens: nil, retry: .none)
        let unknown = await PairingAvailability.probe(client: offline)
        XCTAssertNil(unknown)
    }

    func testTheProbeSendsNoCredentialsAndNoCode() async throws {
        let transport = MockTransport(routes: [.failure(.post, "/api/pair/poll", status: 400, message: "device_code is required")])
        _ = await PairingAvailability.probe(client: client(transport))
        let requests = await transport.requests(matching: "/api/pair/poll")
        let request = try XCTUnwrap(requests.first)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(try HVCoding.decoder(.verbatim).decode(JSONValue.self, from: try XCTUnwrap(request.httpBody)), [:])
    }

    func testTheWordsAreTheWebs() {
        XCTAssertEqual(PairingCopy.askLine("Claude Code"), "Claude Code wants to connect to your HyperVault.")
        XCTAssertEqual(PairingCopy.warning, "Only approve if you just started this from your AI tool.")
        XCTAssertEqual(PairingCopy.approvedLine, "Approved. Go back to your AI tool; it will finish on its own.")
        XCTAssertEqual(PairingCopy.deniedLine, "Denied. Nothing was shared.")
    }
}

/// A transport that never gets an answer.
struct ThrowingTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResponse { throw URLError(.notConnectedToInternet) }
}
