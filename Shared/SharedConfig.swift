import Foundation
import HyperVaultKit

/// What the app, the share extension and the widgets agree on. The app writes
/// it after it has talked to the server; the extensions only read.
enum SharedConfig {
    /// Set from build settings (Config/Base.xcconfig) through Info.plist.
    static var appGroup: String? { string("HVAppGroup") }
    static var keychainGroup: String? { string("HVKeychainGroup") }

    static var defaultServer: ServerConfig {
        if let text = string("HVDefaultServer"), let config = ServerConfig(userInput: text) { return config }
        return .production
    }

    /// Defaults shared through the app group; falls back to the app's own
    /// when the group is not available (an unsigned build).
    static var defaults: UserDefaults {
        #if DEBUG
        if let scratchDefaults { return scratchDefaults }
        #endif
        if let appGroup, !appGroup.isEmpty, let shared = UserDefaults(suiteName: appGroup) { return shared }
        return .standard
    }

    #if DEBUG
    /// Set only by the UI-test mode (`UITestHarness`), so a run's shared state is a scratch suite of its own and never
    /// the app group's. Always nil in a normal launch and absent from release builds.
    static var scratchDefaults: UserDefaults?
    #endif

    private static func string(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String, !value.isEmpty, !value.hasPrefix("$(") else {
            return nil
        }
        return value
    }

    // MARK: Values the extensions need

    private static let serverKey = "hv.server"
    private static let supabaseKey = "hv.supabase"

    static var server: ServerConfig {
        get {
            guard let data = defaults.data(forKey: serverKey),
                  let config = try? JSONDecoder().decode(ServerConfig.self, from: data)
            else { return defaultServer }
            return config
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: serverKey)
        }
    }

    static var supabase: SupabaseConfig? {
        get {
            guard let data = defaults.data(forKey: supabaseKey) else { return nil }
            return try? JSONDecoder().decode(SupabaseConfig.self, from: data)
        }
        set {
            if let newValue {
                defaults.set(try? JSONEncoder().encode(newValue), forKey: supabaseKey)
            } else {
                defaults.removeObject(forKey: supabaseKey)
            }
        }
    }

    // MARK: What the widgets and Siri must not show while the lock is on

    private static let lockKey = "hv.lock"

    /// Whether the Face ID lock is on. The preference itself is the app's (`PrefKey.biometricLock`); this is
    /// its copy for the widgets and the Keep intent, which run outside the app and cannot ask for Face ID, so
    /// while it is on they must not show what is kept or write to it.
    static var isLockOn: Bool {
        get { defaults.bool(forKey: lockKey) }
        set { defaults.set(newValue, forKey: lockKey) }
    }

    /// Where the widget remembers the last names it showed, so it has something to say offline.
    static let widgetRecentKey = "hv.widget.recent"

    /// Drops the widget's remembered names: on sign-out, and when the lock is turned on.
    static func forgetWidgetCache() {
        defaults.removeObject(forKey: widgetRecentKey)
    }

    /// A client for the signed-in person, as an extension would build one.
    /// Nil until the app has signed in at least once.
    static func makeClient() -> (client: HVClient, auth: AuthService)? {
        guard let supabase else { return nil }
        HVURLCache.install()
        let auth = AuthService(config: supabase, store: KeychainSecureStore())
        let client = HVClient(baseURL: server.baseURL, tokens: auth)
        return (client, auth)
    }
}
