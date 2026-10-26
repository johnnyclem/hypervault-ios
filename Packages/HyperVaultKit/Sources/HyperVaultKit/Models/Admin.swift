import Foundation

// Admin: the owner's control room (invite codes, the waitlist, accounts). The
// wire is `app/api/admin/**`. Every route there is write-only: the web page
// reads its lists with the service-role key on the server, and the tables have
// no read policy for a signed-in person (invite_codes has none at all;
// waitlist, profiles and account_access are readable for your own row only),
// so the app has no way to list invites, the waitlist or accounts. What it can
// do is act on a row whose id it already holds: an invite it just minted, an
// account id copied from the web dashboard.

public enum AdminInviteStatus: String, Sendable, Equatable {
    case active, usedUp, disabled
}

/// An invite code row, as `POST /api/admin/invites` and `PATCH .../[id]` return it.
public struct AdminInvite: Sendable, Codable, Identifiable, Hashable {
    public let id: String
    public let code: String
    public var note: String?
    public var maxUses: Int
    public var useCount: Int
    public var disabled: Bool
    public var createdAt: Date?

    public init(id: String, code: String, note: String? = nil, maxUses: Int = 1, useCount: Int = 0, disabled: Bool = false, createdAt: Date? = nil) {
        self.id = id
        self.code = code
        self.note = note
        self.maxUses = maxUses
        self.useCount = useCount
        self.disabled = disabled
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        code = try c.decode(String.self, forKey: .code)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        maxUses = try c.decodeIfPresent(Int.self, forKey: .maxUses) ?? 1
        useCount = try c.decodeIfPresent(Int.self, forKey: .useCount) ?? 0
        disabled = try c.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    enum Keys: String, CodingKey { case id, code, note, maxUses, useCount, disabled, createdAt }

    public var remaining: Int { max(0, maxUses - useCount) }

    public var status: AdminInviteStatus {
        if disabled { return .disabled }
        return useCount >= maxUses ? .usedUp : .active
    }

    /// The link to hand someone: it opens the sign-in page with the code filled in
    /// (the same link the weekly star-invite email carries).
    public func shareURL(server: URL) -> URL {
        var components = URLComponents(url: server.appendingPathComponent("login"), resolvingAgainstBaseURL: false) ?? URLComponents()
        components.queryItems = [URLQueryItem(name: "invite", value: code)]
        return components.url ?? server
    }

    /// The route keeps 1 to 10,000 uses.
    public static let usesRange = 1...10_000

    public static func clampUses(_ value: Int) -> Int {
        min(max(value, usesRange.lowerBound), usesRange.upperBound)
    }
}

/// The `{ invite }` answer of a create or an update.
public struct AdminInviteEnvelope: Sendable, Decodable {
    public let invite: AdminInvite
}

/// The codes minted from this phone. The server cannot list them, so the app
/// keeps the ones it has seen, with the counts as of the last answer.
public struct AdminInviteBook: Sendable, Codable, Equatable {
    public private(set) var invites: [AdminInvite]

    public init(invites: [AdminInvite] = []) {
        self.invites = invites
    }

    /// Adds or replaces a row, newest first.
    public mutating func upsert(_ invite: AdminInvite) {
        if let index = invites.firstIndex(where: { $0.id == invite.id }) {
            invites[index] = invite
        } else {
            invites.insert(invite, at: 0)
        }
        invites.sort { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    public mutating func remove(id: String) {
        invites.removeAll { $0.id == id }
    }
}

public enum AdminPlan: String, Sendable, CaseIterable, Identifiable {
    case free, pro

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

/// One change to an account (`PATCH /api/admin/accounts/[id]`).
public enum AdminAccountChange: Sendable, Equatable {
    case plan(AdminPlan)
    case displayName(String)
    /// Lets the account in (and takes it off the waitlist).
    case approve
    /// Shuts the account out of the vault again.
    case revoke

    /// The body, with the route's own key names.
    public var body: JSONValue {
        switch self {
        case .plan(let plan): return .object(["plan": .string(plan.rawValue)])
        case .displayName(let name): return .object(["displayName": .string(String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)))])
        case .approve: return .object(["approved": .bool(true)])
        case .revoke: return .object(["approved": .bool(false)])
        }
    }
}

/// The `{ ok: true }` answer of an update or delete.
public struct AdminAck: Sendable, Decodable {
    public let ok: Bool?
}

/// Reads an account id someone pasted.
public enum AdminAccountID {
    /// A lowercase UUID, or nil. Quotes, spaces and a trailing comma (as copied
    /// from a table or JSON) are ignored.
    public static func parse(_ text: String) -> String? {
        let cleaned = text.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n\"',"))
        return UUID(uuidString: cleaned)?.uuidString.lowercased()
    }
}

