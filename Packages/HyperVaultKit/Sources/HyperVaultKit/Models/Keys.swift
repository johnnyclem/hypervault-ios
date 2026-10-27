import Foundation

// Agent keys: the `hv_` keys a person hands to an AI so it can use their vault.
// The web app's source is app/api/keys/route.ts (mint, revoke, change mail
// scopes), lib/api-keys.ts and lib/agent-setup.ts (the setup challenge).
//
// No route lists keys: the web page reads the `api_keys` table on the server.
// RLS and the column grants of migrations 0032 and 0047 let a signed-in
// session read its own rows through PostgREST (`AccountRest`), which is what
// `AgentKeyDirectory` does. A raw key exists in exactly one response, the
// mint, and `NewAgentKey` is written so that nothing prints it by accident.

// MARK: Scopes

/// What a key may do with mail. A new key holds the first only.
public enum AgentKeyScope {
    public static let mailRead = "mail:read"
    public static let mailSend = "mail:send"

    /// The scopes the "Can send mail" switch writes.
    public static func scopes(canSendMail: Bool) -> [String] {
        canSendMail ? [mailRead, mailSend] : [mailRead]
    }
}

// MARK: Rows

/// One of the person's keys, as the account page lists it. Never the key itself:
/// the prefix (`hv_` and eight characters) is all of it the server keeps readable.
public struct AgentKey: Sendable, Codable, Identifiable, Hashable {
    public let id: String
    public let keyPrefix: String
    /// What the key is called. "default" for a key made without a name; "Paired: <label>" for one made by pairing.
    public let name: String
    public let createdAt: Date?
    public let lastUsedAt: Date?
    /// Nil when the database predates migration 0047 (no mail controls to offer).
    public let scopes: [String]?
    public let mailClaimId: String?
    /// The claim the key was pinned to has been released: it reads but cannot send until pinned again.
    public let mailPinCleared: Bool

    public init(
        id: String, keyPrefix: String, name: String = "default", createdAt: Date? = nil, lastUsedAt: Date? = nil,
        scopes: [String]? = nil, mailClaimId: String? = nil, mailPinCleared: Bool = false
    ) {
        self.id = id
        self.keyPrefix = keyPrefix
        self.name = name
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.scopes = scopes
        self.mailClaimId = mailClaimId
        self.mailPinCleared = mailPinCleared
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        keyPrefix = try c.decodeIfPresent(String.self, forKey: .keyPrefix) ?? "hv_"
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "default"
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        scopes = try c.decodeIfPresent([String].self, forKey: .scopes)
        mailClaimId = try c.decodeIfPresent(String.self, forKey: .mailClaimId)
        mailPinCleared = try c.decodeIfPresent(Bool.self, forKey: .mailPinCleared) ?? false
    }

    enum Keys: String, CodingKey { case id, keyPrefix, name, createdAt, lastUsedAt, scopes, mailClaimId, mailPinCleared }

    /// The name to show, or nil for the unnamed "default" key.
    public var displayName: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "default" ? nil : trimmed
    }

    /// `hv_abcd1234…`, how the web card shows the key.
    public var prefixLabel: String { "\(keyPrefix)…" }

    /// Made by approving a pairing ("Paired: <label>").
    public var isPaired: Bool { name.hasPrefix("Paired: ") }

    public var canSendMail: Bool { scopes?.contains(AgentKeyScope.mailSend) ?? false }

    /// The mail controls are offered only when the database could say what the key may do.
    public var hasMailControls: Bool { scopes != nil }

    /// A copy with the mail settings the server answered after a change.
    public func with(scopes: [String]?, mailClaimId: String?, mailPinCleared: Bool) -> AgentKey {
        AgentKey(
            id: id, keyPrefix: keyPrefix, name: name, createdAt: createdAt, lastUsedAt: lastUsedAt,
            scopes: scopes, mailClaimId: mailClaimId, mailPinCleared: mailPinCleared
        )
    }
}

// MARK: Mint, revoke, change

/// The setup challenge minted with a key: a private page the agent rewrites to prove the link works.
public struct SetupChallengeRef: Sendable, Codable, Equatable, Hashable {
    public let slug: String
    public let url: String?

    public init(slug: String, url: String? = nil) {
        self.slug = slug
        self.url = url
    }
}

/// `POST /api/keys`: the one response that ever holds a raw key. Shown once,
/// copied with an expiring pasteboard item, and dropped when the sheet closes.
/// Printing it (`print`, string interpolation, a debugger) shows only the prefix.
public struct NewAgentKey: Sendable, Decodable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let key: String
    public let prefix: String
    /// Nil when the server could not create the challenge page; the key still works.
    public let challenge: SetupChallengeRef?
    public let message: String?

    public init(key: String, prefix: String, challenge: SetupChallengeRef? = nil, message: String? = nil) {
        self.key = key
        self.prefix = prefix
        self.challenge = challenge
        self.message = message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        key = try c.decode(String.self, forKey: .key)
        prefix = try c.decodeIfPresent(String.self, forKey: .prefix) ?? String(key.prefix(11))
        challenge = try c.decodeIfPresent(SetupChallengeRef.self, forKey: .challenge)
        message = try c.decodeIfPresent(String.self, forKey: .message)
    }

    enum Keys: String, CodingKey { case key, prefix, challenge, message }

    public var description: String { "NewAgentKey(prefix: \(prefix)…)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["prefix": prefix], displayStyle: .struct) }
}

