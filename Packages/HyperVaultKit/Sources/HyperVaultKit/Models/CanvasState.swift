import Foundation

/// What is on the canvas: a short stack of cards, and nothing else. A port of
/// the web app's `lib/canvas/state.ts`: one list, one cap, a pure reducer.
/// Hiding a card only removes it from the list; it never touches the thing it
/// stood for.

/// The most cards on the canvas at once. Adding a ninth drops the oldest.
public let canvasMaxCards = 8

/// What a card says when its thing was kept a moment ago, here, by the person.
public struct KeptDetails: Sendable, Equatable {
    /// "Kept. Here's the link." or, for a repeat, "Already kept. Here's the link."
    public let line: String
    /// The whole link, ready to copy.
    public let link: String
    /// As the keep response reported it; only "private" earns the privacy line.
    public let visibility: String

    public init(line: String, link: String, visibility: String) {
        self.line = line
        self.link = link
        self.visibility = visibility
    }

    public var isPrivate: Bool { visibility == "private" }
}

/// The stored row a card stands for, in the terms `/api/yours/open` and `/api/yours/card` take.
public struct CardRef: Sendable, Equatable, Hashable, Encodable {
    public let kind: KeptKind
    public let id: String

    public init(kind: KeptKind, id: String) {
        self.kind = kind
        self.id = id
    }
}

public struct CanvasCard: Sendable, Equatable, Identifiable {
    /// One card per key. `artifact:<slug>` for a page, a file or a group.
    public let key: String
    public let kind: KeptKind
    public var title: String
    public var subtitle: String?
    /// Where Open goes, a path on the server.
    public let href: String
    /// Set on the card a keep just produced.
    public var kept: KeptDetails?
    /// Set on every card that came from Yours; what Open records and what the chat is told about.
    public var ref: CardRef?
    /// What `GET /api/yours/card` said, once it has said it.
    public var detail: KeptCard?

    public var id: String { key }

    public init(key: String, kind: KeptKind, title: String, subtitle: String? = nil, href: String, kept: KeptDetails? = nil, ref: CardRef? = nil, detail: KeptCard? = nil) {
        self.key = key
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.href = href
        self.kept = kept
        self.ref = ref
        self.detail = detail
    }

    /// The artifact slug for a page, file or group card.
    public var slug: String? {
        guard kind == .page || kind == .file || kind == .group, key.hasPrefix("artifact:") else { return nil }
        return String(key.dropFirst("artifact:".count))
    }
}

public enum CanvasAction: Sendable {
    case add(CanvasCard)
    /// The card's payload arrived or changed; attach it if the card is still there.
    case fill(key: String, detail: KeptCard, subtitle: String?, title: String?)
    case hide(key: String)
    case hideAll
}

public enum CanvasState {
    /// What the chat is told is on the page: the rows the cards stand for, in stack order.
    public static func pulledRefs(_ cards: [CanvasCard]) -> [CardRef] {
        cards.compactMap(\.ref)
    }

    /// Oldest first, so the stack reads in arrival order and the cap drops from the front.
    /// Adding a card already there replaces it and puts it last; a keep's link and an
    /// arrived payload survive being added again as a plain card.
    public static func reduce(_ cards: [CanvasCard], _ action: CanvasAction) -> [CanvasCard] {
        switch action {
        case .add(var card):
            let was = cards.first { $0.key == card.key }
            if card.kept == nil, let kept = was?.kept { card.kept = kept }
            if card.detail == nil, let detail = was?.detail { card.detail = detail }
            var next = cards.filter { $0.key != card.key }
            next.append(card)
            return next.count > canvasMaxCards ? Array(next.suffix(canvasMaxCards)) : next
        case .fill(let key, let detail, let subtitle, let title):
            guard cards.contains(where: { $0.key == key }) else { return cards }
            return cards.map { card in
                guard card.key == key else { return card }
                var filled = card
                filled.detail = detail
                filled.ref = CardRef(kind: detail.kind, id: detail.id)
                if let subtitle { filled.subtitle = subtitle }
                if let title { filled.title = title }
                return filled
            }
        case .hide(let key):
            return cards.contains { $0.key == key } ? cards.filter { $0.key != key } : cards
        case .hideAll:
            return []
        }
    }

    // MARK: Names

