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
        if let appGroup, !appGroup.isEmpty, let shared = UserDefaults(suiteName: appGroup) { return shared }
        return .standard
    }

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

    /// A client for the signed-in person, as an extension would build one.
    /// Nil until the app has signed in at least once.
    static func makeClient() -> (client: HVClient, auth: AuthService)? {
        guard let supabase else { return nil }
        let auth = AuthService(config: supabase, store: KeychainSecureStore())
        let client = HVClient(baseURL: server.baseURL, tokens: auth)
        return (client, auth)
    }
}
