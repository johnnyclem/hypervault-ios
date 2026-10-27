import Foundation

/// Preferences an earlier version wrote that nothing reads any more. The app used to let a person pick System, Light or
/// Dark and one of five accents; the stock look is dark with one accent (handoff 2.2), so what they picked is dropped
/// rather than left on the phone. It runs at every launch and costs one dictionary lookup per key.
enum RetiredPreferences {
    static let keys = ["pref.appearance", "pref.accent"]

    static func remove(from defaults: UserDefaults = .standard) {
        for key in keys { defaults.removeObject(forKey: key) }
    }
}
