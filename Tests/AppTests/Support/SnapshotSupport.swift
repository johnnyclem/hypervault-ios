import SwiftUI
import UIKit
import XCTest

/// One of each kind of surface, drawn in both looks on every run, so a light look that slips is seen in the published
/// renders and not on somebody's phone: a list on the page, a card, a form of fields, a form under section notes, a
/// sheet, a chat, a graph, a diff, the tag colours, the welcome story, the lock.
let lightLookScreens: Set<String> = [
    "yours", "yours-empty", "settings-panes", "settings", "welcome-1-keep", "lock",
    "chat-list", "home-starter", "chat-conversation", "chat-connect-form", "pane-models", "pane-general-pro",
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
    _ = try renderSnapshot(view, named: name, size: size, settle: settle, schemes: schemes, file: file, line: line)
}

/// `snapshot`, handing back the images it drew (one per scheme, in the order drawn), so a test can look at what a pixel is.
@MainActor
func renderSnapshot<V: View>(
    _ view: V,
    named name: String,
    size: CGSize = CGSize(width: 393, height: 852),
    settle: TimeInterval = 1.0,
    schemes: [UIUserInterfaceStyle]? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> [UIImage] {
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HV_SNAPSHOT_DIR"] ?? NSTemporaryDirectory())
        .appendingPathComponent("snapshots", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    var images: [UIImage] = []
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
        images.append(image)
    }
    return images
}

/// A view held in a window of its own, drawn as often as a test asks, so a test can change something and look again.
@MainActor
final class LiveWindow {
    let window: UIWindow
    private let host: UIViewController
    let size: CGSize

    init<V: View>(_ view: V, size: CGSize = CGSize(width: 393, height: 852), scheme: UIUserInterfaceStyle = .dark) {
        self.size = size
        let host = UIHostingController(rootView: view)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(origin: .zero, size: size))
        window.frame = CGRect(origin: .zero, size: size)
        window.windowLevel = .alert + 1
        window.overrideUserInterfaceStyle = scheme
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        self.host = host
        self.window = window
    }

    /// Lets updates the app made run: observation tells SwiftUI, SwiftUI lays out and draws on the next turns of the run loop.
    func settle(_ seconds: TimeInterval = 0.6) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        host.view.layoutIfNeeded()
    }

    func draw() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    func close() {
        window.isHidden = true
    }
}

/// The pixels of a render in sRGB, so a test can ask what colour a point or a column of the screen is whatever colour space
/// the device drew in.
struct PixelBuffer {
    let width: Int
    let height: Int
    let scale: CGFloat
    private let bytes: [UInt8]

    init?(_ image: UIImage) {
        guard let cg = image.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var data = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            return true
        }
        guard drawn else { return nil }
        width = cg.width
        height = cg.height
        scale = image.scale
        bytes = data
    }

    /// The colour at a point (in points, from the top left), as 0xRRGGBB.
    func color(x: CGFloat, y: CGFloat) -> UInt32? {
        let column = Int(x * scale), row = Int(y * scale)
        guard column >= 0, row >= 0, column < width, row < height else { return nil }
        let index = (row * width + column) * 4
        return UInt32(bytes[index]) << 16 | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2])
    }

    /// Whether a colour is within `tolerance` steps of 255 in every channel.
    static func same(_ a: UInt32, _ b: UInt32, tolerance: Int = 4) -> Bool {
        [UInt32(16), 8, 0].allSatisfy { abs(Int((a >> $0) & 0xFF) - Int((b >> $0) & 0xFF)) <= tolerance }
    }

    /// Whether anywhere down the column at `x` (in points) is `hex`.
    func column(x: CGFloat, contains hex: UInt32, tolerance: Int = 4) -> Bool {
        let column = Int(x * scale)
        guard column >= 0, column < width else { return false }
        for row in 0..<height {
            let index = (row * width + column) * 4
            let value = UInt32(bytes[index]) << 16 | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2])
            if Self.same(value, hex, tolerance: tolerance) { return true }
        }
        return false
    }
}