    /// A title or a spoken name reduced to its words: lower case, punctuation and
    /// spacing gone, and no leading article.
    public static func nameWords(_ text: String) -> String {
        var words = text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) })
        // A leading article goes only when something follows it ("the q3 plan", not "the").
        if words.count > 1, ["the", "my", "our", "a", "an"].contains(String(words[0])) {
            words.removeFirst()
        }
        return words.joined(separator: " ")
    }

    /// The one card a spoken name points at, or nil. A name matches when it is the
    /// whole title, or a run of whole words inside exactly one title. Two cards that
    /// both fit match nothing: the card's own Hide button is the way to pick one.
    public static func findCard(named name: String, in cards: [CanvasCard]) -> CanvasCard? {
        let wanted = nameWords(name)
        guard !wanted.isEmpty else { return nil }
        let whole = cards.filter { nameWords($0.title) == wanted }
        if !whole.isEmpty { return whole.count == 1 ? whole[0] : nil }
        let within = cards.filter { " \(nameWords($0.title)) ".contains(" \(wanted) ") }
        return within.count == 1 ? within[0] : nil
    }

    // MARK: Building cards

    public static func artifactCard(slug: String, title: String?, kind: KeptKind = .page) -> CanvasCard {
        let encoded = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
        let trimmed = title?.trimmingCharacters(in: .whitespaces) ?? ""
        return CanvasCard(
            key: "artifact:\(slug)",
            kind: kind,
            title: trimmed.isEmpty ? HVCopy.untitledCard : trimmed,
            href: kind == .group ? "/g/\(encoded)" : "/a/\(encoded)"
        )
    }

    /// The card for a thing the person just kept. Same key as `artifactCard` gives the same page.
    public static func keptCard(_ kept: KeptThing, origin: URL) -> CanvasCard {
        var card = artifactCard(slug: kept.slug, title: kept.title)
        let base = origin.absoluteString.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        card.kept = KeptDetails(
            line: kept.duplicate ? HVCopy.alreadyKeptLine : HVCopy.keptLine,
            link: base + card.href,
            visibility: kept.visibility
        )
        return card
    }

    /// The key an item's card has: a page, file or group is keyed by slug so a page that was
    /// just kept and then tapped in Yours is one card.
    public static func itemCardKey(kind: KeptKind, id: String, href: String) -> String {
        switch kind {
        case .memory: return "memory:\(id)"
        case .key: return "key:\(id)"
        default:
            let tail = href.hasPrefix("/a/") || href.hasPrefix("/g/") ? String(href.dropFirst(3)) : href
            return "artifact:\(tail.removingPercentEncoding ?? tail)"
        }
    }

    public static func itemCard(_ item: KeptItem, now: Date = Date()) -> CanvasCard {
        let when = item.lastOpenedAt ?? item.updatedAt
        return CanvasCard(
            key: itemCardKey(kind: item.kind, id: item.id, href: item.href),
            kind: item.kind,
            title: item.name,
            subtitle: when.map { HVCopy.ago(since: $0, now: now) },
            href: item.href,
            ref: CardRef(kind: item.kind, id: item.id)
        )
    }

    /// The one line a plain card carries about what the card endpoint said: a memory's
    /// digest, a page's age, a group's size and first files, a key's agents and last use.
    public static func detailLine(_ detail: KeptCard, now: Date = Date()) -> String {
        func ago(_ date: Date?) -> String { date.map { HVCopy.ago(since: $0, now: now) } ?? "Just now" }
        switch detail.kind {
        case .memory:
            if let digest = detail.digest, !digest.isEmpty { return digest }
            return ago(detail.updatedAt)
        case .page, .file:
            return ago(detail.updatedAt)
        case .group:
            let named = detail.files.prefix(3).map(\.path)
            guard !named.isEmpty else { return HVCopy.filesCountLine(0) }
            let more = detail.files.count > named.count ? ", ..." : ""
            return "\(HVCopy.filesCountLine(detail.files.count)): \(named.joined(separator: ", "))\(more)"
        case .key:
            let use = detail.lastUsedAt.map { HVCopy.lastUsedLine(HVCopy.ago(since: $0, now: now)) } ?? HVCopy.neverUsedLine
            return "\(HVCopy.agentsAllowedLine(detail.agents.count)), \(use)"
        }
    }

    /// The card for a thing asked for by its link: made from the payload, already whole.
    public static func payloadCard(_ detail: KeptCard, now: Date = Date()) -> CanvasCard {
        CanvasCard(
            key: itemCardKey(kind: detail.kind, id: detail.id, href: detail.href),
            kind: detail.kind,
            title: detail.name,
            subtitle: detailLine(detail, now: now),
            href: detail.href,
            ref: CardRef(kind: detail.kind, id: detail.id),
            detail: detail
        )
    }
}