/// `DELETE /api/keys` answers `{ revoked: id }`.
public struct RevokedAgentKey: Sendable, Decodable, Equatable {
    public let revoked: String
}

/// `PATCH /api/keys` answers `{ key: { id, scopes, mail_claim_id, mail_pin_cleared } }`.
public struct AgentKeyUpdate: Sendable, Decodable, Equatable {
    public struct Key: Sendable, Decodable, Equatable {
        public let id: String
        public let scopes: [String]?
        public let mailClaimId: String?
        public let mailPinCleared: Bool?
    }

    public let key: Key
}

extension Endpoint where Response == NewAgentKey {
    /// Mints a key. `name` is what the keys card calls it (the server reduces it to
    /// plain text of at most 60 characters); a blank name is no name. `canSendMail`
    /// asks for the "Can send mail" scope, which the server otherwise leaves off.
    public static func createAgentKey(name: String? = nil, canSendMail: Bool = false) -> Endpoint<NewAgentKey> {
        var body: [String: JSONValue] = [:]
        if let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            body["name"] = .string(String(trimmed.prefix(AgentKeyRules.nameMaxLength)))
        }
        if canSendMail {
            body["scopes"] = .array(AgentKeyScope.scopes(canSendMail: true).map(JSONValue.string))
        }
        return Endpoint(.post, "/api/keys", body: .jsonValue(.object(body)))
    }
}

extension Endpoint where Response == RevokedAgentKey {
    /// Revokes a key at once; the row is kept for audit.
    public static func revokeAgentKey(id: String) -> Endpoint<RevokedAgentKey> {
        Endpoint(.delete, "/api/keys", body: .jsonValue(["id": .string(id)]))
    }
}

extension Endpoint where Response == AgentKeyUpdate {
    /// Changes what a key may do with mail (the "Can send mail" switch).
    public static func setAgentKeyMail(id: String, canSendMail: Bool) -> Endpoint<AgentKeyUpdate> {
        let scopes = AgentKeyScope.scopes(canSendMail: canSendMail).map(JSONValue.string)
        return Endpoint(.patch, "/api/keys", body: .jsonValue(["id": .string(id), "scopes": .array(scopes)]))
    }
}

public enum AgentKeyRules {
    /// A key's name is reduced to plain text of at most this many characters (lib/pairing/codes.ts).
    public static let nameMaxLength = 60

    /// Every key is `hv_` and 32 URL-safe characters (35 in all).
    public static func looksLikeKey(_ text: String) -> Bool {
        guard text.hasPrefix("hv_"), text.utf8.count == 35 else { return false }
        return text.dropFirst(3).unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 0x30 && scalar.value <= 0x39) || (scalar.value >= 0x41 && scalar.value <= 0x5A)
                || (scalar.value >= 0x61 && scalar.value <= 0x7A) || scalar == "_" || scalar == "-"
        }
    }
}

// MARK: Setup challenge pages

/// Which private page is each key's setup challenge. Every key is minted with one: a page its agent is asked to
/// rewrite, tagged with the key's prefix. Only the slug is read, so the app can open the page. Whether the agent
/// finished is not worked out here: no route reports the server's check, and a second copy of it on the device
/// would be untested.
public enum SetupChallengePages {
    /// The tag that marks an artifact as a key's setup challenge, beside the key prefix.
    public static let tag = "agent-setup-challenge"

    public struct Page: Sendable, Decodable, Equatable {
        public let slug: String
        public let tags: [String]

        public init(slug: String, tags: [String]) {
            self.slug = slug
            self.tags = tags
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            slug = try c.decode(String.self, forKey: .slug)
            tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        }

        enum Keys: String, CodingKey { case slug, tags }
    }

    /// The slug of each key's challenge page by key id, matched by the prefix tag with the newest page winning.
    /// `pages` must be newest first. A key with no page (minted before challenges existed) has no entry.
    public static func slugs(keys: [AgentKey], pages: [Page]) -> [String: String] {
        var byPrefix: [String: String] = [:]
        for page in pages {
            for tag in page.tags where tag != Self.tag && byPrefix[tag] == nil {
                byPrefix[tag] = page.slug
            }
        }
        var out: [String: String] = [:]
        for key in keys {
            if let slug = byPrefix[key.keyPrefix] { out[key.id] = slug }
        }
        return out
    }
}

// MARK: Reading the lists

/// What the keys screen shows: the keys and, where the challenge pages could be read, the slug of each key's page.
public struct AgentKeysSnapshot: Sendable, Codable, Equatable {
    public var keys: [AgentKey]
    /// Key id to the slug of its setup challenge page.
    public var challengeSlugs: [String: String]

