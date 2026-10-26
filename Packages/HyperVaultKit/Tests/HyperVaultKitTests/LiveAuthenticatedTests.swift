import XCTest
@testable import HyperVaultKit

/// The Kit's read endpoints against a real deployment with a real identity, comparing what the models decode
/// with what the server actually sent. Most models decode leniently (a missing field becomes an empty list), so
/// "it decoded" proves little: each check compares the decoded counts with the raw JSON's own.
///
/// Opt-in, read-only (GET only, nothing is written), and it prints counts, never content:
///
///     HV_E2E_SERVER=https://hypervault.store HV_E2E_KEY=hv_... swift test --filter LiveAuthenticatedTests
///
/// The key can be an API key from the account's vault; the server accepts it as a bearer token on the routes
/// that take one. The session-only routes (keys, invites, pairing, admin) need a person's own token and are
/// not covered here. Mail and saved secrets are deliberately left out.
///
/// Written against the response shapes in `ProductionShapeTests`; it has not been run by its author (a key could
/// not be used from the build environment), so a first failure may be the check's own mistake as well as the
/// Kit's: look at which count differs before changing anything.
final class LiveAuthenticatedTests: XCTestCase {
    private struct StaticToken: TokenProvider {
        let token: String
        func accessToken() async throws -> String? { token }
        func refreshAfterUnauthorized(rejected: String?) async throws -> String? { nil }
    }

    private func client() throws -> HVClient {
        let env = ProcessInfo.processInfo.environment
        guard let text = env["HV_E2E_SERVER"], let server = ServerConfig(userInput: text), let key = env["HV_E2E_KEY"], !key.isEmpty else {
            throw XCTSkip("Set HV_E2E_SERVER and HV_E2E_KEY to run the authenticated live checks.")
        }
        return HVClient(baseURL: server.baseURL, transport: URLSessionTransport(), tokens: StaticToken(token: key))
    }

    /// The decoded value and the raw JSON object it came from.
    private func fetch<R: Sendable>(_ endpoint: Endpoint<R>, in client: HVClient) async throws -> (value: R, raw: [String: Any]) {
        let response = try await client.sendRaw(endpoint)
        let value = try endpoint.decode(response, endpoint.keys)
        let raw = (try? JSONSerialization.jsonObject(with: response.data)) as? [String: Any] ?? [:]
        return (value, raw)
    }

    private func rawCount(_ raw: [String: Any], _ key: String) -> Int { (raw[key] as? [Any])?.count ?? -1 }

    private func report(_ name: String, _ pairs: [(String, Int)]) {
        print("live \(name): " + pairs.map { "\($0.0)=\($0.1)" }.joined(separator: " "))
    }

    func testTheKeyIsRecognisedAsAnIdentity() async throws {
        let api = try client()
        let (caps, _) = try await fetch(.capabilities, in: api)
        let user = try XCTUnwrap(caps.user, "a call with a valid key was not told who it is")
        XCTAssertFalse(user.id.isEmpty)
    }

    func testYoursKeepsEveryRowTheServerSent() async throws {
        let api = try client()
        for filter in [YoursFilter.all, .file, .memory] {
            let (list, raw) = try await fetch(.yours(filter: filter, limit: 25), in: api)
            XCTAssertEqual(list.recent.count, rawCount(raw, "recent"), "recent, \(filter)")
            XCTAssertEqual(list.results.count, rawCount(raw, "results"), "results, \(filter)")
            for item in list.results {
                XCTAssertFalse(item.id.isEmpty)
                XCTAssertFalse(item.name.isEmpty)
                XCTAssertFalse(item.href.isEmpty)
                XCTAssertNotNil(item.updatedAt, "a row's updated_at did not parse")
            }
            report("yours(\(filter))", [("recent", list.recent.count), ("results", list.results.count)])
        }
    }

    func testArtifactsAndGroupsKeepEveryRow() async throws {
        let api = try client()
        let (artifacts, raw) = try await fetch(.artifacts, in: api)
        XCTAssertEqual(artifacts.items.count, rawCount(raw, "items"))
        for item in artifacts.items {
            XCTAssertFalse(item.slug.isEmpty)
            XCTAssertFalse(item.title.isEmpty)
        }
        let (groups, rawGroups) = try await fetch(.artifactGroups, in: api)
        XCTAssertEqual(groups.items.count, rawCount(rawGroups, "items"))
        report("artifacts", [("items", artifacts.items.count), ("groups", groups.items.count)])
    }

