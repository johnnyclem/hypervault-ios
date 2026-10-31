import HyperVaultKit
import SwiftUI
import UIKit

/// Screens the chat tab pushes by itself. Conversations and rooms are `Route`s
/// (other features and links reach them); these are only for this tab.
enum ChatDestination: Hashable {
    case newConversation
    case models
}

/// An action that failed, in words that can go straight into a toast.
struct ChatActionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension HVError {
    /// The sentence for a failed action: the server's own, except when the
    /// request never arrived, where `offline` says so.
    func sentence(offline: String) -> String {
        isOffline ? offline : userMessage
    }
}

// MARK: Dates

enum ChatDates {
    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .named
        return formatter
    }()

    /// "2h ago", "yesterday", "3d ago".
    static func relative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        if now.timeIntervalSince(date) < 60 { return "Just now" }
        return relative.localizedString(for: date, relativeTo: now)
    }

    enum Bucket: Int, CaseIterable, Identifiable {
        case today, yesterday, week, month, earlier

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .today: return "Today"
            case .yesterday: return "Yesterday"
            case .week: return "Previous 7 days"
            case .month: return "Previous 30 days"
            case .earlier: return "Earlier"
            }
        }
    }

    /// Items grouped under "Today", "Yesterday" and so on, newest group first; empty groups are left out.
    static func sections<Item>(
        of items: [Item], date: (Item) -> Date?, now: Date = Date(), calendar: Calendar = .current
    ) -> [(bucket: Bucket, items: [Item])] {
        let grouped = Dictionary(grouping: items) { bucket(for: date($0), now: now, calendar: calendar) }
        return Bucket.allCases.compactMap { bucket in
            guard let items = grouped[bucket], !items.isEmpty else { return nil }
            return (bucket, items)
        }
    }

    static func bucket(for date: Date?, now: Date = Date(), calendar: Calendar = .current) -> Bucket {
        guard let date else { return .earlier }
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return .yesterday
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days < 7 { return .week }
        if days < 30 { return .month }
        return .earlier
    }
}

// MARK: Layout

/// Chips that wrap onto as many lines as they need. Items of different heights sit on the middle of
/// their line, so a tag beside a line of text does not hang from the top. An item wider than the whole
/// is offered the whole width, so its text wraps instead of running off the edge.
struct ChatFlowLayout: Layout {
    var spacing: CGFloat = HV.Space.xs

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arranged = arrange(width: bounds.width, subviews: subviews)
        for index in subviews.indices {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + arranged.points[index].x, y: bounds.minY + arranged.points[index].y),
                anchor: .leading,
                proposal: ProposedViewSize(arranged.sizes[index])
            )
        }
    }

    /// The size of the whole; for each item its size, and the point its leading edge and vertical middle sit at.
    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, sizes: [CGSize], points: [CGPoint]) {
        let offered = ProposedViewSize(width: width.isFinite ? width : nil, height: nil)
        let sizes = subviews.map { $0.sizeThatFits(offered) }
        var lines: [[Int]] = [[]]
        var x: CGFloat = 0
        for (index, size) in sizes.enumerated() {
            if x > 0, x + size.width > width {
                lines.append([])
                x = 0
            }
            lines[lines.count - 1].append(index)
            x += size.width + spacing
        }

        var points = [CGPoint](repeating: .zero, count: sizes.count)
        var y: CGFloat = 0
        var widest: CGFloat = 0
        for line in lines where !line.isEmpty {
            let height = line.map { sizes[$0].height }.max() ?? 0
            var lineX: CGFloat = 0
            for index in line {
                points[index] = CGPoint(x: lineX, y: y + height / 2)
                lineX += sizes[index].width + spacing
            }
            widest = max(widest, lineX - spacing)
            y += height + spacing
        }
        return (CGSize(width: widest, height: max(0, y - spacing)), sizes, points)
    }
}

// MARK: Who is speaking

/// The colour a model family wears wherever it appears: its row on the Models screen, the pill on an
/// imported chat, its dot and its handle in a room. It follows who the model is, never where it sits in
/// a list, so Claude is the same orange on every screen. The cases are in the order a clash falls through.
/// Rose is last and no family owns it: it sits too close to the red of a failed turn.
enum ChatAgentTone: CaseIterable, Hashable {
    case coral, mint, blue, violet, amber, cyan, sky, rose

    /// The three tones the palette has no token for. They are a model family's colour and nothing else's: no tile, tag
    /// or glyph takes a hue for being a destination, so `Palette` no longer carries them. Each is its dark shade and, in
    /// the light look, the 700 the other accents mirror to.
    private enum Ramp {
        static let coral = Color(dark: 0xF97316, light: 0xC2410C)
        static let cyan = Color(dark: 0x22D3EE, light: 0x0E7490)
        static let rose = Color(dark: 0xFB7185, light: 0xBE123C)
    }

