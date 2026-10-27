import Foundation

// The saved-secrets vault: logins, cards, contact info and keys an agent may be
// allowed to read. The web app's source is app/api/secrets/** (list, create,
// edit, delete, grants), lib/secrets/items.ts (the typed entries, ported below
// as `VaultItems`) and components/vault-pane/*.
//
// A value goes in and never comes back. The list carries metadata and a
// `hint` the server derives ("Visa •••• 4242", a username) and nothing else, so
// nothing in this file can hold a stored value; the one place a value exists is
// the draft a person is typing, and it is written to the request and dropped.

// MARK: Kinds

/// Every kind a secret can have.
public enum SecretKind: String, Sendable, Codable, CaseIterable, Hashable {
    case opaque, header
    case oauthGrant = "oauth_grant"
    case login, card, contact

    /// An unknown kind from a newer server reads as a key, as the web does.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SecretKind(rawValue: raw) ?? .opaque
    }

    /// What the list and the detail sheet call it.
    public var label: String {
        switch self {
        case .opaque: return "Key"
        case .header: return "MCP header"
        case .oauthGrant: return "OAuth grant"
        case .login: return "Login"
        case .card: return "Card"
        case .contact: return "Contact info"
        }
    }

    public var vaultItemKind: VaultItemKind? {
        switch self {
        case .login: return .login
        case .card: return .card
        case .contact: return .contact
        case .opaque, .header, .oauthGrant: return nil
        }
    }

    public var category: VaultCategory {
        switch self {
        case .login: return .logins
        case .card: return .cards
        case .contact: return .contact
        case .opaque, .header, .oauthGrant: return .keys
        }
    }
}

/// The three kinds whose value is a small JSON object rather than an opaque string.
public enum VaultItemKind: String, Sendable, CaseIterable, Hashable {
    case login, card, contact

    public var secretKind: SecretKind {
        switch self {
        case .login: return .login
        case .card: return .card
        case .contact: return .contact
        }
    }

    /// The fields an entry may carry, in the order the canonical JSON writes them.
    /// Any other key is dropped, so a value cannot carry extra data past validation.
    public var fields: [String] {
        switch self {
        case .login: return ["url", "username", "password", "notes"]
        case .card: return ["cardholder", "number", "expMonth", "expYear", "cvc"]
        case .contact: return ["fullName", "email", "phone", "address"]
        }
    }

    /// Why a value is not an object of the right kind at all. It names the fields, because API callers read it too.
    public var shapeError: String {
        switch self {
        case .login: return "A login must be a JSON object with a username and password."
        case .card: return "A card must be a JSON object with a number, expMonth and expYear."
        case .contact: return "Contact info must be a JSON object with a fullName, email, phone or address."
        }
    }
}

/// The filters the vault list offers, in order. Every kind is in exactly one.
public enum VaultCategory: String, Sendable, CaseIterable, Identifiable, Hashable {
    case logins, cards, contact, keys

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .logins: return "Logins"
        case .cards: return "Cards"
        case .contact: return "Contact info"
        case .keys: return "Keys"
        }
    }

    public var kinds: [SecretKind] {
        switch self {
        case .logins: return [.login]
        case .cards: return [.card]
        case .contact: return [.contact]
        case .keys: return [.opaque, .header, .oauthGrant]
        }
    }

    /// One helpful line for a filter with nothing in it (components/vault-pane/vault-pane.tsx).
    public var emptyLine: String {
        switch self {
        case .logins: return "No logins yet. Save one, then allow the agents that should sign in with it."
        case .cards: return "No cards yet. The list only ever shows a card's brand and last four digits."
        case .contact: return "No contact info yet. Save a name, email, phone or address once for every agent you allow."
        case .keys: return "No keys yet. Save an API token or other secret here, and the agents you allow read it by name."
        }
    }
}

// MARK: Rows

/// A secret as the list shows it: metadata and the masked hint, never the value.
public struct VaultSecret: Sendable, Codable, Identifiable, Hashable {
    public let id: String
    /// The title in the list and the handle an agent fetches it by.
    public let name: String
    public let kind: SecretKind
    public let description: String?
    /// The masked subtitle of a login, card or contact; nil for a key, and for every row on a database without migration 0055.
    public let hint: String?
    public let createdAt: Date?
    public let updatedAt: Date?
    /// When an agent last read it. Only an agent's read counts.
    public let lastAccessedAt: Date?

