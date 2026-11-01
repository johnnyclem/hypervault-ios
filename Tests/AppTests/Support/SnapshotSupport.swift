import SwiftUI
import UIKit
import XCTest

/// One of each kind of surface, drawn in both looks on every run, so a light look that slips is seen in the published
/// renders and not on somebody's phone: a list on the page, a card, a form of fields, a form under section notes, a
/// sheet, a chat, a graph, a diff, the tag colours, the welcome story, the lock.
let lightLookScreens: Set<String> = [
    "yours", "yours-empty", "you", "settings", "welcome-1-keep", "lock",
    "chat-list", "chat-conversation", "chat-connect-form", "pane-models", "pane-general-pro",
    "digest", "design-controls", "design-details", "design-palette", "force-graph", "group-new",
    "memory-list", "memory-graph", "memory-graph-controls", "memory-ask", "memory-memorize", "mind-diff", "mind-merge-preview", "library-all",
    "keys-webhooks-add", "mail-compose", "mail-settings", "realms-detail",
    "taskboards-board", "taskboards-task", "tools-list", "tools-add-form", "truth-entry",
    "vault-add-card", "vault-add-login", "vault-detail-card", "admin-accounts",
]

/// Renders a SwiftUI screen the way the device would (inside a real window, so
/// List, NavigationStack and TabView draw) and writes it as a PNG. CI uploads
/// the folder, so a screen can be looked at without running a simulator. The app follows the system. The renders are
/// in the dark, the look the published PNGs are read against, and the screens in `lightLookScreens` are drawn in the
/// light look as well (`<name>-light.png`); pass `schemes` to choose for one screen.
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
    schemes: [UIUserInterfaceStyle]? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HV_SNAPSHOT_DIR"] ?? NSTemporaryDirectory())
        .appendingPathComponent("snapshots", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    for scheme in schemes ?? (lightLookScreens.contains(name) ? [.dark, .light] : [.dark]) {
        let host = UIHostingController(rootView: view)
        // The window must belong to the host app's scene, or nothing is drawn.
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(origin: .zero, size: size))
        window.frame = CGRect(origin: .zero, size: size)
        window.windowLevel = .alert + 1
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
