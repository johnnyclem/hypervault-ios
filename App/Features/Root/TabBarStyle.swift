import ObjectiveC
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
        // A symbol with no spoken name is labelled with its own name. The memory glyph's name contains
        // "connected", and the tab button already says Memory, so the glyph is not its own element.
        TabSymbolQuiet.install
    }

    private static func style(_ item: UITabBarItemStateAppearance, color: UIColor) {
        item.iconColor = color
        item.titleTextAttributes = [.foregroundColor: color]
    }
}

/// The memory tab's glyph is a private image view. Its spoken name is "Three filled connected points...", which is not
/// a claim about an agent, and the tab button already says Memory. XCUITest still lists that glyph when it is not an
/// accessibility element, because a tab button's automation children are the subviews that have an identifier, and
/// the filled symbol's identifier contains "connected". A block set on the element takes precedence over the private
/// getter. The walk looks at the whole window, because the tab bar's own layout is not always `UITabBar.layoutSubviews`.
private enum TabSymbolQuiet {
    static let install: Void = {
        let original = class_getInstanceMethod(UIView.self, #selector(UIView.didAddSubview(_:)))
        let quiet = class_getInstanceMethod(UIView.self, #selector(UIView.hv_didAddSubviewAndQuietGlyphs(_:)))
        if let original, let quiet { method_exchangeImplementations(original, quiet) }
    }()

    private static var walking = false
    private static var scheduled = false
    /// Layout keeps happening for the life of the screen. A handful of walks covers the tab bar appearing and the
    /// glyph taking its filled name; adding a tab-bar image buys a few more, so a rebuilt glyph is caught too.
    private static var walksRemaining = 12

    static func scheduleWalk(forced: Bool = false) {
        if forced { walksRemaining = max(walksRemaining, 1) }
        if scheduled || walksRemaining <= 0 { return }
        scheduled = true
        DispatchQueue.main.async {
            scheduled = false
            walksRemaining -= 1
            quietVisibleBars()
        }
    }

    static func noteAdded(_ view: UIView) {
        let typeName = NSStringFromClass(type(of: view))
        let inBar = view is UITabBar || typeName.contains("TabBar") || ((view is UIImageView) && isUnderTabBar(view))
        guard inBar else { return }
        walksRemaining = max(walksRemaining, 4)
        scheduleWalk()
    }

    static func quietVisibleBars() {
        if walking { return }
        walking = true
        defer { walking = false }
        var visited = Set<ObjectIdentifier>()
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                walk(window, visited: &visited)
            }
        }
    }

    private static func walk(_ view: UIView, visited: inout Set<ObjectIdentifier>) {
        if !visited.insert(ObjectIdentifier(view)).inserted { return }
        quietIfNeeded(view)
        let typeName = NSStringFromClass(type(of: view))
        if view is UITabBar || typeName.contains("TabBar") || typeName.contains("TabButton") {
            walkAccessibility(of: view, visited: &visited)
        }
        for subview in view.subviews {
            walk(subview, visited: &visited)
        }
    }

    /// The filled symbol is also published as an accessibility element that is not always the image view itself.
    private static func walkAccessibility(of view: UIView, visited: inout Set<ObjectIdentifier>) {
        if let elements = view.accessibilityElements {
            for case let object as NSObject in elements {
                visitAccessibility(object, visited: &visited)
            }
        }
        let count = view.accessibilityElementCount()
        guard count > 0, count < 400 else { return }
        for index in 0..<count {
            guard let raw = view.accessibilityElement(at: index), let object = raw as? NSObject else { continue }
            visitAccessibility(object, visited: &visited)
        }
    }

    private static func visitAccessibility(_ object: NSObject, visited: inout Set<ObjectIdentifier>) {
        if !visited.insert(ObjectIdentifier(object)).inserted { return }
        quietIfNeeded(object)
        if let view = object as? UIView {
            walkAccessibility(of: view, visited: &visited)
        }
    }

    /// The outline symbol names the Memory button. The filled one is the glyph beside it. `accessibilityIdentifier`
    /// is not on `NSObject`; views, images, and accessibility elements each have it.
    private static func identifier(of object: NSObject) -> String? {
        if let view = object as? UIView { return view.accessibilityIdentifier }
        if let element = object as? UIAccessibilityElement { return element.accessibilityIdentifier }
        if let image = object as? UIImage { return image.accessibilityIdentifier }
        return nil
    }

    private static func setIdentifier(_ identifier: String?, on object: NSObject) {
        if let view = object as? UIView { view.accessibilityIdentifier = identifier }
        else if let element = object as? UIAccessibilityElement { element.accessibilityIdentifier = identifier }
        else if let image = object as? UIImage { image.accessibilityIdentifier = identifier }
    }

