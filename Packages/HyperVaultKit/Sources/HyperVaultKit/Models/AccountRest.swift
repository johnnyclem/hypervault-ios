import Foundation

/// Reads from the project's PostgREST with the person's own token, for the
/// few account lists the web app renders on the server straight from the
/// database and no `/api` route returns: their agent keys, the addresses they
/// claimed, their plan. Row-level security scopes every read to the caller, and
/// the columns are the ones the web page selects (`app/vault/account/page.tsx`).
///
/// `client` is an `HVClient` whose base URL is the Supabase project (not the
/// HyperVault server) and whose token provider is the signed-in session, so a
/// 401 refreshes the token as everywhere else. `anonKey` rides as `apikey`.
public struct AccountRest: Sendable {
    public let client: HVClient
    public let anonKey: String

    public init(client: HVClient, anonKey: String) {
        self.client = client
        self.anonKey = anonKey
    }

    /// `GET /rest/v1/<table>?...` decoded as a list of rows.
    public func rows<Row: Decodable & Sendable>(
        _ type: Row.Type = Row.self,
        from table: String,
        query: [URLQueryItem]
    ) async throws -> [Row] {
        try await client.send(Self.select(table, query: query, anonKey: anonKey))
    }

    static func select<Row: Decodable & Sendable>(_ table: String, query: [URLQueryItem], anonKey: String) -> Endpoint<[Row]> {
        Endpoint<[Row]>(.get, "/rest/v1/\(table)", query: query, headers: ["apikey": anonKey])
    }

    /// Whether PostgREST refused a read because a column is missing (a database
    /// that predates a migration): 400 with a column error, or PostgREST's own
    /// code for it. The caller asks again without the column.
    static func isMissingColumn(_ error: Error) -> Bool {
        guard let failure = (error as? HVError)?.failure else { return false }
        if failure.code == "42703" || failure.code == "PGRST204" { return true }
        let text = failure.message.lowercased()
        return failure.status == 400 && text.contains("column")
    }

    /// Whether PostgREST has no such table (a migration that was never run).
    static func isMissingTable(_ error: Error) -> Bool {
        guard let failure = (error as? HVError)?.failure else { return false }
        if failure.code == "42P01" || failure.code == "PGRST205" { return true }
        return failure.status == 404
    }
}

/// `profiles`: the one row of the signed-in person. Only the two columns the
/// account page reads.
public struct AccountProfile: Sendable, Codable, Equatable {
    public let plan: String
    public let vanitySubdomain: String?

    public init(plan: String = "free", vanitySubdomain: String? = nil) {
        self.plan = plan
        self.vanitySubdomain = vanitySubdomain
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        plan = try c.decodeIfPresent(String.self, forKey: .plan) ?? "free"
        vanitySubdomain = try c.decodeIfPresent(String.self, forKey: .vanitySubdomain)
    }

    enum Keys: String, CodingKey { case plan, vanitySubdomain }

    public var isPro: Bool { plan == "pro" }
}

extension AccountRest {
    /// The person's own profile row (plan, vanity subdomain), or nil when there is none.
    public func profile(userID: String) async throws -> AccountProfile? {
        let rows: [AccountProfile] = try await rows(
            from: "profiles",
            query: [
                URLQueryItem(name: "select", value: "plan,vanity_subdomain"),
                URLQueryItem(name: "id", value: "eq.\(userID)"),
                URLQueryItem(name: "limit", value: "1"),
            ]
        )
        return rows.first
    }
}