    public init(
        id: String, name: String, kind: SecretKind, description: String? = nil, hint: String? = nil,
        createdAt: Date? = nil, updatedAt: Date? = nil, lastAccessedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.description = description
        self.hint = hint
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastAccessedAt = lastAccessedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decodeIfPresent(SecretKind.self, forKey: .kind) ?? .opaque
        description = try c.decodeIfPresent(String.self, forKey: .description)
        hint = try c.decodeIfPresent(String.self, forKey: .hint)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        lastAccessedAt = try c.decodeIfPresent(Date.self, forKey: .lastAccessedAt)
    }

    enum Keys: String, CodingKey { case id, name, kind, description, hint, createdAt, updatedAt, lastAccessedAt }

    /// What the row's second line says: the hint when there is one, else the kind.
    public var subtitle: String { hint ?? kind.label }

    /// The brand a card's hint names, for the row's tile.
    public var cardBrand: VaultItems.CardBrand? {
        kind.category == .cards ? VaultItems.cardBrand(fromHint: hint) : nil
    }

    /// The first letter or digit of a login's name ("www.github.com" is G). Logins get a monogram, not a favicon:
    /// fetching one would tell a third party which sites are in the vault.
    public var monogram: String {
        let trimmed = name.lowercased().hasPrefix("www.") ? String(name.dropFirst(4)) : name
        guard let first = trimmed.first(where: { $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return "?" }
        return String(first).uppercased()
    }
}

public struct VaultSecretList: Sendable, Decodable, Equatable {
    public let secrets: [VaultSecret]
}

public struct VaultSecretResponse: Sendable, Decodable, Equatable {
    public let secret: VaultSecret
}

/// An agent key allowed to read a secret (`secret_grants`).
public struct SecretGrant: Sendable, Decodable, Equatable, Identifiable, Hashable {
    public let id: String
    public let apiKeyId: String
    public let createdAt: Date?

    public init(id: String, apiKeyId: String, createdAt: Date? = nil) {
        self.id = id
        self.apiKeyId = apiKeyId
        self.createdAt = createdAt
    }
}

public struct SecretGrantList: Sendable, Decodable, Equatable {
    public let grants: [SecretGrant]
}

public struct SecretGrantResponse: Sendable, Decodable, Equatable {
    public let grant: SecretGrant

    public init(grant: SecretGrant) {
        self.grant = grant
    }
}

// MARK: Endpoints

extension Endpoint where Response == VaultSecretList {
    /// `GET /api/secrets`: the person's secrets, oldest first, metadata only. Human-authed.
    public static var vaultSecrets: Endpoint<VaultSecretList> {
        Endpoint(.get, "/api/secrets")
    }
}

extension Endpoint where Response == VaultSecretResponse {
    /// `POST /api/secrets`. For a login, card or contact `value` is the canonical JSON of the entry
    /// (`VaultItems.serialize`); the server checks it again and derives the hint. A 409 is a taken name.
    public static func createVaultSecret(name: String, kind: SecretKind, value: String, description: String? = nil) -> Endpoint<VaultSecretResponse> {
        var body: [String: JSONValue] = ["name": .string(name), "value": .string(value), "kind": .string(kind.rawValue)]
        if let description, !description.isEmpty { body["description"] = .string(description) }
        return Endpoint(.post, "/api/secrets", body: .jsonValue(.object(body)))
    }

    /// `PATCH /api/secrets/[name]`: rename, change the description, or replace the value. Fields left nil
    /// are left alone; an empty description clears it. A new value is checked against the secret's kind.
    public static func updateVaultSecret(
        name: String, newName: String? = nil, description: String? = nil, value: String? = nil
    ) -> Endpoint<VaultSecretResponse> {
        var body: [String: JSONValue] = [:]
        if let newName { body["new_name"] = .string(newName) }
        if let description { body["description"] = .string(description) }
        if let value { body["value"] = .string(value) }
        return Endpoint(.patch, "/api/secrets/\(name)", body: .jsonValue(.object(body)))
    }
}

extension Endpoint where Response == NoContent {
    /// `DELETE /api/secrets/[name]`: cuts off every agent at once.
    public static func deleteVaultSecret(name: String) -> Endpoint<NoContent> {
        Endpoint(.delete, "/api/secrets/\(name)")
    }

