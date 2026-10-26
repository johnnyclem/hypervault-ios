import Foundation

// Realms: the addresses a person claims (you.vault.cool and the rest of the
// portfolio), each wearing a look and optionally opening to one of their pages.
// The web app's source is app/api/claim-domain/route.ts (availability, claim,
// restyle), lib/domains.ts, components/domain-picker.tsx,
// components/theme-switcher.tsx and app/upgrade/page.tsx.
//
// No route lists a person's claims: the account page reads `domain_claims` on
// the server. RLS lets a signed-in session read them (and they are public by
// design, for availability checks), so `RealmDirectory` reads them through
// PostgREST like the keys list.

// MARK: Rows

/// One claimed address.
public struct RealmClaim: Sendable, Codable, Identifiable, Hashable {
    public let id: String
    public let subdomain: String
    public let baseDomain: String
    /// A style id from `Capabilities.themes`, or nil for the base domain's default look.
    public let theme: String?
    /// The slug of the artifact served at the address's bare root, or nil for the vault index.
    public let defaultArtifactSlug: String?
    public let claimedAt: Date?

    public init(
        id: String, subdomain: String, baseDomain: String = "vault.cool", theme: String? = nil,
        defaultArtifactSlug: String? = nil, claimedAt: Date? = nil
    ) {
        self.id = id
        self.subdomain = subdomain
        self.baseDomain = baseDomain
        self.theme = theme
        self.defaultArtifactSlug = defaultArtifactSlug
        self.claimedAt = claimedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let sub = try c.decode(String.self, forKey: .subdomain)
        let base = try c.decodeIfPresent(String.self, forKey: .baseDomain) ?? "vault.cool"
        subdomain = sub
        baseDomain = base
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? "\(sub).\(base)"
        theme = try c.decodeIfPresent(String.self, forKey: .theme)
        defaultArtifactSlug = try c.decodeIfPresent(String.self, forKey: .defaultArtifactSlug)
        claimedAt = try c.decodeIfPresent(Date.self, forKey: .claimedAt)
    }

    enum Keys: String, CodingKey { case id, subdomain, baseDomain, theme, defaultArtifactSlug, claimedAt }

    /// `nova.vault.cool`.
    public var host: String { "\(subdomain).\(baseDomain)" }
    public var url: URL? { URL(string: "https://\(host)") }
}

/// One of the person's single-page artifacts, offered as a realm's home page.
public struct RealmHomeOption: Sendable, Codable, Identifiable, Hashable {
    public let slug: String
    public let title: String
    /// `public`, `private` or `password`; nil on a database from before visibility.
    public let visibility: String?

    public var id: String { slug }

    public init(slug: String, title: String, visibility: String? = nil) {
        self.slug = slug
        self.title = title
        self.visibility = visibility
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        slug = try c.decode(String.self, forKey: .slug)
        let raw = try c.decodeIfPresent(String.self, forKey: .title)?.trimmingCharacters(in: .whitespacesAndNewlines)
        title = (raw?.isEmpty == false ? raw : nil) ?? "Untitled artifact"
        visibility = try c.decodeIfPresent(String.self, forKey: .visibility)
    }

    enum Keys: String, CodingKey { case slug, title, visibility }

    /// Visitors would see the lock page instead of the artifact.
    public var isGated: Bool { visibility != nil && visibility != "public" }
}

/// What the Your address screen shows.
public struct RealmsSnapshot: Sendable, Codable, Equatable {
    public var claims: [RealmClaim]
    public var isPro: Bool
    public var homeOptions: [RealmHomeOption]

    public init(claims: [RealmClaim] = [], isPro: Bool = false, homeOptions: [RealmHomeOption] = []) {
        self.claims = claims
        self.isPro = isPro
        self.homeOptions = homeOptions
    }
}

