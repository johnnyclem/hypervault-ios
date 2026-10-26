import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

/// The reads the web makes on the server and the app makes as the signed-in person
/// (domain_claims, profiles.sidebar_pins, artifact_shares: all behind row-level security),
/// and the file upload that goes around the app server.
final class ArtifactRealmsTests: XCTestCase {
    let base = URL(string: "https://hv.test")!
    let supabase = SupabaseConfig(url: URL(string: "https://p.supabase.test")!, anonKey: "anon-key")

    func tables(_ transport: MockTransport) -> ArtifactTables {
        ArtifactTables(config: supabase, tokens: StaticTokenProvider("jwt-1"), transport: transport)
    }

    func client(_ transport: MockTransport) -> HVClient {
        HVClient(baseURL: base, transport: transport, tokens: StaticTokenProvider(), sleep: { _ in })
    }

    // MARK: Tables

    func testRowsAreAskedForAsThePerson() async throws {
        let transport = MockTransport(routes: [
            .json(.get, "/rest/v1/domain_claims", #"[{"subdomain":"nova","base_domain":"vault.cool","default_artifact_slug":"home-1"},{"subdomain":"sam","base_domain":"vault.cool","default_artifact_slug":null}]"#),
        ])
        let realms = try await ArtifactRealmReader(tables: tables(transport), userId: "u-1").realms()
        XCTAssertEqual(realms.map(\.host), ["nova.vault.cool", "sam.vault.cool"])
        XCTAssertEqual(realms[0].defaultArtifactSlug, "home-1")
        XCTAssertNil(realms[1].defaultArtifactSlug)

        let requests = await transport.requests
        let sent = try XCTUnwrap(requests.first)
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer jwt-1")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "apikey"), "anon-key")
        let query = try XCTUnwrap(URLComponents(url: try XCTUnwrap(sent.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "user_id" }?.value, "eq.u-1")
        XCTAssertEqual(query.first { $0.name == "order" }?.value, "claimed_at.asc")
    }

    func testARealmFromBeforeHomePagesStillReads() async throws {
        let transport = MockTransport()
        await transport.add(.json(.get, "/rest/v1/domain_claims", #"[{"subdomain":"nova","base_domain":"vault.cool"}]"#))
        await transport.add(MockRoute(.get, "/rest/v1/domain_claims") { request in
            let select = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "select" }?.value ?? ""
            if select.contains("default_artifact_slug") {
                return HTTPResponse(status: 400, data: Data(#"{"code":"42703","message":"column domain_claims.default_artifact_slug does not exist"}"#.utf8))
            }
            return HTTPResponse(status: 200, data: Data(#"[{"subdomain":"nova","base_domain":"vault.cool"}]"#.utf8))
        })
        let realms = try await ArtifactRealmReader(tables: tables(transport), userId: "u-1").realms()
        XCTAssertEqual(realms.map(\.host), ["nova.vault.cool"])
    }

    func testAnOldProfileWithOnlyAVanityNameIsOneRealm() async throws {
        let transport = MockTransport(routes: [
            .json(.get, "/rest/v1/domain_claims", "[]"),
            .json(.get, "/rest/v1/profiles", #"[{"vanity_subdomain":"olive"}]"#),
        ])
        let realms = try await ArtifactRealmReader(tables: tables(transport), userId: "u-1").realms()
        XCTAssertEqual(realms, [ArtifactRealm(subdomain: "olive", baseDomain: "vault.cool")])
    }

    func testNoAddressesIsNoRealms() async throws {
        let transport = MockTransport(routes: [
            .json(.get, "/rest/v1/domain_claims", "[]"),
            .json(.get, "/rest/v1/profiles", #"[{"vanity_subdomain":null}]"#),
        ])
        let realms = try await ArtifactRealmReader(tables: tables(transport), userId: "u-1").realms()
        XCTAssertEqual(realms, [])
    }

    func testARefusedReadIsTheServersSentence() async {
        let transport = MockTransport(routes: [.json(.get, "/rest/v1/profiles", #"{"message":"JWT expired","code":"PGRST301"}"#, status: 401)])
        do {
            _ = try await SidebarPinsReader(tables: tables(transport), userId: "u-1").pins()
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual((error as? HVError)?.status, 401)
        }
    }

    // MARK: Pins

    func testPinsKeepOtherKindsAndToggleOnlyArtifacts() async throws {
        let transport = MockTransport(routes: [
            .json(.get, "/rest/v1/profiles", #"[{"sidebar_pins":[{"kind":"vault","ref":"nova.vault.cool"},{"kind":"artifact","ref":"p-1"},{"kind":"conversation","ref":"c-1"}]}]"#),
        ])
        let pins = try await SidebarPinsReader(tables: tables(transport), userId: "u-1").pins()
        XCTAssertEqual(pins.artifactSlugs, ["p-1"])
        XCTAssertTrue(pins.contains(artifact: "p-1"))
        let unpinned = pins.toggling(artifact: "p-1")
        XCTAssertEqual(unpinned.pins.map(\.kind), ["vault", "conversation"], "the other kinds survive the whole-list write")
        let pinned = unpinned.toggling(artifact: "p-2")
        XCTAssertEqual(pinned.pins.last, .artifact("p-2"))
    }

    func testReplacingPinsSendsTheWholeOrderedList() async throws {
        let transport = MockTransport(routes: [.json(.patch, "/api/sidebar-pins", #"{"pins":[]}"#)])
        _ = try await client(transport).send(.replaceSidebarPins([.artifact("p-1"), SidebarPin(kind: "vault", ref: "nova.vault.cool")]))
        let requests = await transport.requests
        let body = String(decoding: try XCTUnwrap(requests.first?.httpBody), as: UTF8.self)
        XCTAssertEqual(body, #"{"pins":[{"kind":"artifact","ref":"p-1"},{"kind":"vault","ref":"nova.vault.cool"}]}"#)
    }

    func testAnEmptyOrMissingPinListIsEmpty() async throws {
        let transport = MockTransport(routes: [.json(.get, "/rest/v1/profiles", #"[{"sidebar_pins":null}]"#)])
        let pins = try await SidebarPinsReader(tables: tables(transport), userId: "u-1").pins()
        XCTAssertEqual(pins, SidebarPins())
    }

    // MARK: Shared with you

    func testSharedWithYouReadsPagesAndTheirOwners() async throws {
        let json = #"""
        [{"id":"s1","created_at":"2026-10-20T10:00:00.000000+00:00","artifact":{"slug":"trip-1","title":"Trip","type":"group","is_jsx":false},"owner":{"email":"maya@example.com","display_name":"Maya"}},
         {"id":"s2","created_at":"2026-10-19T10:00:00.000000+00:00","artifact":[{"slug":"pomo-1","title":"Pomodoro","type":"react","is_jsx":true}],"owner":null},
         {"id":"s3","created_at":"2026-10-18T10:00:00.000000+00:00","artifact":null,"owner":{"email":"x@y.co","display_name":null}}]
        """#
        let transport = MockTransport(routes: [.json(.get, "/rest/v1/artifact_shares", json)])
        let items = try await SharedWithYouReader(tables: tables(transport), userId: "u-1").items()
        XCTAssertEqual(items.map(\.slug), ["trip-1", "pomo-1"], "a share whose page cannot be read is left out")
        XCTAssertEqual(items[0].owner, "Maya")
        XCTAssertTrue(items[0].isGroup)
        XCTAssertNil(items[1].owner)
        XCTAssertEqual(items[1].typeLabel, "react")
        XCTAssertEqual(items[0].shareId, "s1")
        let requests = await transport.requests
        let query = URLComponents(url: try XCTUnwrap(requests.first?.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first { $0.name == "shared_with_id" }?.value, "eq.u-1")
    }

    func testSharedWithYouFallsBackToPagesOnly() async throws {
        let transport = MockTransport()
        await transport.add(MockRoute(.get, "/rest/v1/artifact_shares") { request in
            let select = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "select" }?.value ?? ""
            if select.contains("owner:") {
                return HTTPResponse(status: 400, data: Data(#"{"message":"Could not find a relationship"}"#.utf8))
            }
            return HTTPResponse(status: 200, data: Data(#"[{"id":"s1","created_at":"2026-10-20T10:00:00Z","artifact":{"slug":"trip-1","title":"Trip","type":"html","is_jsx":false}}]"#.utf8))
        })
        let items = try await SharedWithYouReader(tables: tables(transport), userId: "u-1").items()
        XCTAssertEqual(items.map(\.title), ["Trip"])
        XCTAssertNil(items[0].owner)
    }

    // MARK: Claiming a page as an address's home

    func testSettingAndClearingARealmHome() async throws {
        let transport = MockTransport(routes: [
            .json(.patch, "/api/claim-domain", #"{"domain":"nova.vault.cool","theme":null,"default_artifact":"home-1","url":"https://nova.vault.cool","warning":"\"Home\" is private, so visitors to nova.vault.cool will see the lock page instead of the artifact. Make it public to serve it here.","message":"nova.vault.cool now opens with \"Home\"."}"#),
        ])
        let api = client(transport)
        let set = try await api.send(.setRealmHome(subdomain: "nova", baseDomain: "vault.cool", slug: "home-1"))
        XCTAssertEqual(set.defaultArtifact, "home-1")
        XCTAssertTrue(set.warning?.contains("lock page") == true)
        _ = try await api.send(.setRealmHome(subdomain: "nova", baseDomain: "vault.cool", slug: nil))
        let requests = await transport.requests
        let cleared = String(decoding: try XCTUnwrap(requests.last?.httpBody), as: UTF8.self)
        XCTAssertTrue(cleared.contains("\"default_artifact\":null"), "null, not a missing key, is how the route clears it")
        XCTAssertTrue(cleared.contains("\"base_domain\":\"vault.cool\""))
    }

    // MARK: Upload

    func testUploadGoesAroundTheAppServer() async throws {
        let transport = MockTransport(routes: [
            .json(.post, "/api/artifacts/upload-url", #"{"path":"u/f.pdf","signed_url":"https://p.supabase.test/storage/v1/object/upload/sign/artifact-files/u/f.pdf?token=t","token":"t","content_type":"application/pdf","max_bytes":1000000}"#),
            MockRoute(.put, "/storage/v1/object/upload/sign/artifact-files/u/f.pdf") { _ in HTTPResponse(status: 200, data: Data(#"{"Key":"artifact-files/u/f.pdf"}"#.utf8)) },
            .json(.post, "/api/artifacts/import-file", #"{"url":"https://hv.test/a/report-abc","slug":"report-abc","is_jsx":false,"visibility":"private","connections":{"manual":0,"auto":0},"message":"Saved! Your PDF has a permanent home. It's private — only you (and anyone you invite) can open the link."}"#),
        ])
        let uploader = ArtifactUploader(client: client(transport), transport: transport)
        let result = try await uploader.upload(data: Data("%PDF-1.4".utf8), filename: "Report.pdf", tags: ["work"])
        XCTAssertEqual(result.slug, "report-abc")
        XCTAssertFalse(result.duplicate)

        let requests = await transport.requests
        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/artifacts/upload-url", "/storage/v1/object/upload/sign/artifact-files/u/f.pdf", "/api/artifacts/import-file"])
        let put = requests[1]
        XCTAssertEqual(put.httpMethod, "PUT")
        XCTAssertEqual(put.value(forHTTPHeaderField: "Content-Type"), "application/pdf")
        XCTAssertNil(put.value(forHTTPHeaderField: "Authorization"), "the signed address carries its own permission; the app's token stays home")
        XCTAssertEqual(put.httpBody, Data("%PDF-1.4".utf8))

        let ticketBody = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(requests[0].httpBody)) as? [String: Any])
        XCTAssertEqual(ticketBody["filename"] as? String, "Report.pdf")
        XCTAssertEqual(ticketBody["size"] as? Int, 8)
        let importBody = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(requests[2].httpBody)) as? [String: Any])
        XCTAssertEqual(importBody["path"] as? String, "u/f.pdf")
        XCTAssertEqual(importBody["title"] as? String, "Report", "the title defaults to the filename without its extension")
        XCTAssertEqual(importBody["tags"] as? [String], ["work"])
        XCTAssertEqual(importBody["visibility"] as? String, "private")
    }

    func testUploadRefusals() async {
        let uploader = ArtifactUploader(client: client(MockTransport()), transport: MockTransport())
        do {
            _ = try await uploader.upload(data: Data("x".utf8), filename: "notes.txt")
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue((error as? HVError)?.userMessage.hasPrefix("Unsupported file type") == true)
        }
        do {
            _ = try await uploader.upload(data: Data(), filename: "a.pdf")
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual((error as? HVError)?.userMessage, "That file is empty.")
        }

        let tooBig = MockTransport(routes: [.failure(.post, "/api/artifacts/upload-url", status: 413, message: "File is over the 1 MB limit.")])
        do {
            _ = try await ArtifactUploader(client: client(tooBig), transport: tooBig).upload(data: Data("x".utf8), filename: "a.pdf")
            XCTFail("expected 413")
        } catch {
            XCTAssertEqual((error as? HVError)?.userMessage, "File is over the 1 MB limit.")
        }
    }

    func testAFailedPutNeverImports() async {
        let transport = MockTransport(routes: [
            .json(.post, "/api/artifacts/upload-url", #"{"path":"u/f.png","signed_url":"https://p.supabase.test/storage/up","token":"t","content_type":"image/png","max_bytes":1000000}"#),
            MockRoute(.put, "/storage/up") { _ in HTTPResponse(status: 403, data: Data()) },
            .json(.post, "/api/artifacts/import-file", "{}"),
        ])
        do {
            _ = try await ArtifactUploader(client: client(transport), transport: transport).upload(data: Data("x".utf8), filename: "a.png")
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual((error as? HVError)?.userMessage, "The upload didn't go through. Try again.")
        }
    }
}