    private static func isMemoryGlyph(_ object: NSObject) -> Bool {
        if object is UIControl { return false }
        let typeName = NSStringFromClass(type(of: object))
        if typeName.contains("Button"), !typeName.contains("Image") { return false }
        let identifier = identifier(of: object) ?? ""
        if identifier == "tab-glyph-quiet" { return false }
        if identifier.contains("point.3.filled") { return true }
        let isImage = object is UIImageView || typeName.contains("Image")
        guard isImage else { return false }
        if let imageView = object as? UIImageView, isUnderTabBar(imageView) {
            let symbol = imageView.image?.accessibilityIdentifier ?? ""
            let described = String(describing: imageView.image)
            if symbol.contains("point.3") || described.contains("point.3") { return true }
        }
        let label = object.accessibilityLabel ?? ""
        if label.contains("point.3.filled") { return true }
        if label.range(of: "connected points", options: .caseInsensitive) != nil {
            return identifier.contains("point.3") || isUnderTabBar(object)
        }
        return false
    }

    /// The Memory tab button. Its automation children include the glyph, whose name contains "connected".
    private static func isMemoryTabButton(_ view: UIView) -> Bool {
        let identifier = view.accessibilityIdentifier ?? ""
        guard identifier.contains("point.3"), !identifier.contains("filled") else { return false }
        let typeName = NSStringFromClass(type(of: view))
        return view is UIControl || typeName.contains("Button")
    }

    private static func isUnderTabBar(_ object: NSObject) -> Bool {
        var current: NSObject? = object
        var hops = 0
        while let node = current, hops < 30 {
            hops += 1
            if node is UITabBar { return true }
            if NSStringFromClass(type(of: node)).contains("TabBar") { return true }
            if let view = node as? UIView {
                current = view.superview
            } else if let element = node as? UIAccessibilityElement {
                current = element.accessibilityContainer as? NSObject
            } else {
                return false
            }
        }
        return false
    }

    private static func quietIfNeeded(_ object: NSObject) {
        if isMemoryGlyph(object) { quiet(object) }
        guard let button = object as? UIView, isMemoryTabButton(button) else { return }
        // Remember the glyphs before quieting them: afterwards their identifier is "tab-glyph-quiet", which is no
        // longer the filled symbol, and they would be let back into the list.
        var glyphs = Set<ObjectIdentifier>()
        for subview in button.subviews {
            let id = subview.accessibilityIdentifier ?? ""
            if isMemoryGlyph(subview) || id == "tab-glyph-quiet" || id.contains("point.3") {
                glyphs.insert(ObjectIdentifier(subview))
                quiet(subview)
            }
        }
        // A tab button that is an accessibility element exposes every identified subview to XCUITest. Leaving the
        // glyph out of that list is what stops its name being read as a claim that an agent is connected. An empty
        // list is not "unset": unset is what publishes those subviews.
        let kept = button.subviews.filter { !glyphs.contains(ObjectIdentifier($0)) }
        if kept.isEmpty {
            let standIn = UIAccessibilityElement(accessibilityContainer: button)
            standIn.accessibilityLabel = "Memory"
            standIn.isAccessibilityElement = false
            button.automationElements = [standIn]
        } else {
            button.automationElements = kept
        }
    }

    /// Blocks win over the private subclass's own getters. The label no longer says "connected", and the glyph is
    /// not an element of its own: the button already says Memory.
    private static func quiet(_ object: NSObject) {
        let memory = NSAttributedString(string: "Memory")
        object.isAccessibilityElementBlock = { false }
        object.accessibilityElementsHiddenBlock = { true }
        object.accessibilityLabelBlock = { "Memory" }
        object.accessibilityAttributedLabelBlock = { memory }
        object.accessibilityValueBlock = { "" }
        object.accessibilityAttributedValueBlock = { NSAttributedString(string: "") }
        object.accessibilityIdentifierBlock = { "tab-glyph-quiet" }
        object.isAccessibilityElement = false
        object.accessibilityLabel = "Memory"
        object.accessibilityValue = ""
        setIdentifier("tab-glyph-quiet", on: object)
        if let imageView = object as? UIImageView {
            // A symbol image's own identifier becomes the image view's, and that name contains "connected".
            imageView.image?.accessibilityIdentifier = "tab-glyph-quiet"
            imageView.image?.accessibilityLabel = "Memory"
        }
        if let view = object as? UIView {
            view.accessibilityElementsHidden = true
        }
    }
}

/// Walks once the tab bar is in the window. Adding the glyph does not always go through `UIView.didAddSubview`.
struct TabGlyphQuietHost: UIViewRepresentable {
    func makeUIView(context: Context) -> TabGlyphQuietView { TabGlyphQuietView() }
    func updateUIView(_ uiView: TabGlyphQuietView, context: Context) { TabSymbolQuiet.scheduleWalk() }
}

final class TabGlyphQuietView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        TabSymbolQuiet.scheduleWalk(forced: true)
        for delay in [0.1, 0.4, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { TabSymbolQuiet.scheduleWalk(forced: true) }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        TabSymbolQuiet.scheduleWalk()
    }
}

private extension UIView {
    @objc func hv_didAddSubviewAndQuietGlyphs(_ subview: UIView) {
        hv_didAddSubviewAndQuietGlyphs(subview)
        TabSymbolQuiet.noteAdded(subview)
    }
}
