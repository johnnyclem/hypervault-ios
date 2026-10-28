import XCTest
@testable import HyperVaultKit

/// The app's navigation links (the tabs, the You panes, the Yours panel, the settings) are for people and for the
/// widgets and Spotlight results the app itself made. A page is untrusted, so none of them may be a page's to open:
/// `ArtifactLinkRouter` lets a page reach a page, a group and `hypervault://artifact/<slug>`, and nothing else.
final class ArtifactLinkNavigationTests: XCTestCase {
    private let router = ArtifactLinkRouter(serverHost: "hypervault.store", domains: ["vault.cool"])

    private func action(_ text: String, tapped: Bool = true) -> ArtifactLinkAction {
        router.action(for: URL(string: text)!, tapped: tapped)
    }

    func testThePageReachableSegmentsAreStillOnlyPagesAndGroups() {
        XCTAssertEqual(ArtifactLinkRouter.pageSegments, ["a", "g", "artifact"])
        XCTAssertEqual(ArtifactLinkRouter.actionSegments, ["pair", "keep", "canvas", "invite", "login"])
    }

    func testAPageCannotDriveTheAppToATabAPaneOrThePanelByItsOwnScheme() {
        let links = [
            "hypervault://tab/you", "hypervault://tab/yours", "hypervault://tab/canvas", "hypervault://tab/home",
            "hypervault://yours", "hypervault://library", "hypervault://settings", "hypervault://account",
            "hypervault://vault", "hypervault://vault/account", "hypervault://vault/account?tab=keys", "hypervault://vault/account#keys",
            "hypervault://vault/library", "hypervault://vault/import", "hypervault://rooms", "hypervault://chat?c=abc",
        ]
        for link in links {
            XCTAssertEqual(action(link), .blocked, link)
            XCTAssertEqual(action(link, tapped: false), .blocked, link)
        }
    }

    func testTheWebsPagesForThemOpenInSafariNotInTheApp() {
        for link in [
            "https://hypervault.store/vault/account?tab=keys", "https://hypervault.store/vault/account#keys",
            "https://hypervault.store/vault", "https://hypervault.store/chat", "https://hypervault.store/vault/memory",
        ] {
            guard case .external = action(link) else {
                XCTFail("\(link) should open on the web, not drive the app.")
                continue
            }
            XCTAssertEqual(action(link, tapped: false), .blocked, "a page's own redirect never leaves the app: \(link)")
        }
    }

    func testAPageStillOpensAPageAndAGroup() {
        for link in ["hypervault://artifact/trip-notes", "https://hypervault.store/a/trip-notes", "https://hypervault.store/g/portfolio"] {
            guard case .hyperVault = action(link) else {
                XCTFail("\(link) is a page.")
                continue
            }
        }
    }
}
