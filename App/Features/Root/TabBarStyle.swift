import SwiftUI
import UIKit

/// The tab bar's colours, from the iOS guides: the selected item is the page's own text in the dark look and
/// `primary` in the light look, and the others are `muted-foreground`. It is set on the bar itself, not with `.tint`
/// on the `TabView`, which would retint every control inside it.
///
/// The appearance is the system's default one with only the item colours changed. It sets no background colour and no
/// background effect: on iOS 26 either one replaces the Liquid Glass bar with a flat one.
enum HVTabBarStyle {
    @MainActor
    static func install() {
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        let quiet = UIColor(named: "muted-foreground") ?? .secondaryLabel
        let selected = UIColor { traits in
            let name = traits.userInterfaceStyle == .light ? "primary" : "foreground"
            return UIColor(named: name)?.resolvedColor(with: traits) ?? .label
        }
        for layout in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance, appearance.compactInlineLayoutAppearance] {
            style(layout.normal, color: quiet)
            style(layout.selected, color: selected)
        }
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    private static func style(_ item: UITabBarItemStateAppearance, color: UIColor) {
        item.iconColor = color
        item.titleTextAttributes = [.foregroundColor: color]
    }
}
