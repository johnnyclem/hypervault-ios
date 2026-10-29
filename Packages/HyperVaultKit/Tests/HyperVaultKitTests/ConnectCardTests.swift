import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

/// The first-run connect card on the canvas (the web's `ConnectAgentCard`): its words, and the read of
/// `profiles.onboarding` that lets a dismissal made anywhere carry to the phone.
final class ConnectCardTests: XCTestCase {
    private func rest(_ transport: MockTransport) -> AccountRest {
        AccountRest(client: HVClient(baseURL: URL(string: "https://proj.supabase.test")!, transport: transport, tokens: StaticTokenProvider(), retry: .none), anonKey: "anon-key")
    }

    // MARK: Words

    func testTheCardSaysTheWebsWords() {
        XCTAssertEqual(ConnectCardCopy.title, "Hand this to your agent")
        XCTAssertEqual(ConnectCardCopy.connectLabel, "Connect an agent")
        XCTAssertEqual(ConnectCardCopy.dismissLabel, "I'll look around first")
        XCTAssertEqual(ConnectCardCopy.line, ConnectCopy.line, "the card promises what the sheet it opens does")
    }

    func testTheCardIsPlainAsciiWithNothingAFirstRunSurfaceAvoids() throws {
        let banned = try NSRegularExpression(
            pattern: #"\b(?:MCP|tombstone|GraphRAG|grant|artifact\s+node|subdomain|AgentVault|wiki|vault\s+item)|!"#,
            options: [.caseInsensitive]
        )
        for line in [ConnectCardCopy.title, ConnectCardCopy.line, ConnectCardCopy.connectLabel, ConnectCardCopy.dismissLabel] {
            XCTAssertTrue(line.unicodeScalars.allSatisfy(\.isASCII), line)
            XCTAssertEqual(banned.numberOfMatches(in: line, range: NSRange(line.startIndex..., in: line)), 0, line)
        }
    }

    // MARK: The dismissal request

    func testDismissingSendsOneFlagAndNothingElse() async throws {
        // PATCH /api/onboarding { connect_dismissed: true }: the web stamps profiles.onboarding.connect_dismissed_at once.
        // Not "connect_completed": the app never says an agent connected.
        let transport = MockTransport(routes: [.json(.patch, "/api/onboarding", #"{"persisted":true,"onboarding":{}}"#)])
        let hv = HVClient(baseURL: URL(string: "https://hv.test")!, transport: transport, tokens: StaticTokenProvider(), retry: .none)
        _ = try await hv.send(.recordOnboarding(connectDismissed: true))
        let sent = await transport.requests(matching: "/api/onboarding")
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].httpMethod, "PATCH")
        XCTAssertEqual(try HVCoding.decoder(.verbatim).decode(JSONValue.self, from: try XCTUnwrap(sent[0].httpBody)), ["connect_dismissed": true])
    }

    // MARK: Reading what the profile remembers

    func testAStampedDismissalIsRead() async throws {
        let transport = MockTransport(routes: [
            .json(.get, "/rest/v1/profiles", #"[{"onboarding":{"connect_dismissed_at":"2026-10-27T09:30:00.123456+00:00"}}]"#),
        ])
        let state = try await rest(transport).onboarding(userID: "u1")
        XCTAssertEqual(state, OnboardingState(connectDismissed: true))

        // It reads the one column of the one row, with the person's id, as the account page reads its rows.
        let sent = await transport.requests(matching: "/rest/v1/profiles")
        XCTAssertEqual(sent.count, 1)
        let query = URLComponents(url: try XCTUnwrap(sent[0].url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "select" }?.value, "onboarding")
        XCTAssertEqual(query.first { $0.name == "id" }?.value, "eq.u1")
        XCTAssertEqual(query.first { $0.name == "limit" }?.value, "1")
        XCTAssertEqual(sent[0].value(forHTTPHeaderField: "apikey"), "anon-key")
    }

    func testAnythingElseInTheProfileReadsAsNotDismissed() async throws {
        let bodies = [
            #"[{"onboarding":{}}]"#,
            #"[{"onboarding":null}]"#,
            #"[{"onboarding":{"connect_dismissed_at":null}}]"#,
            #"[{"onboarding":{"connect_dismissed_at":""}}]"#,
            #"[{"onboarding":{"connect_completed_at":"2026-10-27T09:30:00Z"}}]"#,
            #"[{"onboarding":"not an object"}]"#,
            #"[{}]"#,
            #"[]"#,
        ]
        for body in bodies {
            let transport = MockTransport(routes: [.json(.get, "/rest/v1/profiles", body)])
            let state = try await rest(transport).onboarding(userID: "u1")
            XCTAssertEqual(state, OnboardingState(connectDismissed: false), body)
        }
    }

    func testADatabaseFromBeforeTheColumnHasNothingStamped() async throws {
        let transport = MockTransport(routes: [
            MockRoute(.get, "/rest/v1/profiles") { _ in
                HTTPResponse(status: 400, data: Data(#"{"code":"42703","message":"column profiles.onboarding does not exist"}"#.utf8))
            },
        ])
        let state = try await rest(transport).onboarding(userID: "u1")
        XCTAssertEqual(state, OnboardingState(connectDismissed: false))
    }

    func testAFailedReadIsThrownSoItIsNotTakenForAnEmptyProfile() async {
        for status in [401, 500] {
            let transport = MockTransport(routes: [.failure(.get, "/rest/v1/profiles", status: status, message: "Nope")])
            do {
                _ = try await rest(transport).onboarding(userID: "u1")
                XCTFail("status \(status) should throw")
            } catch {
                XCTAssertTrue(error is HVError, "\(error)")
            }
        }
    }
}
