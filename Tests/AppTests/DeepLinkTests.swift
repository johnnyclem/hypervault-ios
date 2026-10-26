import XCTest
@testable import HyperVault

final class DeepLinkTests: XCTestCase {
    private func link(_ text: String) -> DeepLink? { URL(string: text).flatMap(DeepLink.init(url:)) }

    func testCustomSchemeLinks() {
        XCTAssertEqual(link("hypervault://artifact/trip-notes-abc123"), .route(.artifact(slug: "trip-notes-abc123")))
        XCTAssertEqual(link("hypervault://memory/7f1c"), .route(.memory(id: "7f1c")))
        XCTAssertEqual(link("hypervault://tab/memory"), .tab(.memory))
        XCTAssertEqual(link("hypervault://keep?text=Call%20the%20dentist"), .keep(prefill: "Call the dentist"))
        XCTAssertEqual(link("hypervault://pair?code=ABCD-EFGH"), .pair(code: "ABCD-EFGH"))
    }

    func testWebLinks() {
        XCTAssertEqual(link("https://hypervault.store/a/trip-notes-abc123"), .route(.artifact(slug: "trip-notes-abc123")))
        XCTAssertEqual(link("https://sam.vault.cool/a/page-1"), .route(.artifact(slug: "page-1")))
        XCTAssertEqual(link("https://hypervault.store/vault/memory"), .tab(.memory))
        XCTAssertEqual(link("https://hypervault.store/vault/mail"), .route(.mail))
        XCTAssertEqual(link("https://hypervault.store/g/portfolio-site-x1"), .route(.artifact(slug: "portfolio-site-x1")))
        XCTAssertEqual(link("hypervault://mail/msg-42"), .route(.mailThread(id: "msg-42")))
        XCTAssertEqual(link("hypervault://truth/review"), .route(.truthReview))
        XCTAssertEqual(link("hypervault://taskboards"), .route(.taskBoards))
        XCTAssertEqual(link("https://hypervault.store/rooms/abc"), .route(.room(id: "abc")))
        XCTAssertEqual(link("https://hypervault.store/login?invite=HV-AB12-CD34"), .invite(code: "HV-AB12-CD34"))
    }

    func testUnknownLinksAreIgnored() {
        XCTAssertNil(link("hypervault://auth/callback?code=x"))
        XCTAssertNil(link("https://hypervault.store/"))
        XCTAssertNil(link("mailto:a@b.co"))
    }

    func testDestinations() {
        XCTAssertEqual(DeepLink.route(.artifact(slug: "x")).destination.tab, .yours)
        XCTAssertEqual(DeepLink.route(.room(id: "x")).destination.tab, .chat)
        XCTAssertEqual(DeepLink.route(.mail).destination.tab, .you)
        XCTAssertEqual(DeepLink.keep(prefill: nil).destination.tab, .canvas)
    }
}