/// Reads the person's claims, plan and candidate home pages through PostgREST, as the web page does on the server.
public enum RealmDirectory {
    /// The person's claims, oldest first. A database from before migration 0031 has no
    /// `default_artifact_slug`: ask again without it. A profile from before the `domain_claims`
    /// backfill may only carry `vanity_subdomain`: that realm is included so the screen and the header agree.
    public static func claims(rest: AccountRest, userID: String, legacySubdomain: String?) async throws -> [RealmClaim] {
        func query(_ columns: String) -> [URLQueryItem] {
            [
                URLQueryItem(name: "select", value: columns),
                URLQueryItem(name: "user_id", value: "eq.\(userID)"),
                URLQueryItem(name: "order", value: "claimed_at.asc"),
                URLQueryItem(name: "limit", value: "50"),
            ]
        }
        var claims: [RealmClaim]
        do {
            claims = try await rest.rows(RealmClaim.self, from: "domain_claims", query: query("id,subdomain,base_domain,theme,default_artifact_slug,claimed_at"))
        } catch where AccountRest.isMissingColumn(error) {
            claims = try await rest.rows(RealmClaim.self, from: "domain_claims", query: query("id,subdomain,base_domain,theme,claimed_at"))
        }
        if claims.isEmpty, let legacy = legacySubdomain, !legacy.isEmpty {
            claims = [RealmClaim(id: "legacy-\(legacy)", subdomain: legacy, baseDomain: "vault.cool")]
        }
        return claims
    }

    /// The recent single-page artifacts a realm can open to. Groups live under `/g/[slug]/…` and would
    /// break at a bare root, so they are left out.
    public static func homeOptions(rest: AccountRest, userID: String) async throws -> [RealmHomeOption] {
        func query(_ columns: String) -> [URLQueryItem] {
            [
                URLQueryItem(name: "select", value: columns),
                URLQueryItem(name: "user_id", value: "eq.\(userID)"),
                URLQueryItem(name: "type", value: "neq.group"),
                URLQueryItem(name: "order", value: "created_at.desc"),
                URLQueryItem(name: "limit", value: "30"),
            ]
        }
        do {
            return try await rest.rows(RealmHomeOption.self, from: "artifacts", query: query("slug,title,type,visibility"))
        } catch where AccountRest.isMissingColumn(error) {
            return try await rest.rows(RealmHomeOption.self, from: "artifacts", query: query("slug,title,type"))
        }
    }

    public static func snapshot(rest: AccountRest, userID: String) async throws -> RealmsSnapshot {
        // The profile first: its vanity subdomain stands in for a claim that predates the claims table.
        let profile = try? await rest.profile(userID: userID)
        let claims = try await claims(rest: rest, userID: userID, legacySubdomain: profile?.vanitySubdomain)
        let options = (try? await homeOptions(rest: rest, userID: userID)) ?? []
        return RealmsSnapshot(claims: claims, isPro: profile?.isPro ?? !claims.isEmpty, homeOptions: options)
    }
}

// MARK: Availability, claim, restyle

/// `GET /api/claim-domain?name=&base=`: a live availability check.
public struct ClaimAvailability: Sendable, Decodable, Equatable {
    public let available: Bool
    public let reason: String?

    public init(available: Bool, reason: String? = nil) {
        self.available = available
        self.reason = reason
    }
}

/// `POST /api/claim-domain`: the address is yours, effective immediately.
public struct ClaimResult: Sendable, Decodable, Equatable {
    public let domain: String
    public let url: String?
    public let claimed: Int?
    public let maxSubdomains: Int?
    public let message: String?
}

/// `PATCH /api/claim-domain`: the look and home page the address now has.
public struct RealmUpdate: Sendable, Decodable, Equatable {
    public let domain: String
    public let theme: String?
    public let defaultArtifact: String?
    public let url: String?
    /// A private or password-gated home page serves as its lock screen; the server says so.
    public let warning: String?
    public let message: String?
}

extension Endpoint where Response == ClaimAvailability {
    /// Public by design (claims are readable anyway), rate limited by address.
    public static func claimAvailability(name: String, base: String) -> Endpoint<ClaimAvailability> {
        Endpoint(.get, "/api/claim-domain", query: [URLQueryItem(name: "name", value: name), URLQueryItem(name: "base", value: base)], auth: .none)
    }
}

extension Endpoint where Response == ClaimResult {
    /// Claims `name.base`. 409 is taken, 403 is the Pro limit; both carry the server's sentence.
    public static func claimRealm(name: String, base: String) -> Endpoint<ClaimResult> {
        Endpoint(.post, "/api/claim-domain", body: .jsonValue(["desired_name": .string(name), "base_domain": .string(base)]))
    }
}

extension Endpoint where Response == RealmUpdate {
    /// Sets one claimed address's look. A nil theme goes back to the base domain's default.
    public static func setRealmTheme(subdomain: String, base: String, theme: String?) -> Endpoint<RealmUpdate> {
        Endpoint(
            .patch, "/api/claim-domain",
            body: .jsonValue(["subdomain": .string(subdomain), "base_domain": .string(base), "theme": theme.map(JSONValue.string) ?? .null])
        )
    }

