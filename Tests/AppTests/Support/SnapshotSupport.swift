import SwiftUI
import UIKit
import XCTest

/// Renders a SwiftUI screen the way the device would (inside a real window, so
/// List, NavigationStack and TabView draw) and writes it as a PNG. CI uploads
/// the folder, so a screen can be looked at without running a simulator.
///
///     @MainActor func testYours() throws {
///         try snapshot(PreviewHost(routes: [...]) { YoursRootView() }, named: "yours")
///     }
@MainActor
func snapshot<V: View>(
    _ view: V,
    named name: String,
    size: CGSize = CGSize(width: 393, height: 852),
    settle: TimeInterval = 1.0,
    schemes: [UIUserInterfaceStyle] = [.light, .dark],
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HV_SNAPSHOT_DIR"] ?? NSTemporaryDirectory())
        .appendingPathComponent("snapshots", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    for scheme in schemes {
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.overrideUserInterfaceStyle = scheme
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()

        // Let `.task` loads, animations and layout settle.
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        host.view.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard let data = image.pngData() else {
            XCTFail("Could not encode \(name)", file: file, line: line)
            continue
        }
        let suffix = scheme == .dark ? "dark" : "light"
        try data.write(to: folder.appendingPathComponent("\(name)-\(suffix).png"))
        window.isHidden = true
    }
}
