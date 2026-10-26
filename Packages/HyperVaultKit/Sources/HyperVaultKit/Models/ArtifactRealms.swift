import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// A few reads the web does on the server, with no REST route to ask for:
// the addresses a person has claimed, the pages shared with them, their pins.
// The rows are the signed-in person's own, behind row-level security, so the
// app reads them from Supabase as itself (the mobile plan's "Direct Supabase"
// reads, like the invite code in `InviteRedeemer`). Every one of these degrades
// to "nothing to show", never to an error on the screen.

/// A small reader for the Supabase REST interface (PostgREST), authorised as the signed-in person.
public struct ArtifactTables: Sendable {
    private let config: SupabaseConfig
    private let tokens: TokenProvider
    private let transport: HTTPTransport

    public init(config: SupabaseConfig, tokens: TokenProvider, transport: HTTPTransport = URLSessionTransport()) {
        self.config = config
        self.tokens = tokens
        self.transport = transport
    }

    func request(_ table: String, query: [URLQueryItem]) async throws -> URLRequest {
        guard let token = try await tokens.accessToken() else { throw HVError.unauthorized }
        guard var components = URLComponents(url: config.url.appendingPathComponent("rest/v1/\(table)"), resolvingAgainstBaseURL: false) else {
            throw HVError.invalidRequest("Bad server address.")
        }
        components.queryItems = query
        guard let url = components.url else { throw HVError.invalidRequest("Bad request address.") }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// The rows of `table` matching `filters` (PostgREST operators, `user_id=eq.<id>`).
    public func rows<Row: Decodable & Sendable>(
        _ table: String,
        select: String,
        filters: [URLQueryItem] = [],
        order: String? = nil,
        limit: Int? = nil,
        as type: Row.Type = Row.self
    ) async throws -> [Row] {
        var query = [URLQueryItem(name: "select", value: select)] + filters
        if let order { query.append(URLQueryItem(name: "order", value: order)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        let request = try await request(table, query: query)

        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            throw HVError.transport(error.localizedDescription)
        }
        guard (200..<300).contains(response.status) else { throw HVError.api(HVClient.failure(from: response)) }
        do {
            return try HVCoding.decoder().decode([Row].self, from: response.data)
        } catch {
            throw HVError.decoding("\(error)")
        }
    }
}

// MARK: Addresses

/// An address a person has claimed (`name.vault.cool`). Every one serves every
/// page, so a link can live on whichever they choose.
public struct ArtifactRealm: Sendable, Codable, Identifiable, Hashable {
    public let subdomain: String
    public let baseDomain: String
    /// The slug of the page this address opens with, when it opens with one.
    public let defaultArtifactSlug: String?

    public var id: String { host }
    public var host: String { "\(subdomain).\(baseDomain)" }

    public init(subdomain: String, baseDomain: String, defaultArtifactSlug: String? = nil) {
        self.subdomain = subdomain
        self.baseDomain = baseDomain
        self.defaultArtifactSlug = defaultArtifactSlug
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        subdomain = try c.decode(String.self, forKey: .subdomain)
        baseDomain = try c.decodeIfPresent(String.self, forKey: .baseDomain) ?? "vault.cool"
        defaultArtifactSlug = try c.decodeIfPresent(String.self, forKey: .defaultArtifactSlug)
    }

    enum Keys: String, CodingKey { case subdomain, baseDomain, defaultArtifactSlug }
}

struct ArtifactProfileRow: Decodable, Sendable {
    let vanitySubdomain: String?
    let sidebarPins: [SidebarPin]?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        vanitySubdomain = try c.decodeIfPresent(String.self, forKey: .vanitySubdomain)
        sidebarPins = try? c.decodeIfPresent([SidebarPin].self, forKey: .sidebarPins)
    }

    enum Keys: String, CodingKey { case vanitySubdomain, sidebarPins }
}

public struct ArtifactRealmReader: Sendable {
    private let tables: ArtifactTables
    private let userId: String

    public init(tables: ArtifactTables, userId: String) {
        self.tables = tables
        self.userId = userId
    }