    /// Pins one of the person's artifacts at the address's bare root. Nil goes back to serving the vault index.
    /// The theme is left alone: a body without `theme` changes only the home page.
    public static func setRealmHome(subdomain: String, base: String, artifactSlug: String?) -> Endpoint<RealmUpdate> {
        Endpoint(
            .patch, "/api/claim-domain",
            body: .jsonValue(["subdomain": .string(subdomain), "base_domain": .string(base), "default_artifact": artifactSlug.map(JSONValue.string) ?? .null])
        )
    }
}

// MARK: Rules and words

public enum RealmRules {
    /// Names that can never be claimed (lib/domains.ts).
    static let reserved: Set<String> = [
        "www", "app", "api", "mcp", "mail", "mx", "auth", "beta", "alpha", "admin",
        "root", "dashboard", "vault", "help", "support", "docs", "blog", "status",
        "dev", "staging", "test", "assets", "cdn", "static", "hypervault",
        "billing", "login", "signup", "graph", "wss", "secure",
    ]

    /// The default Pro limit when the server does not say (`Capabilities.Limits.maxProSubdomains`).
    public static let defaultMaxClaims = 10

    /// Port of `validateSubdomain`: the name normalized, or the sentence that says what is wrong with it.
    public static func validate(_ raw: String) -> Result<String, ValidationError> {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let scalars = Array(name.unicodeScalars)
        if scalars.count < 2 { return .failure(ValidationError(message: "Pick at least 2 characters.")) }
        if scalars.count > 63 { return .failure(ValidationError(message: "Subdomains max out at 63 characters.")) }
        let allowed: (Unicode.Scalar) -> Bool = { ($0.value >= 0x61 && $0.value <= 0x7A) || ($0.value >= 0x30 && $0.value <= 0x39) || $0 == "-" }
        if !scalars.allSatisfy(allowed) || scalars.first == "-" || scalars.last == "-" {
            return .failure(ValidationError(message: "Use only lowercase letters, numbers, and hyphens (no leading/trailing hyphen)."))
        }
        if reserved.contains(name) || name.hasPrefix("www") {
            return .failure(ValidationError(message: "\"\(name)\" is reserved."))
        }
        return .success(name)
    }

    public struct ValidationError: Error, Sendable, Equatable {
        public let message: String
    }

    /// The portfolio the picker shows: the featured address first, then the claimable ones, then those not open yet.
    public static func ordered(_ domains: [Capabilities.PortfolioDomain]) -> [Capabilities.PortfolioDomain] {
        func rank(_ d: Capabilities.PortfolioDomain) -> Int {
            if d.featured && d.available { return 0 }
            return d.available ? 1 : 2
        }
        return domains.enumerated().sorted { a, b in
            let (ra, rb) = (rank(a.element), rank(b.element))
            return ra == rb ? a.offset < b.offset : ra < rb
        }.map(\.element)
    }
}

/// The upgrade page's words (app/upgrade/page.tsx). Payment happens on the web.
public enum RealmPlanCopy {
    public static let title = "Claim your corner of the internet"
    public static let lead = "Free gets you a permanent vault. Pro gets you a legendary address, a domain so cool people ask where you got it."
    public static let freePrice = "$0 / forever"
    public static let proPrice = "$8 / month"
    public static let freeFeatures = [
        "Unlimited saves from chat & MCP",
        "Permanent /a/ links with social previews",
        "Auto-detected React/JSX rendering",
        "PWA install for every artifact",
    ]
    public static let proFeatures = [
        "Everything in Free",
        "Up to 10 legendary addresses (you.vault.cool)",
        "Your full vault lives on every subdomain",
        "Custom vault landing page on your domain",
        "Priority rendering & higher rate limits",
        "Early access to graph view & collections",
    ]
    public static let pickLine = "Choose a base domain from the HyperVault portfolio, pick a name, and it's live immediately."
    public static let domainLine = "Every claimed address serves your whole vault. Visitors see the realm's look; you still get your dashboard."
    public static let appearanceLine = "Each realm can wear its own look, and open straight to an artifact you pick."
    public static let noAddressTitle = "No address yet"
    public static let noAddressDetail = "Claim one and your whole vault is served from it, like you.vault.cool."
    public static let upgradeDetail = "Pro gets you an address of your own, like you.vault.cool."
}
