import SwiftUI
import UIKit

extension HV {
    /// Motion (handoff 2.6). The web's entrances are 0.15 to 0.22s ease-out and its copied state lasts 1.5s; Reduce Motion
    /// turns every custom animation off. System sheets and pushes animate themselves and are left alone.
    ///
    /// One easing family and three lengths, all ease-out: `press` 0.15s for feedback, `entrance` 0.2s for a thing that
    /// appears or changes in place, `sheet` 0.3s for a thing that travels or reflows. No springs, no overshoot, and no
    /// loop that is not a live state (the thinking dots and the skeleton say that something is loading).
    ///
    /// A view animates through `hvAnimation(_:value:)`; a change made in a closure (a button's action, a scroll) goes
    /// through `HV.Motion.animate`. Both are the usual `animation(_:value:)` and `withAnimation` with the gate in front.
    enum Motion {
        /// Feedback under a finger: a pressed button, a chip taking or losing its fill, a copied mark. Ease-out over 0.15s.
        static let press = Animation.easeOut(duration: 0.15)

        /// How a thing that appears or opens comes in: ease-out over 0.2s.
        static let entrance = Animation.easeOut(duration: 0.2)

        /// A thing that travels or reflows: a toast, a card leaving or arriving, a stage of a flow giving way to the next,
        /// a dragged card going back, a scroll to the newest item. Ease-out over 0.3s.
        static let sheet = Animation.easeOut(duration: 0.3)

        /// How long a button says "Copied" before it goes back to its name, as the web's copy button does.
        static let copiedHold: TimeInterval = 1.5

        /// Whether the person asked the system to reduce motion. The setting is read on the main thread, which is where
        /// SwiftUI changes state; anywhere else there is no animation to gate.
        static var reduceMotion: Bool {
            guard Thread.isMainThread else { return false }
            return MainActor.assumeIsolated { UIAccessibility.isReduceMotionEnabled }
        }

        /// The animation to use: none under Reduce Motion.
        static func resolved(_ animation: Animation?, reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : animation
        }

        /// `withAnimation`, off under Reduce Motion. The change still happens; it just does not move.
        ///
        /// A plain closure, not a generic one that rethrows: the Release compiler of Xcode 26.6 crashed (a SIL verification
        /// error while optimizing) in a caller of the generic form, and nothing here returns a value or throws.
        static func animate(_ animation: Animation? = HV.Motion.entrance, _ body: () -> Void) {
            withAnimation(resolved(animation, reduceMotion: reduceMotion), body)
        }
    }
}

extension View {
    /// `animation(_:value:)`, off under Reduce Motion.
    func hvAnimation<Value: Equatable>(_ animation: Animation?, value: Value) -> some View {
        modifier(HVAnimationModifier(animation: animation, value: value))
    }

    /// A symbol that bounces once when `value` changes, and stays still under Reduce Motion.
    func hvBounce<Value: Equatable>(value: Value) -> some View {
        modifier(HVBounceModifier(value: value))
    }
}

struct HVAnimationModifier<Value: Equatable>: ViewModifier {
    let animation: Animation?
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(HV.Motion.resolved(animation, reduceMotion: reduceMotion), value: value)
    }
}

struct HVBounceModifier<Value: Equatable>: ViewModifier {
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.symbolEffect(.bounce, value: value)
        }
    }
}
