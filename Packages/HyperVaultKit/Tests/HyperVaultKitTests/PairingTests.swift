import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

/// What the app knows about pairing: what a code looks like and where the website's page is. Approving is the
/// website's (app/api/pair/{approve,deny}/route.ts, lib/pairing/{approver,codes}.ts), not the app's.
final class PairingTests: XCTestCase {
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

    // MARK: The page

    private let server = URL(string: "https://hypervault.store")!

    func testThePageIsTheWebsitesPairRouteWithTheCodeInTheLink() {
        XCTAssertEqual(PairingCode.pageURL(server: server, code: "bcdf2346").absoluteString, "https://hypervault.store/pair?code=BCDF-2346")
        XCTAssertEqual(PairingCode.pageURL(server: URL(string: "https://my.host:8443/")!, code: "BCDF-2346").absoluteString, "https://my.host:8443/pair?code=BCDF-2346")
        XCTAssertEqual(PairingCode.pageURL(server: server, code: "https://hypervault.store/pair?code=BCDF-2346").absoluteString, "https://hypervault.store/pair?code=BCDF-2346")
    }

    func testAnythingThatIsNotACodeLeavesTheAddressBare() {
        let bare = "https://hypervault.store/pair"
        for code in [nil, "", "hello", "ABCD-EFGH", "https://elsewhere.example/?code=nope"] {
            XCTAssertEqual(PairingCode.pageURL(server: server, code: code).absoluteString, bare, code ?? "nil")
        }
    }

    func testOnlyTheCodeGetsIntoTheAddress() {
        let tricky = "BCDF-2346&next=https://elsewhere.example"
        XCTAssertEqual(PairingCode.pageURL(server: server, code: tricky).absoluteString, "https://hypervault.store/pair?code=BCDF-2346")
    }
}
