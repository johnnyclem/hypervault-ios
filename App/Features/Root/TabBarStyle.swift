import SwiftUI
import UIKit

/// The tab bar's colours: the selected item takes the web's `accent`, as the web's dock does, and the others its
/// `muted-foreground`. It is set on the bar itself, not with `.tint` on the `TabView`, which would retint every control
/// inside it.
///
/// The appearance is the system's default one with only the item colours changed. It sets no background colour and no
/// background effect: on iOS 26 either one replaces the Liquid Glass bar with a flat one.
enum HVTabBarStyle {
    @MainActor
    static func install() {
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        for layout in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance, appearance.compactInlineLayoutAppearance] {
            style(layout.normal, color: UIColor(HVColor.mutedForeground))
            style(layout.selected, color: UIColor(HVColor.accent))
        }
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    private static func style(_ item: UITabBarItemStateAppearance, color: UIColor) {
        item.iconColor = color
        item.titleTextAttributes = [.foregroundColor: color]
    }
}