    func testTheConnectionsGraphKeepsEveryEdge() async throws {
        let api = try client()
        let (edges, raw) = try await fetch(.artifactEdges, in: api)
        XCTAssertEqual(edges.connections.count, rawCount(raw, "connections"))
        XCTAssertEqual(edges.memoryArtifactLinks.count, rawCount(raw, "memory_artifact_links"))
        let (memory, rawMemory) = try await fetch(.memoryConnections, in: api)
        XCTAssertEqual(memory.memoryLinks.count, rawCount(rawMemory, "memory_links"))
        XCTAssertEqual(memory.bridges.count, rawCount(rawMemory, "memory_artifact_links"))
        report("connections", [("artifact", edges.connections.count), ("bridges", memory.bridges.count), ("memoryLinks", memory.memoryLinks.count)])
    }

    func testMemoriesAndTheMindKeepEveryRow() async throws {
        let api = try client()
        let (list, raw) = try await fetch(.memoryList(), in: api)
        XCTAssertEqual(list.memories.count, rawCount(raw, "memories"))
        XCTAssertFalse(list.branch.isEmpty)
        let (branches, rawBranches) = try await fetch(.mindBranches, in: api)
        XCTAssertEqual(branches.branches.count, rawCount(rawBranches, "branches"))
        let (commits, rawCommits) = try await fetch(.mindCommits(limit: 20), in: api)
        XCTAssertEqual(commits.commits.count, rawCount(rawCommits, "commits"))
        report("memory", [("memories", list.memories.count), ("branches", branches.branches.count), ("commits", commits.commits.count)])
    }

    func testChatListsKeepEveryRow() async throws {
        let api = try client()
        let (conversations, raw) = try await fetch(.conversations, in: api)
        XCTAssertEqual(conversations.count, rawCount(raw, "conversations"))
        let (backends, rawBackends) = try await fetch(.backends, in: api)
        XCTAssertEqual(backends.count, rawCount(rawBackends, "backends"))
        let (rooms, rawRooms) = try await fetch(.rooms, in: api)
        XCTAssertEqual(rooms.count, rawCount(rawRooms, "rooms"))
        let (settings, rawSettings) = try await fetch(.chatSettings, in: api)
        XCTAssertEqual(rawSettings.count, 4, "chat settings grew a field the Kit does not know")
        _ = settings
        report("chat", [("conversations", conversations.count), ("backends", backends.count), ("rooms", rooms.count)])
    }

    func testDreamsDigestAndJobsDecode() async throws {
        let api = try client()
        let (dreams, rawDreams) = try await fetch(.dreamQueue, in: api)
        XCTAssertEqual(dreams.runs.count, rawCount(rawDreams, "runs"))
        XCTAssertEqual(dreams.pendingCount, rawDreams["pending_count"] as? Int)
        let (dreamSettings, _) = try await fetch(.dreamSettings, in: api)
        XCTAssertNotNil(dreamSettings.lastRunAt, "the last run time did not parse")
        let (digest, rawDigest) = try await fetch(.digestQueue, in: api)
        XCTAssertEqual(digest.runs.count, rawCount(rawDigest, "runs"))
        let (jobs, rawJobs) = try await fetch(.backgroundJobs, in: api)
        XCTAssertEqual(jobs.jobs.count, rawCount(rawJobs, "jobs"))
        report("dreams", [("pending", dreams.pendingCount), ("digestRuns", digest.runs.count), ("jobs", jobs.jobs.count)])
    }

    func testAPageReadsThroughTheArtifactEndpoints() async throws {
        let api = try client()
        let (artifacts, _) = try await fetch(.artifacts, in: api)
        guard let first = artifacts.items.first else { throw XCTSkip("no pages on this account") }
        let (versions, rawVersions) = try await fetch(.artifactVersions(slug: first.slug), in: api)
        XCTAssertEqual(versions.versions.count, rawCount(rawVersions, "versions"))
        report("page", [("versions", versions.versions.count)])
    }
}