    /// The person's claimed addresses, oldest first (the first is the primary one).
    /// A profile from before claims were recorded may carry only a vanity name on vault.cool.
    public func realms() async throws -> [ArtifactRealm] {
        let owner = URLQueryItem(name: "user_id", value: "eq.\(userId)")
        var claims: [ArtifactRealm]
        do {
            claims = try await tables.rows("domain_claims", select: "subdomain,base_domain,default_artifact_slug", filters: [owner], order: "claimed_at.asc", limit: 20)
        } catch {
            // A database from before realm home pages has no such column: ask for the rest.
            claims = try await tables.rows("domain_claims", select: "subdomain,base_domain", filters: [owner], order: "claimed_at.asc", limit: 20)
        }
        if !claims.isEmpty { return claims }
        let profiles: [ArtifactProfileRow] = try await tables.rows(
            "profiles", select: "vanity_subdomain", filters: [URLQueryItem(name: "id", value: "eq.\(userId)")], limit: 1
        )
        if let name = profiles.first?.vanitySubdomain, !name.isEmpty {
            return [ArtifactRealm(subdomain: name, baseDomain: "vault.cool")]
        }
        return []
    }
}

// MARK: Links

public enum ArtifactLinks {
    /// The permanent link of a page or a group. A link lives on the app's own
    /// address or on any claimed one: every address serves every page.
    public static func url(slug: String, isGroup: Bool = false, host: String? = nil, appURL: URL) -> URL {
        let path = (isGroup ? "g/" : "a/") + (slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug)
        if let host, !host.isEmpty, let url = URL(string: "https://\(host)/\(path)") { return url }
        let base = appURL.absoluteString.hasSuffix("/") ? String(appURL.absoluteString.dropLast()) : appURL.absoluteString
        return URL(string: "\(base)/\(path)") ?? appURL
    }

    /// The first address in a list, which is the person's primary one.
    public static func primaryHost(_ realms: [ArtifactRealm]) -> String? { realms.first?.host }
}

// MARK: Pins

/// One shortcut in the side menu (`lib/sidebar-pins.ts`). The list is replaced
/// whole on every change, in display order.
public struct SidebarPin: Sendable, Codable, Hashable {
    public static let artifactKind = "artifact"
    /// The most pins the server keeps.
    public static let maxPins = 40

    public let kind: String
    public let ref: String

    public init(kind: String, ref: String) {
        self.kind = kind
        self.ref = ref
    }

    public static func artifact(_ slug: String) -> SidebarPin { SidebarPin(kind: artifactKind, ref: slug) }

    public var isArtifact: Bool { kind == Self.artifactKind }
}

public struct SidebarPins: Sendable, Equatable {
    public var pins: [SidebarPin]

    public init(pins: [SidebarPin] = []) {
        self.pins = pins
    }

    public func contains(artifact slug: String) -> Bool { pins.contains(.artifact(slug)) }

    /// The list with a page pinned (at the end) or unpinned. Other kinds of pin are left as they are.
    public func toggling(artifact slug: String) -> SidebarPins {
        var next = pins
        if let index = next.firstIndex(of: .artifact(slug)) {
            next.remove(at: index)
        } else {
            next.append(.artifact(slug))
        }
        return SidebarPins(pins: next)
    }

    public var artifactSlugs: [String] { pins.filter(\.isArtifact).map(\.ref) }

    /// Moves one pinned page among the pinned pages, as a list's drag does: `source` is its place
    /// among the artifact pins, `destination` the place it is dropped before (counted before it leaves).
    /// Pins of other kinds keep the places they have.
    public func movingArtifact(from source: Int, to destination: Int) -> SidebarPins {
        var slugs = artifactSlugs
        guard slugs.indices.contains(source), destination >= 0, destination <= slugs.count else { return self }
        let moved = slugs.remove(at: source)
        slugs.insert(moved, at: destination > source ? destination - 1 : destination)
        var next = slugs.makeIterator()
        return SidebarPins(pins: pins.map { $0.isArtifact ? (next.next().map(SidebarPin.artifact) ?? $0) : $0 })
    }
}

public struct SidebarPinsReader: Sendable {
    private let tables: ArtifactTables
    private let userId: String

