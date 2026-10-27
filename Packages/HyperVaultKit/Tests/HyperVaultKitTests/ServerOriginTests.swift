import XCTest
@testable import HyperVaultKit

final class ServerOriginTests: XCTestCase {
    func testTheOriginIsTheSchemeHostAndPortWithNoPath() {
        XCTAssertEqual(ServerOrigin.string(of: URL(string: "https://hypervault.store")!), "https://hypervault.store")
        XCTAssertEqual(ServerOrigin.string(of: URL(string: "https://hypervault.store/")!), "https://hypervault.store")
        XCTAssertEqual(ServerOrigin.string(of: URL(string: "https://my.host:8443/base")!), "https://my.host:8443")
        XCTAssertEqual(ServerOrigin.string(of: URL(string: "http://localhost:3000")!), "http://localhost:3000")
    }
}