    /// `DELETE /api/secrets/[name]/grants`: stops one key reading the secret. Not idempotent, and so never
    /// retried: a revoke with no matching grant answers 404 "No such grant.", so a repeat that already went
    /// through would look like a failure (handoff 5.10). `HVClient.setSecretGrant` is how a switch calls it.
    public static func revokeSecretGrant(name: String, keyID: String) -> Endpoint<NoContent> {
        Endpoint(.delete, "/api/secrets/\(name)/grants", body: .jsonValue(["api_key_id": .string(keyID)]))
    }
}

extension Endpoint where Response == SecretGrantList {
    /// `GET /api/secrets/[name]/grants`: which keys may read it.
    public static func secretGrants(name: String) -> Endpoint<SecretGrantList> {
        Endpoint(.get, "/api/secrets/\(name)/grants")
    }
}

extension Endpoint where Response == SecretGrantResponse {
    /// `POST /api/secrets/[name]/grants`: lets one of the person's keys read the secret. An upsert, so it is safe
    /// to repeat and is retried on a busy server (handoff 5.10). The handoff does not document the answer's
    /// shape, so any 2xx is a success: a body that is not `{ grant: { id, api_key_id, created_at } }` gives a grant
    /// with an empty `id` and the `keyID` that was asked for.
    public static func grantSecret(name: String, keyID: String) -> Endpoint<SecretGrantResponse> {
        Endpoint(
            method: .post, path: "/api/secrets/\(name)/grants", body: .jsonValue(["api_key_id": .string(keyID)]),
            idempotent: true
        ) { response, keys in
            if let granted = try? HVCoding.decoder(keys).decode(SecretGrantResponse.self, from: response.data) { return granted }
            return SecretGrantResponse(grant: SecretGrant(id: "", apiKeyId: keyID))
        }
    }
}

// MARK: Typed entries

/// The typed entries (lib/secrets/items.ts), ported as pure functions: what a login, card or contact
/// may hold, how it is validated, the canonical JSON it is stored as and the hint derived from it. The
/// form validates with this so Save stays off until the server would accept the entry; the server checks
/// again anyway. An entry is `[String: String]`, keyed by `VaultItemKind.fields`.
public enum VaultItems {
    public typealias Fields = [String: String]

    // MARK: Names

    public static let nameHint = "1–100 chars: letters, digits, dot, dash, or underscore."

    /// A secret's name is both its title and the handle an agent fetches it by, so it has no spaces.
    public static func isValidName(_ name: String) -> Bool {
        let count = name.unicodeScalars.count
        guard count >= 1, count <= 100 else { return false }
        return name.unicodeScalars.allSatisfy(isNameScalar)
    }

    private static func isNameScalar(_ scalar: Unicode.Scalar) -> Bool {
        isASCIIAlphanumeric(scalar) || scalar == "." || scalar == "_" || scalar == "-"
    }