    var color: Color {
        switch self {
        case .coral: return Ramp.coral
        case .mint: return Palette.mint
        case .blue: return Palette.blue
        case .rose: return Ramp.rose
        case .amber: return Palette.amber
        case .violet: return Palette.violet
        case .sky: return Palette.sky
        case .cyan: return Ramp.cyan
        }
    }

    /// The family a backend's `provider` names; an endpoint nobody has heard of gets the plain one.
    init(provider: String) {
        switch provider {
        case "anthropic", "custom-anthropic": self = .coral
        case "openai": self = .mint
        case "gemini": self = .blue
        case "xai": self = .violet
        case "mistral": self = .amber
        case "ollama", "lmstudio": self = .cyan
        default: self = .sky
        }
    }

    /// The family an imported chat came from, or nil for a chat that was started here.
    init?(platform: ChatPlatform) {
        switch platform {
        case .chatgpt: self = .init(provider: "openai")
        case .claude: self = .init(provider: "anthropic")
        case .gemini: self = .init(provider: "gemini")
        case .grok: self = .init(provider: "xai")
        case .hypervault, .other: return nil
        }
    }

    /// One tone for each of these providers, in the same order. The first of a family keeps its own
    /// tone whoever else is in the list; later members of the same family take the next tone nobody
    /// has, so no two dots in a room match.
    static func tones(forProviders providers: [String]) -> [ChatAgentTone] {
        let own = providers.map { ChatAgentTone(provider: $0) }
        var result = [ChatAgentTone?](repeating: nil, count: own.count)
        var taken = Set<ChatAgentTone>()
        for (index, tone) in own.enumerated() where !taken.contains(tone) {
            result[index] = tone
            taken.insert(tone)
        }
        let all = ChatAgentTone.allCases
        for (index, tone) in own.enumerated() where result[index] == nil {
            let start = all.firstIndex(of: tone) ?? 0
            let free = (1..<all.count).map { all[(start + $0) % all.count] }.first { !taken.contains($0) }
            result[index] = free ?? tone
            taken.insert(free ?? tone)
        }
        return result.compactMap { $0 }
    }
}

/// The note under a section of a form, in the app's own size and grey rather than the system's.
struct ChatFooter: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.hvCaption).foregroundStyle(Palette.textSecondary)
    }
}

/// The example inside a field that has its own label above it, in a grey that still reads.
func chatPrompt(_ text: String) -> Text {
    Text(text).foregroundStyle(Palette.textTertiary)
}

// MARK: Model names

enum ChatModelNames {
    /// What the thread shows under a reply for the model that wrote it.
    static func display(_ model: String?) -> String? {
        guard let model, !model.isEmpty else { return nil }
        if model == "apple-on-device" { return "On this iPhone" }
        return model
    }
}

/// One shared outbox per person, so the list, a conversation and the launch
/// flush never replay the same turn twice at once.
@MainActor
enum ChatOutboxes {
    private static var byUser: [String: ChatTurnOutbox] = [:]

    static func outbox(for env: AppEnvironment) -> ChatTurnOutbox {
        if let existing = byUser[env.user.id] { return existing }
        let made = ChatTurnOutbox(cache: env.cache, namespace: env.user.id)
        byUser[env.user.id] = made
        return made
    }
}

// MARK: Long requests

/// A chat turn can take two minutes. If the person leaves the app meanwhile,
/// iOS lends a little time to finish the request before suspending it.
@MainActor
final class ChatBackgroundGrace {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    func begin(_ name: String) {
        end()
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            Task { @MainActor in self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

// MARK: The tile on a model's row

/// The neutral tile at the head of a model's row on the Models screen and in the options sheet, so a connection looks
/// the same on both: `HVTile` at the side `HVRow` gives its own (36, growing with the type to 44). A connection to a
/// provider carries the first letter of the provider's name; where a model runs (this Mac, this iPhone) has a glyph of
/// its own. The provider's colour is the small dot by its name, never the tile. The tile is decoration and hidden from
/// VoiceOver; the row's words say which provider it is.
struct ChatModelTile: View {
    private enum Mark {
        case symbol(String)
        case monogram(String)
    }

    private let mark: Mark
    @ScaledMetric(relativeTo: .body) private var scaled: CGFloat = HV.rowTile

    init(symbol: String) { mark = .symbol(symbol) }

    init(monogram: String) { mark = .monogram(monogram) }

    /// The tile of a connection to `provider`: the first letter of its short name ("A" for Anthropic, not the first letter
    /// of the name the person gave the connection). An empty registry falls back to the built-in list.
    init(provider: String, registry: [Capabilities.ProviderSpec] = []) {
        let name = ChatProviders.shortName(for: provider, in: registry)
        self.init(monogram: name.first.map { String($0).uppercased() } ?? "?")
    }

    var body: some View {
        let side = HV.glyphBox(scaled: scaled, base: HV.rowTile)
        switch mark {
        case .symbol(let name): HVTile(symbol: name, size: side)
        case .monogram(let letter): HVTile(monogram: letter, size: side)
        }
    }
}
