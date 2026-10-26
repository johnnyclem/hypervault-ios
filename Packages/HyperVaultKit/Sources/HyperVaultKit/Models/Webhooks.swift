import Foundation

// Signed outbound webhooks: where HyperVault POSTs truth events, for whom, and
// signed how. A power-user corner of Account & keys. The web app's source is
// app/api/webhooks/** and lib/webhooks/subscriptions.ts; docs/truth-events.md
// explains the events and how a receiver checks the signature.
//
// The signing secret is returned once, by the create call, and `CreatedWebhook`
// is written so that nothing prints it by accident.

public struct OutboundWebhook: Sendable, Codable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let url: String
    /// `truth.*` or any of `WebhookRules.knownEvents`.
    public let events: [String]
    /// Only entries whose author or signer is in this list are delivered; empty means all.
    public let authors: [String]
    public let enabled: Bool
    public let consecutiveFailures: Int
    public let lastDeliveredAt: Date?
    public let lastStatus: Int?
    public let createdAt: Date?

    public init(
        id: String, name: String = "", url: String, events: [String] = ["truth.*"], authors: [String] = [],
        enabled: Bool = true, consecutiveFailures: Int = 0, lastDeliveredAt: Date? = nil, lastStatus: Int? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.events = events
        self.authors = authors
        self.enabled = enabled
        self.consecutiveFailures = consecutiveFailures
        self.lastDeliveredAt = lastDeliveredAt
        self.lastStatus = lastStatus
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        events = try c.decodeIfPresent([String].self, forKey: .events) ?? ["truth.*"]
        authors = try c.decodeIfPresent([String].self, forKey: .authors) ?? []
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        consecutiveFailures = try c.decodeIfPresent(Int.self, forKey: .consecutiveFailures) ?? 0
        lastDeliveredAt = try c.decodeIfPresent(Date.self, forKey: .lastDeliveredAt)
        lastStatus = try c.decodeIfPresent(Int.self, forKey: .lastStatus)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    enum Keys: String, CodingKey {
        case id, name, url, events, authors, enabled, consecutiveFailures, lastDeliveredAt, lastStatus, createdAt
    }

    /// The name, else the host the hook posts to.
    public var title: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return URL(string: url)?.host ?? url
    }

    /// 25 failures in a row turn a hook off; the screen warns well before.
    public var isFailing: Bool { consecutiveFailures > 0 }
}

/// How a receiver checks a delivery, as the list answers it.
public struct WebhookSigning: Sendable, Decodable, Equatable {
    public let signatureHeader: String?
    public let eventHeader: String?
    public let deliveryHeader: String?
    public let scheme: String?
    public let retries: String?
}

public struct WebhookList: Sendable, Decodable, Equatable {
    public let webhooks: [OutboundWebhook]
    public let events: [String]
    public let signing: WebhookSigning?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        webhooks = try c.decodeIfPresent([OutboundWebhook].self, forKey: .webhooks) ?? []
        events = try c.decodeIfPresent([String].self, forKey: .events) ?? WebhookRules.knownEvents
        signing = try c.decodeIfPresent(WebhookSigning.self, forKey: .signing)
    }

    enum Keys: String, CodingKey { case webhooks, events, signing }
}

/// `POST /api/webhooks` (201): the hook and its signing secret, which is shown once.
public struct CreatedWebhook: Sendable, Decodable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let webhook: OutboundWebhook
    public let secret: String
    public let message: String?

    public var description: String { "CreatedWebhook(id: \(webhook.id))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["webhook": webhook], displayStyle: .struct) }
}

/// One attempt to deliver an event to a hook.
public struct WebhookDelivery: Sendable, Decodable, Identifiable, Equatable {
    public let id: String
    public let status: String?
    public let attempts: Int?
    public let lastStatus: Int?
    public let lastError: String?
    public let createdAt: Date?
    public let deliveredAt: Date?
}

public struct WebhookDetail: Sendable, Decodable, Equatable {
    public let webhook: OutboundWebhook
    public let deliveries: [WebhookDelivery]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        webhook = try c.decode(OutboundWebhook.self, forKey: .webhook)
        deliveries = try c.decodeIfPresent([WebhookDelivery].self, forKey: .deliveries) ?? []
    }

    enum Keys: String, CodingKey { case webhook, deliveries }
}