    private static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 0x30 && scalar.value <= 0x39) || (scalar.value >= 0x41 && scalar.value <= 0x5A)
            || (scalar.value >= 0x61 && scalar.value <= 0x7A)
    }

    private static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x30 && scalar.value <= 0x39
    }

    private static func allDigits(_ text: String, count: ClosedRange<Int>) -> Bool {
        let scalars = text.unicodeScalars
        return count.contains(scalars.count) && scalars.allSatisfy(isASCIIDigit)
    }

    // MARK: Canonical form

    private static let multiLineFields: Set<String> = ["notes", "address"]

    private static func stripControls(_ text: String, keepingLines: Bool) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let v = scalar.value
            let isControl = v <= 0x1F || v == 0x7F
            let isLine = v == 0x09 || v == 0x0A || v == 0x0D
            if isControl && !(keepingLines && isLine) { continue }
            out.append(scalar)
        }
        return String(out)
    }

    private static func digits(of text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter(isASCIIDigit)))
    }

    /// JavaScript's `trim()` (see VaultText.swift), not Foundation's, which also trims U+0085 and keeps U+FEFF.
    private static func trimmed(_ text: String) -> String {
        jsTrim(text)
    }

    /// The canonical form of an entry: control characters removed (keeping the line breaks of notes and an
    /// address), strings trimmed, empty fields dropped, the card number without spaces or dashes, a
    /// one-digit month padded and a two-digit year widened to 20yy. The password is the one field kept
    /// exactly as typed: a leading or trailing space can be part of a real password.
    public static func canonical(_ kind: VaultItemKind, _ input: Fields) -> Fields {
        var out: Fields = [:]
        for field in kind.fields {
            guard let raw = input[field] else { continue }
            var value = field == "password" ? raw : trimmed(stripControls(raw, keepingLines: multiLineFields.contains(field)))
            if field == "number" {
                value = String(String.UnicodeScalarView(value.unicodeScalars.filter { !isWhitespace($0) && $0 != "-" }))
            }
            if field == "expMonth", allDigits(value, count: 1...1) { value = "0" + value }
            if field == "expYear", allDigits(value, count: 2...2) { value = "20" + value }
            if !value.isEmpty { out[field] = value }
        }
        return out
    }

    /// What the web's `\s` matches, for the card number strip and Luhn.
    private static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        isJSWhitespace(scalar)
    }

    // MARK: Validation

    /// The fewest digits a phone number may have. The hint shows the last four, so a number must be longer for it to stay a mask.
    public static let minPhoneDigits = 5

    /// A shape check, not a deliverability check: something@something.something with no spaces. The web's
    /// `/^[^\s@]+@[^\s@]+\.[^\s@]+$/` over Unicode scalars: no JavaScript white space and exactly one "@", something
    /// before it, and in what follows a "." with a scalar on each side of it (so "a@b..c" and "a@.b.c" pass and
    /// "a@b." and "a@.b" do not). Scalars and not Characters, so a combining mark glued to the dot or the "@"
    /// does not change the answer, and "\r\n" is two white space scalars and not one Character.
    static func looksLikeEmail(_ text: String) -> Bool {
        var localCount = 0
        var domain: [Unicode.Scalar] = []
        var seenAt = false
        for scalar in text.unicodeScalars {
            if isJSWhitespace(scalar) { return false }
            if scalar == "@" {
                if seenAt { return false }
                seenAt = true
            } else if seenAt {
                domain.append(scalar)
            } else {
                localCount += 1
            }
        }
        guard seenAt, localCount > 0, domain.count >= 3 else { return false }
        return (1...(domain.count - 2)).contains { domain[$0] == "." }
    }

    /// The host of an http(s) address as `new URL(url).hostname` writes it, or nil when `new URL` throws, the
    /// scheme is not http(s) or there is no host. Not `URL(string:)`: that is RFC 3986 and its answer depends on
    /// the OS. See VaultWebHost.swift.
    static func webHost(_ url: String) -> String? {
        VaultWebHost.host(of: url)
    }

    /// The first problem with a canonical entry, worded for the person filling in the form.
    /// Expiry is checked for shape only: an expired card is still a card someone may want to keep.
    static func fieldsError(_ kind: VaultItemKind, _ f: Fields) -> String? {
        switch kind {
        case .login:
            if f["username"] == nil { return "Add the username." }
            if trimmed(f["password"] ?? "").isEmpty { return "Add the password." }
            if let url = f["url"], webHost(url) == nil {
                return "The website must be a full address starting with http:// or https://."
            }
            return nil
        case .card:
            let number = f["number"] ?? ""
            if !allDigits(number, count: 12...19) { return "The card number must be 12 to 19 digits." }
            if !luhnValid(number) { return "That card number doesn't look right. Check it for a typo." }
            let month = f["expMonth"] ?? ""
            if !(allDigits(month, count: 2...2) && (1...12).contains(Int(month) ?? 0)) { return "The expiry month must be 1 to 12." }
            if !allDigits(f["expYear"] ?? "", count: 4...4) { return "The expiry year must be 2 or 4 digits." }
            if let cvc = f["cvc"], !allDigits(cvc, count: 3...4) { return "The security code must be 3 or 4 digits." }
            return nil
        case .contact:
            if f["fullName"] == nil, f["email"] == nil, f["phone"] == nil, f["address"] == nil {
                return "Add a name, email, phone or address."
            }
            if let email = f["email"], !looksLikeEmail(email) { return "That email address doesn't look right." }
            if let phone = f["phone"], digits(of: phone).count < minPhoneDigits {
                return "The phone number needs at least \(minPhoneDigits) digits."
            }
            return nil
        }
    }

    /// Why an entry is not a valid login, card or contact, or nil when it is. The message is shown to the
    /// person as is. Accepts what the form holds: spaces in a card number, "4" for April, "27" for 2027.
    public static func validate(_ kind: VaultItemKind, _ fields: Fields) -> String? {
        fieldsError(kind, canonical(kind, fields))
    }

    /// Reads a stored or submitted value (the JSON string a secret holds) as an entry of `kind`.
    /// A valid value comes back canonical, with unknown keys dropped.
    public static func parse(_ kind: VaultItemKind, value: String) -> Result<Fields, ParseError> {
        guard let data = value.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return .failure(ParseError(message: kind.shapeError)) }
        var fields: Fields = [:]
        for field in kind.fields {
            guard let raw = object[field], !(raw is NSNull) else { continue }
            guard let text = raw as? String else { return .failure(ParseError(message: "\(field) must be a string.")) }
            fields[field] = text
        }
        let canonicalFields = canonical(kind, fields)
        if let problem = fieldsError(kind, canonicalFields) { return .failure(ParseError(message: problem)) }
        return .success(canonicalFields)
    }

    public struct ParseError: Error, Sendable, Equatable {
        public let message: String
    }

    /// The canonical JSON an entry is stored as: fixed key order, trimmed strings, a digits-only card number.
    /// Two submissions of the same card, one typed with spaces and one pasted with dashes, store the same bytes.
    /// Expects a valid entry; it normalizes, it does not validate.
    public static func serialize(_ kind: VaultItemKind, _ fields: Fields) -> String {
        let canonicalFields = canonical(kind, fields)
        let members = kind.fields.compactMap { field in
            canonicalFields[field].map { "\(quoted(field)):\(quoted($0))" }
        }
        return "{" + members.joined(separator: ",") + "}"
    }

    /// A JSON string literal the way `JSON.stringify` writes one: only `"` `\` and C0 controls are escaped.
    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += "\\u" + String(format: "%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    // MARK: Hints

    /// Matches the hint column's check constraint (migration 0055), so a derived hint always fits.
    public static let hintMax = 120

    private static func clampHint(_ hint: String) -> String {
        let scalars = Array(hint.unicodeScalars)
        guard scalars.count > hintMax else { return hint }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: scalars.prefix(hintMax - 1))
        return String(out) + "…"
    }

    /// The plaintext subtitle the list shows for an entry: a card's brand and last four digits, a login's
    /// username, a contact's email, else the last four digits of the phone, else the name, else "Address".
    /// Never a full card number, a security code or a password.
    public static func deriveHint(_ kind: VaultItemKind, _ fields: Fields) -> String {
        let f = canonical(kind, fields)
        let hint: String
        switch kind {
        case .card:
            let number = digits(of: f["number"] ?? "")
            hint = "\(cardBrand(number).label) •••• \(number.suffix(4))"
        case .login:
            hint = f["username"] ?? ""
        case .contact:
            if let email = f["email"] {
                hint = email
            } else if let phone = f["phone"] {
                hint = "•••• \(digits(of: phone).suffix(4))"
            } else {
                hint = f["fullName"] ?? "Address"
            }
        }
        return clampHint(hint)
    }

    // MARK: Cards

    public enum CardBrand: String, Sendable, CaseIterable, Hashable {
        case visa, mastercard, amex, discover, other

        /// How a hint names each brand. An unrecognised one is just "Card", so its hint still reads "Card •••• 1234".
        public var label: String {
            switch self {
            case .visa: return "Visa"
            case .mastercard: return "Mastercard"
            case .amex: return "Amex"
            case .discover: return "Discover"
            case .other: return "Card"
            }
        }
    }

    /// The network a card number belongs to, from its leading digits alone, so the form can show the
    /// brand while the number is still being typed. Anything not recognised is `.other`.
    public static func cardBrand(_ number: String) -> CardBrand {
        let d = digits(of: number)
        if d.hasPrefix("34") || d.hasPrefix("37") { return .amex }
        if d.hasPrefix("4") { return .visa }
        if let second = d.dropFirst().first, d.hasPrefix("5"), ("1"..."5").contains(String(second)) { return .mastercard }
        if d.count >= 4, let firstFour = Int(d.prefix(4)), (2221...2720).contains(firstFour) { return .mastercard }
        if d.hasPrefix("6011") || d.hasPrefix("65") { return .discover }
        if d.hasPrefix("64"), let third = d.dropFirst(2).first, ("4"..."9").contains(String(third)) { return .discover }
        return .other
    }

    /// The brand a card hint names ("Visa •••• 4242" is visa), or nil when the hint is not a card hint.
    public static func cardBrand(fromHint hint: String?) -> CardBrand? {
        guard let hint, let range = hint.range(of: " •••• ") else { return nil }
        let tail = hint[range.upperBound...]
        guard tail.count == 4, tail.unicodeScalars.allSatisfy(isASCIIDigit) else { return nil }
        let label = String(hint[..<range.lowerBound])
        return CardBrand.allCases.first { $0.label == label }
    }

    /// The Luhn checksum every payment card number carries, which catches a single mistyped digit and most
    /// swapped neighbours. Spaces and dashes are ignored; any other character makes the number invalid.
    public static func luhnValid(_ number: String) -> Bool {
        let cleaned = number.unicodeScalars.filter { !isWhitespace($0) && $0 != "-" }
        guard !cleaned.isEmpty, cleaned.allSatisfy(isASCIIDigit) else { return false }
        var sum = 0
        for (index, scalar) in cleaned.reversed().enumerated() {
            var digit = Int(scalar.value) - 0x30
            if index % 2 == 1 {
                digit *= 2
                if digit > 9 { digit -= 9 }
            }
            sum += digit
        }
        return sum % 10 == 0
    }

    /// A card number grouped for display while it is typed: Amex as 4-6-5, every other brand in fours.
    /// Non-digits are dropped and the length is capped at the most the brand can have.
    public static func formatCardNumber(_ input: String) -> String {
        let d = digits(of: input)
        if cardBrand(d) == .amex {
            let amex = String(d.prefix(15))
            return [String(amex.prefix(4)), String(amex.dropFirst(4).prefix(6)), String(amex.dropFirst(10))]
                .filter { !$0.isEmpty }.joined(separator: " ")
        }
        let capped = String(d.prefix(19))
        var groups: [String] = []
        var index = capped.startIndex
        while index < capped.endIndex {
            let next = capped.index(index, offsetBy: 4, limitedBy: capped.endIndex) ?? capped.endIndex
            groups.append(String(capped[index..<next]))
            index = next
        }
        return groups.joined(separator: " ")
    }

    // MARK: Suggested names

    /// Squashes text into a valid secret name: each run of disallowed characters becomes one dash,
    /// capped at 100 characters, with no leading or trailing dash or dot. "" when nothing usable is left.
    static func toSecretName(_ text: String) -> String {
        var name = ""
        var inRun = false
        for scalar in text.unicodeScalars {
            if isNameScalar(scalar) {
                name.unicodeScalars.append(scalar)
                inRun = false
            } else if !inRun {
                name += "-"
                inRun = true
            }
        }
        name = String(name.prefix(100))
        while let first = name.first, first == "-" || first == "." { name.removeFirst() }
        while let last = name.last, last == "-" || last == "." { name.removeLast() }
        return isValidName(name) ? name : ""
    }

    /// A name the add form can prefill while the person types, always valid or "". A login is named for its
    /// site's host without "www." (an address typed without http:// still counts here, though validation will
    /// ask for it), else for its username; a card is "visa-4242" ("card-1234" for an unrecognised brand);
    /// contact info is "contact", or "home" when it is only an address.
    public static func suggestName(_ kind: VaultItemKind, _ fields: Fields) -> String {
        let f = canonical(kind, fields)
        switch kind {
        case .login:
            if let url = f["url"], var host = webHost(url.contains("://") ? url : "https://\(url)") {
                if host.hasPrefix("www.") { host.removeFirst(4) }
                let name = toSecretName(host)
                if !name.isEmpty { return name }
            }
            return toSecretName(f["username"] ?? "")
        case .card:
            let number = digits(of: f["number"] ?? "")
            guard number.count >= 4 else { return "" }
            let brand = cardBrand(number)
            return "\(brand == .other ? "card" : brand.rawValue)-\(number.suffix(4))"
        case .contact:
            if f["fullName"] != nil || f["email"] != nil || f["phone"] != nil { return "contact" }
            return f["address"] != nil ? "home" : ""
        }
    }

    // MARK: Agent-facing

    /// The fields a typed value's JSON may carry, for the line under the fetch command.
    public static func valueFieldsLine(_ kind: VaultItemKind) -> String {
        switch kind {
        case .login: return "url, username, password and notes"
        case .card: return "cardholder, number, expMonth, expYear and cvc"
        case .contact: return "fullName, email, phone and address"
        }
    }
}
