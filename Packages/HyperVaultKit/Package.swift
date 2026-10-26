// swift-tools-version: 6.0
import PackageDescription

// HyperVaultKit is everything the app needs that is not UI: the typed API
// client, auth, models, caches. It depends on Foundation only, so it builds and
// its tests run on Linux as well as Apple platforms (`swift test` in this
// folder). All SwiftUI lives in the app targets.
let package = Package(
    name: "HyperVaultKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "HyperVaultKit", targets: ["HyperVaultKit"]),
    ],
    targets: [
        .target(name: "HyperVaultKit"),
        .testTarget(name: "HyperVaultKitTests", dependencies: ["HyperVaultKit"]),
    ],
    swiftLanguageModes: [.v6]
)