    public init(keys: [AgentKey] = [], challengeSlugs: [String: String] = [:]) {
        self.keys = keys
        self.challengeSlugs = challengeSlugs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        keys = try c.decode([AgentKey].self, forKey: .keys)
        // A copy saved by an older version has no slugs.
        challengeSlugs = try c.decodeIfPresent([String: String].self, forKey: .challengeSlugs) ?? [:]
    }

    enum Keys: String, CodingKey { case keys, challengeSlugs }
}

/// Reads the person's keys and their setup challenge pages through PostgREST, the way the web page does on the server.
public enum AgentKeyDirectory {
    static let baseColumns = "id,key_prefix,name,created_at,last_used_at"
    static let mailColumns = "scopes,mail_claim_id,mail_pin_cleared"

    /// The live keys, newest first. A database without migration 0047 has no mail columns:
    /// ask again without them and the keys simply carry no mail controls.
    public static func keys(rest: AccountRest, userID: String) async throws -> [AgentKey] {
        func query(_ columns: String) -> [URLQueryItem] {
            [
                URLQueryItem(name: "select", value: columns),
                URLQueryItem(name: "user_id", value: "eq.\(userID)"),
                URLQueryItem(name: "revoked", value: "eq.false"),
                URLQueryItem(name: "order", value: "created_at.desc"),
            ]
        }
        do {
            return try await rest.rows(AgentKey.self, from: "api_keys", query: query("\(baseColumns),\(mailColumns)"))
        } catch where AccountRest.isMissingColumn(error) {
            return try await rest.rows(AgentKey.self, from: "api_keys", query: query(baseColumns))
        }
    }

    /// The slug of each key's setup challenge page, by key id. Best effort: when the pages cannot be read the
    /// result is empty and the screen simply has no page to open. Reads the slug and tags only, never a page's content.
    public static func challengeSlugs(rest: AccountRest, userID: String, keys: [AgentKey]) async -> [String: String] {
        guard !keys.isEmpty else { return [:] }
        guard let pages: [SetupChallengePages.Page] = try? await rest.rows(
            from: "artifacts",
            query: [
                URLQueryItem(name: "select", value: "slug,tags"),
                URLQueryItem(name: "user_id", value: "eq.\(userID)"),
                URLQueryItem(name: "tags", value: "cs.{\(SetupChallengePages.tag)}"),
                URLQueryItem(name: "order", value: "created_at.desc"),
                URLQueryItem(name: "limit", value: "200"),
            ]
        ) else { return [:] }
        return SetupChallengePages.slugs(keys: keys, pages: pages)
    }

    public static func snapshot(rest: AccountRest, userID: String) async throws -> AgentKeysSnapshot {
        let keys = try await keys(rest: rest, userID: userID)
        let slugs = await challengeSlugs(rest: rest, userID: userID, keys: keys)
        return AgentKeysSnapshot(keys: keys, challengeSlugs: slugs)
    }
}

// MARK: Onboarding

/// `PATCH /api/onboarding` answers `{ persisted, onboarding? }`.
public struct OnboardingRecord: Sendable, Decodable, Equatable {
    public let persisted: Bool?
}

extension Endpoint where Response == OnboardingRecord {
    /// Records a first-run event on the profile: the connect card was dismissed, or an agent connected.
    /// Each flag stamps its time once. Best effort: callers ignore failure.
    public static func recordOnboarding(connectDismissed: Bool = false, connectCompleted: Bool = false) -> Endpoint<OnboardingRecord> {
        var body: [String: JSONValue] = [:]
        if connectDismissed { body["connect_dismissed"] = true }
        if connectCompleted { body["connect_completed"] = true }
        return Endpoint(.patch, "/api/onboarding", body: .jsonValue(.object(body)))
    }
}

// MARK: Words

/// Lines the key and vault lists share with the web's lists (lib/copy.ts).
public enum AccountWords {
    public static let neverUsed = "Never used"

    public static func lastUsed(_ ago: String) -> String { "Last used \(ago)" }

    public static let mailSendLabel = "Can send mail"

    /// How long ago something was last used: the biggest unit that fits, rounded down. Anything under a
    /// minute, in the future (a clock that disagrees with the server's) or not a number is "Just now".
    public static func agoLine(seconds: TimeInterval) -> String {
        guard seconds >= 60 else { return "Just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) hr ago" }
        let days = hours / 24
        if days < 2 { return "Yesterday" }
        if days < 30 { return "\(days) days ago" }
        let months = days / 30
        if days < 365 { return months == 1 ? "1 month ago" : "\(months) months ago" }
        let years = days / 365
        return years == 1 ? "1 year ago" : "\(years) years ago"
    }

    /// "Last used 3 days ago", or "Never used" for a key or secret nothing has read.
    public static func lastUsedLine(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return neverUsed }
        let ago = agoLine(seconds: now.timeIntervalSince(date))
        return lastUsed(ago.prefix(1).lowercased() + ago.dropFirst())
    }
}