// MARK: Is this person an admin?

/// There is no "am I an admin" read, and no GET route anywhere under
/// `app/api/admin`. Every admin route starts with `requireAdmin()`, which
/// answers 401 (not signed in), 403 (not an admin) or, for an admin, goes on to
/// read its body. So the probe asks the one route whose body check comes
/// before any database access, with a body that fails it: an admin gets a 400
/// ("Pass { disabled: boolean }."), anyone else a 403. Nothing is written.
public enum AdminProbe {
    public enum Verdict: Sendable, Equatable {
        case admin, notAdmin
        /// The answer says nothing either way (signed out of the web session, a server error).
        case unknown
    }

    /// An id no row has. The route never reaches the database with it.
    public static let probeID = "00000000-0000-0000-0000-000000000000"

    /// What each answer means.
    public static func verdict(status: Int?) -> Verdict {
        guard let status else { return .unknown }
        switch status {
        case 200..<300, 400, 404, 503:
            // 400: past the guard, refusing the empty body. 404 and 2xx: past it
            // too, should the route one day check the id first. 503: the guard
            // checks the email before it looks for the service key.
            return .admin
        case 403:
            return .notAdmin
        default:
            return .unknown
        }
    }

    /// How long an answer is trusted before it is asked again.
    public static let freshFor: TimeInterval = 6 * 3600
}

// MARK: Endpoints

extension Endpoint where Response == NoContent {
    /// The admin probe: a PATCH with an empty body that every admin route's
    /// body check refuses. See `AdminProbe`. Never retried.
    public static var adminProbe: Endpoint<NoContent> {
        Endpoint(.patch, "/api/admin/invites/\(AdminProbe.probeID)", body: .jsonValue(.object([:])), timeout: 15)
    }
}

extension Endpoint where Response == AdminInviteEnvelope {
    /// Mints a code. The route reads `maxUses` (camelCase) and `note`.
    public static func createInvite(maxUses: Int, note: String?) -> Endpoint<AdminInviteEnvelope> {
        var object: [String: JSONValue] = ["maxUses": .int(AdminInvite.clampUses(maxUses))]
        if let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty { object["note"] = .string(String(note.prefix(200))) }
        return Endpoint(.post, "/api/admin/invites", body: .jsonValue(.object(object)))
    }

    /// Turns a code off or on. The answer is the whole row, with its current uses.
    public static func setInvite(id: String, disabled: Bool) -> Endpoint<AdminInviteEnvelope> {
        Endpoint(.patch, "/api/admin/invites/\(id)", body: .jsonValue(.object(["disabled": .bool(disabled)])))
    }
}

extension Endpoint where Response == AdminAck {
    public static func deleteInvite(id: String) -> Endpoint<AdminAck> {
        Endpoint(.delete, "/api/admin/invites/\(id)")
    }

    public static func changeAccount(id: String, _ change: AdminAccountChange) -> Endpoint<AdminAck> {
        Endpoint(.patch, "/api/admin/accounts/\(id)", body: .jsonValue(change.body))
    }

    /// Deletes the sign-in and, with it, everything the account saved.
    public static func deleteAccount(id: String) -> Endpoint<AdminAck> {
        Endpoint(.delete, "/api/admin/accounts/\(id)")
    }

    /// Drops an entry from the waitlist without approving it.
    public static func dropFromWaitlist(id: String) -> Endpoint<AdminAck> {
        Endpoint(.delete, "/api/admin/waitlist/\(id)")
    }
}
