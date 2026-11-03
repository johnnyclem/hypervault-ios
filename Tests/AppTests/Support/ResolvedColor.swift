import SwiftUI
import UIKit
import XCTest

/// What a colour is once the system has resolved it for a look and a contrast setting.
struct ResolvedColor {
    let hex: UInt32
    let alpha: CGFloat
}

func resolveColor(_ color: Color, style: UIUserInterfaceStyle = .light, contrast: UIAccessibilityContrast = .normal) -> ResolvedColor {
    let traits = UITraitCollection(traitsFrom: [UITraitCollection(userInterfaceStyle: style), UITraitCollection(accessibilityContrast: contrast)])
    let resolved = UIColor(color).resolvedColor(with: traits)
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    XCTAssertTrue(resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha), "The colour has no RGB form.")
    func byte(_ value: CGFloat) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
    return ResolvedColor(hex: byte(red) << 16 | byte(green) << 8 | byte(blue), alpha: alpha)
}
