import Foundation

/// Tells the first launch of an install from every launch after it.
///
/// The Keychain outlives an uninstall and the app's own preferences do not, so a session the Keychain still holds on
/// the first launch of a new install was made by an earlier one. It is ended there, so deleting the app and putting it
/// back does not sign the previous person in again. An update from a build that kept no marker is not a new install:
/// the story has been seen on this phone (`PrefKey.onboarded`, which sits in the same preferences), and the session
/// stays.
struct InstallMarker {
    static let key = "hv.installed.v1"

    /// The app's own preferences, not the app group's: the extensions share that suite, and only this app's launch
    /// decides what an install is.
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether the Keychain's session, if there is one, belongs to an earlier install.
    var isNewInstall: Bool {
        !defaults.bool(forKey: Self.key) && !defaults.bool(forKey: PrefKey.onboarded)
    }

    /// Records that this install has launched and settled what the Keychain holds.
    func mark() {
        defaults.set(true, forKey: Self.key)
    }
}
