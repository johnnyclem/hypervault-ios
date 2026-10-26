import Foundation

// Who can open a page: people it is shared with, and passwords. The wire is
// `app/api/shares/route.ts` and `app/api/artifacts/[slug]/passwords`; the
// words are `lib/copy.ts` (the share sheet's own).

// MARK: People

/// What one person can do with something shared with them (`lib/sharing/roles.ts`).
public enum ArtifactShareRole: String, Sendable, Codable, CaseIterable, Hashable {
    case view, use, edit

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // A role this build does not know is never read as more than a view.
        self = ArtifactShareRole(rawValue: raw) ?? .view
    }

    public var title: String {
        switch self {
        case .view: return "View"
        case .use: return "Use"
        case .edit: return "Edit"
        }
    }

    /// The PRD's sentence for the chosen role.
    public var line: String {
        switch self {
        case .view: return "They can open it."
        case .use: return "They can add and change the contents, not the sharing."
        case .edit: return "They can change how it works, including who is on it."
        }
    }
}

/// One person on `GET /api/shares?artifact=`. `id` is the share, which Remove names.
public struct ArtifactSharePerson: Sendable, Codable, Identifiable, Hashable {
    public let id: String
    public let email: String?
    public let displayName: String?
    public let role: ArtifactShareRole
    public let createdAt: Date?

    public init(id: String, email: String?, displayName: String? = nil, role: ArtifactShareRole = .view, createdAt: Date? = nil) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.role = role
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        role = try c.decodeIfPresent(ArtifactShareRole.self, forKey: .role) ?? .view
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    enum Keys: String, CodingKey { case id, email, displayName, role, createdAt }

    /// Their email, else their name, else "Someone".
    public var name: String {
        if let email, !email.isEmpty { return email }
        if let displayName, !displayName.isEmpty { return displayName }
        return "Someone"
    }
}

/// `GET /api/shares?artifact=`: who has the page, what it may be shared as, and
/// whether `use` and `edit` do anything on this deployment.
public struct ArtifactShareList: Sendable, Decodable, Equatable {
    public let people: [ArtifactSharePerson]
    /// What the page can be shared as, least first (the route's `roles`).
    public let roles: [ArtifactShareRole]
    /// False while `HYPERVAULT_SHARE_ROLES` is off: every share acts as a view.
    public let enforced: Bool

    public init(people: [ArtifactSharePerson], roles: [ArtifactShareRole], enforced: Bool) {
        self.people = people
        self.roles = roles
        self.enforced = enforced
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        people = try c.decodeIfPresent([ArtifactSharePerson].self, forKey: .shares) ?? []
        let words = try c.decodeIfPresent([String].self, forKey: .roles) ?? []
        roles = words.compactMap(ArtifactShareRole.init(rawValue:))
        enforced = try c.decodeIfPresent(Bool.self, forKey: .rolesEnforced) ?? false
    }

    enum Keys: String, CodingKey { case shares, roles, rolesEnforced }

    /// The roles the sheet offers: the ones the page can have, and of those only
    /// `view` while the others do nothing (`sheetRoles`).
    public var offeredRoles: [ArtifactShareRole] {
        enforced ? roles : roles.filter { $0 == .view }
    }

    /// What a person's share is worth today, not what is stored (`effectiveRole`).
    public func effectiveRole(of person: ArtifactSharePerson) -> ArtifactShareRole {
        enforced && roles.contains(person.role) ? person.role : .view
    }
}

/// What `POST /api/shares` answers.
public struct ArtifactShareAdded: Sendable, Decodable {
    public let role: ArtifactShareRole
    public let message: String

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        role = try c.decodeIfPresent(ArtifactShareRole.self, forKey: .role) ?? .view
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
    }

    enum Keys: String, CodingKey { case role, message }
}

public enum ArtifactShareEmail {
    /// The route's own check: something@something.something, no spaces.
    public static func isValid(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.contains(where: { $0.isWhitespace }), let at = value.firstIndex(of: "@"), at != value.startIndex else { return false }
        let domain = value[value.index(after: at)...]
        guard !domain.contains("@"), let dot = domain.lastIndex(of: "."), dot != domain.startIndex else { return false }
        return domain.index(after: dot) != domain.endIndex
    }
}

// MARK: Passwords

/// One password on a password-gated page (never the password itself).
public struct ArtifactPassword: Sendable, Codable, Identifiable, Hashable {
    public let id: String
    public let label: String?
    public let maxUses: Int?
    public let useCount: Int
    public let disabled: Bool
    public let createdAt: Date?

    public init(id: String, label: String? = nil, maxUses: Int? = nil, useCount: Int = 0, disabled: Bool = false, createdAt: Date? = nil) {
        self.id = id
        self.label = label
        self.maxUses = maxUses
        self.useCount = useCount
        self.disabled = disabled
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        maxUses = try c.decodeIfPresent(Int.self, forKey: .maxUses)
        useCount = try c.decodeIfPresent(Int.self, forKey: .useCount) ?? 0
        disabled = try c.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    enum Keys: String, CodingKey { case id, label, maxUses, useCount, disabled, createdAt }

    public var displayLabel: String {
        if let label, !label.isEmpty { return label }
        return "Untitled"
    }

    /// "3 visits" or "3 visits / 5 max".
    public var usageLine: String {
        let visits = useCount == 1 ? "1 visit" : "\(useCount) visits"
        if let maxUses { return "\(visits) / \(maxUses) max" }
        return visits
    }

    public var isUsedUp: Bool {
        if let maxUses { return useCount >= maxUses }
        return false
    }
}

public struct ArtifactPasswordVisit: Sendable, Codable, Identifiable, Hashable {
    public let id: String
    public let artifactPasswordId: String?
    public let label: String?
    public let createdAt: Date?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        artifactPasswordId = try c.decodeIfPresent(String.self, forKey: .artifactPasswordId)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    enum Keys: String, CodingKey { case id, artifactPasswordId, label, createdAt }
}

/// `GET /api/artifacts/[slug]/passwords`: the passwords and a short feed of who used which.
public struct ArtifactPasswordList: Sendable, Decodable, Equatable {
    public let passwords: [ArtifactPassword]
    public let recentVisits: [ArtifactPasswordVisit]

    public init(passwords: [ArtifactPassword] = [], recentVisits: [ArtifactPasswordVisit] = []) {
        self.passwords = passwords
        self.recentVisits = recentVisits
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        passwords = try c.decodeIfPresent([ArtifactPassword].self, forKey: .passwords) ?? []
        recentVisits = try c.decodeIfPresent([ArtifactPasswordVisit].self, forKey: .recentVisits) ?? []
    }

    enum Keys: String, CodingKey { case passwords, recentVisits }
}

/// What minting a password answers. `plaintext` is shown once and never kept.
public struct ArtifactPasswordMinted: Sendable, Decodable {
    public let password: ArtifactPassword
    public let plaintext: String
    public let message: String

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        password = try c.decode(ArtifactPassword.self, forKey: .password)
        plaintext = try c.decode(String.self, forKey: .plaintext)
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? "Copy this password now. It won't be shown again."
    }

    enum Keys: String, CodingKey { case password, plaintext, message }
}

struct ArtifactPasswordEnvelope: Sendable, Decodable {
    let password: ArtifactPassword
}

public enum ArtifactPasswordRules {
    /// An artifact can have at most this many passwords.
    public static let maxPasswords = 20
    public static let minimumLength = 4
}
