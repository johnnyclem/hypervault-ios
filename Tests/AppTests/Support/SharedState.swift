import Foundation
import HyperVaultKit
@testable import HyperVault

/// What the app keeps in the shared defaults, which every test in the process shares. Tests that sign people in or out, or
/// turn the lock on, call `begin()` in `setUp` and `end()` in `tearDown`, so they do not see each other's leftovers and the
/// server and project the other tests found are put back.
enum SharedState {
    private static var server: ServerConfig?
    private static var supabase: SupabaseConfig?

    static func begin() {
        server = SharedConfig.server
        supabase = SharedConfig.supabase
        clear()
        // A session the tests seed is theirs; without the marker, launch would take it for a previous install's and end it.
        InstallMarker().mark()
    }

    static func end() {
        clear()
        if let server { SharedConfig.server = server }
        SharedConfig.supabase = supabase
    }

    private static func clear() {
        let defaults = SharedConfig.defaults
        for key in [PrefKey.approvedUser, PrefKey.sessionUser, PrefKey.waitlistedUser, SharedConfig.widgetRecentKey] {
            defaults.removeObject(forKey: key)
        }
        SharedConfig.isLockOn = false
        OutboxStore.save([])
        UserDefaults.standard.removeObject(forKey: PrefKey.biometricLock)
        UserDefaults.standard.removeObject(forKey: SpotlightIndexer.preferenceKey)
    }
}
