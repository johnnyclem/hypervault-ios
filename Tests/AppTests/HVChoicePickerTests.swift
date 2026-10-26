import SwiftUI
import UIKit
import XCTest
@testable import HyperVault

/// A segmented control stays at its small size however large the text is set. At accessibility sizes the choice
/// has to be something else, so these look at what UIKit actually draws.
@MainActor
final class HVChoicePickerTests: XCTestCase {
    private enum Pick: String, CaseIterable, Hashable { case one, two, three }

    private struct Harness: View {
        @State private var pick = Pick.one

        var body: some View {
            HVChoicePicker(title: "Pick", selection: $pick) {
                ForEach(Pick.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
        }
    }

    /// Hosts the picker in a real window, as the snapshots do, and says whether it drew a segmented control.
    private func drawsSegmentedControl(at size: DynamicTypeSize) -> Bool {
        let host = UIHostingController(rootView: Harness().environment(\.dynamicTypeSize, size))
        let frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        defer { window.isHidden = true }
        return Self.contains(UISegmentedControl.self, in: host.view)
    }

    private static func contains<T: UIView>(_ type: T.Type, in view: UIView) -> Bool {
        view is T || view.subviews.contains { contains(type, in: $0) }
    }

    func testAtTheNormalSizeTheChoiceIsSegmented() {
        XCTAssertTrue(drawsSegmentedControl(at: .large))
    }

    func testAtAnAccessibilitySizeTheChoiceIsNoLongerASegmentedControl() {
        XCTAssertFalse(drawsSegmentedControl(at: .accessibility3))
        XCTAssertFalse(drawsSegmentedControl(at: .accessibility5))
    }
}