    public init(tables: ArtifactTables, userId: String) {
        self.tables = tables
        self.userId = userId
    }

    /// The person's pins. There is no route that lists them: the profile row holds them.
    public func pins() async throws -> SidebarPins {
        let rows: [ArtifactProfileRow] = try await tables.rows(
            "profiles", select: "sidebar_pins", filters: [URLQueryItem(name: "id", value: "eq.\(userId)")], limit: 1
        )
        return SidebarPins(pins: rows.first?.sidebarPins ?? [])
    }
}

// MARK: Shared with you

/// A page another person shared with this one (`lib/sharing/shared-with-me.ts`).
public struct SharedWithYouItem: Sendable, Codable, Identifiable, Hashable {
    /// The share, which Leave names.
    public let shareId: String
    public let slug: String
    public let title: String
    public let type: String
    public let isJsx: Bool
    /// Who shared it, when the profile can be read; the web's service role reads it, a signed-in person's rights may not.
    public let owner: String?
    public let createdAt: Date?

    public var id: String { shareId }

    public init(shareId: String, slug: String, title: String, type: String, isJsx: Bool = false, owner: String? = nil, createdAt: Date? = nil) {
        self.shareId = shareId
        self.slug = slug
        self.title = title
        self.type = type
        self.isJsx = isJsx
        self.owner = owner
        self.createdAt = createdAt
    }

    public var isGroup: Bool { type == "group" }
    public var typeLabel: String { isJsx ? "react" : type }
}

struct SharedWithYouRow: Decodable, Sendable {
    struct Page: Decodable, Sendable {
        let slug: String
        let title: String?
        let type: String?
        let isJsx: Bool?
    }

    struct Owner: Decodable, Sendable {
        let email: String?
        let displayName: String?
    }

    let id: String
    let createdAt: Date?
    let artifact: Page?
    let owner: Owner?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        // PostgREST embeds a to-one row as an object, or as a one-item list for some relationships.
        artifact = SharedWithYouRow.one(Page.self, in: c, key: .artifact)
        owner = SharedWithYouRow.one(Owner.self, in: c, key: .owner)
    }

    enum Keys: String, CodingKey { case id, createdAt, artifact, owner }

    private static func one<T: Decodable>(_ type: T.Type, in c: KeyedDecodingContainer<Keys>, key: Keys) -> T? {
        if let value = try? c.decodeIfPresent(T.self, forKey: key) { return value }
        if let list = try? c.decodeIfPresent([T].self, forKey: key) { return list.first }
        return nil
    }
}

public struct SharedWithYouReader: Sendable {
    private let tables: ArtifactTables
    private let userId: String

    public init(tables: ArtifactTables, userId: String) {
        self.tables = tables
        self.userId = userId
    }

    /// Pages shared with this person, newest first. An empty list hides the section.
    public func items() async throws -> [SharedWithYouItem] {
        let owner = "owner:profiles!artifact_shares_owner_id_fkey(email,display_name)"
        let columns = "id,created_at,artifact:artifacts(slug,title,type,is_jsx),\(owner)"
        let filters = [URLQueryItem(name: "shared_with_id", value: "eq.\(userId)")]
        let rows: [SharedWithYouRow]
        do {
            rows = try await tables.rows("artifact_shares", select: columns, filters: filters, order: "created_at.desc", limit: 100)
        } catch {
            // Without the owner's name (the profile may not be readable): the pages are what matter.
            rows = try await tables.rows(
                "artifact_shares", select: "id,created_at,artifact:artifacts(slug,title,type,is_jsx)",
                filters: filters, order: "created_at.desc", limit: 100
            )
        }
        return rows.compactMap { row in
            guard let page = row.artifact else { return nil }
            let owner = row.owner?.displayName ?? row.owner?.email
            return SharedWithYouItem(
                shareId: row.id, slug: page.slug, title: page.title ?? "Untitled", type: page.type ?? "html",
                isJsx: page.isJsx ?? false, owner: (owner?.isEmpty ?? true) ? nil : owner, createdAt: row.createdAt
            )
        }
    }
}