/// What `POST /api/webhooks/[id]/test` found at the receiver.
public struct WebhookTestResult: Sendable, Decodable, Equatable {
    public let ok: Bool
    public let status: Int?
    public let response: String?
    public let error: String?

    /// One sentence for the result.
    public var summary: String {
        if ok { return "The receiver answered \(status.map(String.init) ?? "OK"). Real events will arrive the same way." }
        if let error, !error.isEmpty { return "Could not reach it: \(error)" }
        if let status { return "The receiver answered \(status). It needs a 2xx for a delivery to count." }
        return "Could not reach it."
    }
}

public struct WebhookUpdate: Sendable, Decodable, Equatable {
    public let webhook: OutboundWebhook
}

// MARK: Endpoints

extension Endpoint where Response == WebhookList {
    public static var webhooks: Endpoint<WebhookList> { Endpoint(.get, "/api/webhooks") }
}

extension Endpoint where Response == CreatedWebhook {
    /// Registers a hook. The secret comes back once. `events` defaults to everything (`truth.*`);
    /// `authors` limits delivery to entries whose author or signer is named.
    public static func createWebhook(url: String, name: String? = nil, events: [String]? = nil, authors: [String] = []) -> Endpoint<CreatedWebhook> {
        var body: [String: JSONValue] = ["url": .string(url)]
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { body["name"] = .string(name) }
        if let events, !events.isEmpty { body["events"] = .array(events.map(JSONValue.string)) }
        if !authors.isEmpty { body["authors"] = .array(authors.map(JSONValue.string)) }
        return Endpoint(.post, "/api/webhooks", body: .jsonValue(.object(body)))
    }
}

extension Endpoint where Response == WebhookUpdate {
    public static func setWebhookEnabled(id: String, enabled: Bool) -> Endpoint<WebhookUpdate> {
        Endpoint(.patch, "/api/webhooks/\(id)", body: .jsonValue(["enabled": .bool(enabled)]))
    }
}

extension Endpoint where Response == WebhookDetail {
    public static func webhookDetail(id: String) -> Endpoint<WebhookDetail> { Endpoint(.get, "/api/webhooks/\(id)") }
}

extension Endpoint where Response == WebhookTestResult {
    /// Sends a signed `truth.test` ping to the hook's URL right now. The route can take up to ten seconds.
    public static func testWebhook(id: String) -> Endpoint<WebhookTestResult> {
        Endpoint(.post, "/api/webhooks/\(id)/test", timeout: 40)
    }
}

extension Endpoint where Response == NoContent {
    public static func deleteWebhook(id: String) -> Endpoint<NoContent> { Endpoint(.delete, "/api/webhooks/\(id)") }
}

// MARK: Rules

public enum WebhookRules {
    /// The events a hook can name (lib/webhooks/subscriptions.ts); the list route returns the live set.
    public static let knownEvents = [
        "truth.*", "truth.challenged", "truth.overturned", "truth.upheld", "truth.verified", "truth.undermined", "truth.restored",
    ]

    /// How many hooks a person may have.
    public static let maxHooks = 20

    /// The failures in a row after which a hook is switched off.
    public static let disableAfterFailures = 25

    /// A target has to be an absolute http(s) URL. The server also refuses private, loopback and
    /// cloud-metadata hosts, and says why.
    public static func validate(url: String) -> String? {
        let text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "Add the address HyperVault should post to." }
        guard let parsed = URL(string: text), let scheme = parsed.scheme?.lowercased(), parsed.host?.isEmpty == false else {
            return "The address must be a full URL, like https://example.com/hooks/hypervault."
        }
        guard scheme == "https" || scheme == "http" else { return "The address must start with https:// or http://." }
        if text.count > 2000 { return "That address is too long." }
        return nil
    }

    /// `grok, gemini` or one name per line, as the list the route takes.
    public static func authors(from text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(50).map { $0 }
    }

    /// `truth.challenged` reads as "Challenged".
    public static func eventTitle(_ event: String) -> String {
        if event == "truth.*" { return "Everything" }
        let name = event.hasPrefix("truth.") ? String(event.dropFirst(6)) : event
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}
