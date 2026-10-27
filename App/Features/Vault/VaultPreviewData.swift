#if DEBUG
import HyperVaultKit

/// Canned answers for the Vault screens in previews, snapshot tests and unit tests: six entries, the three agent keys
/// of `KeysPreviewData`, and which key may read what.
enum VaultPreviewData {
    static let secretsJSON = """
    {"secrets":[
      {"id":"s1","name":"github.com","kind":"login","description":"Work account","created_at":"2026-10-20T10:00:00Z","updated_at":"2026-10-20T10:00:00Z","last_accessed_at":"2026-10-25T09:30:00Z","hint":"jane@appleseed.dev"},
      {"id":"s2","name":"visa-4242","kind":"card","description":null,"created_at":"2026-10-21T10:00:00Z","updated_at":"2026-10-21T10:00:00Z","last_accessed_at":null,"hint":"Visa •••• 4242"},
      {"id":"s3","name":"amex-0005","kind":"card","description":null,"created_at":"2026-10-21T11:00:00Z","updated_at":"2026-10-21T11:00:00Z","last_accessed_at":"2026-10-22T09:30:00Z","hint":"Amex •••• 0005"},
      {"id":"s4","name":"contact","kind":"contact","description":null,"created_at":"2026-10-22T10:00:00Z","updated_at":"2026-10-22T10:00:00Z","last_accessed_at":null,"hint":"jane@appleseed.dev"},
      {"id":"s5","name":"home","kind":"contact","description":null,"created_at":"2026-10-22T10:00:00Z","updated_at":"2026-10-22T10:00:00Z","last_accessed_at":null,"hint":"Address"},
      {"id":"s6","name":"stripe-restricted-key","kind":"opaque","description":"Read-only","created_at":"2026-10-23T10:00:00Z","updated_at":"2026-10-23T10:00:00Z","last_accessed_at":"2026-10-24T09:30:00Z","hint":null}
    ]}
    """

    static let routes: [MockRoute] = [
        .json(.get, "/api/secrets", secretsJSON),
        .json(.get, "/rest/v1/api_keys", KeysPreviewData.keysJSON),
    ] + grantRoutes

    /// Which keys may read each entry: Claude Code the first, nothing else. One route a name, so no entry in the
    /// previews or the snapshots asks for a grants list the canned server does not have.
    static let grantRoutes: [MockRoute] = ["github.com", "visa-4242", "amex-0005", "contact", "home", "stripe-restricted-key"].map { name in
        MockRoute.json(.get, "/api/secrets/\(name)/grants", #"{"grants":[{"id":"g1","api_key_id":"k1","created_at":"2026-10-24T10:00:00Z"}]}"#)
    }
}
#endif
