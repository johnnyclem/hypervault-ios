import Foundation

/// The product's sentences, verbatim from the web app's `lib/copy.ts`, so the
/// canvas, Yours and the keep flow read as the same product on either. A string
/// that must contain a word the first-run banned list names does not belong on
/// a first-run surface.
public enum HVCopy {
    // The front door
    public static let landingLine = "Keep what your AI just made. Only you can open it."
    public static let chatPlaceholder = "Ask, or paste something to keep."
    public static let productSentence = "You talk to your AI like usual. HyperVault keeps the thing worth keeping, and you only see it when you ask for it."
    public static let productSentenceMore = "You can pull a memory, a file, a group of files, or a key onto the page. Nobody else can open it until you share it."

    // Keeping
    public static let keptLine = "Kept. Here's the link."
    public static let alreadyKeptLine = "Already kept. Here's the link."
    public static let onlyYouLine = "Only you can open it."
    public static let keepingLine = "Keeping..."
    public static let nothingToKeepLine = "Nothing to keep yet. Paste something, or keep a reply."
    public static let keepFailedLine = "That could not be kept. Try again."
    public static let keepOfflineLine = "Network hiccup. Nothing was kept. Try again."
    /// What a memory write says when the server sent no sentence of its own.
    public static let keptInMemoryLine = "Kept in memory."
    public static let keepItLabel = "Keep it"
    public static let askInsteadLabel = "Ask instead"
    public static let keepReplyLabel = "Keep"
    public static let copyPromptLabel = "Copy a starter prompt"
    public static let copyPromptNextLine = "Now paste it into the AI you already use."

    public static func pastedLine(characters: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        return "Pasted - \(formatter.string(from: NSNumber(value: characters)) ?? String(characters)) characters"
    }

    // Yours
    public static let panelTitle = "Yours."
    public static let emptyPanel = "Nothing kept yet."
    public static let yoursSearchLabel = "Search by name"
    public static let recentHeading = "Recent"
    public static let onPageLabel = "On the page"
    public static let yoursNothingHereLine = "Nothing here."
    public static let yoursFailedLine = "That did not load. Try again."
    public static let yoursOfflineLine = "Network hiccup. That did not load. Try again."
    public static let tryAgainLabel = "Try again"
    public static let newAskLine = "What do you want to keep?"
    public static let libraryTruncatedLine = "These are the most recent. Search by name to find the rest."

    public static func showNoneLine(_ target: ShowTarget) -> String {
        switch target {
        case .memories: return "No memories yet."
        case .files: return "No files yet."
        case .keys: return "No keys yet."
        case .stuff: return emptyPanel
        }
    }

    // Pulling
    public static let pullWhichLine = "Which one?"
    public static let pullNoneLine = "Nothing matches."
    public static let pullMoreLine = "There are more. Say more of the name to narrow it."

    // Hints and help
    public static let hintKeepLine = "Paste anything here to keep it."
    public static let hintTryLabel = "Try"
    public static let hintExamples = ["Show my memories", "Show my files"]
    public static let hintAskLine = "Ask anything else and your model answers."
    public static let hintConnectLine = "Connect your AI and it keeps things here for you."
    public static let connectAILabel = "Connect your AI"
    public static let noModelLine = "Nothing is connected yet, so nothing can answer. Connect your AI to get started."
    public static let helpLine = "Paste anything here to keep it. Say \"show my memories\" or \"show my files\" to see what you have. Ask anything else and your model answers."
    public static let thinkingLine = "Thinking..."
    public static let chatFailedLine = "That did not go through. Try again."
    public static let chatOfflineLine = "Network hiccup. Your message was not sent. Try again."
    public static let replyCutShortLine = "This reply was cut short. Say continue to get the rest."
    public static let untitledCard = "Untitled"

    public static func usingLine(_ names: String) -> String { "Using: \(names)" }

    // Cards
    public static let cardOpenLabel = "Open"
    public static let cardHideLabel = "Hide"
    public static let neverUsedLine = "Never used"
    public static let agentsAllowedHeading = "Agents allowed"
    public static let noAgentsLine = "You have no agents yet. Add one under Account & keys."

    public static func filesCountLine(_ count: Int) -> String {
        if count == 1 { return "1 file" }
        return count > 0 ? "\(count) files" : "No files"
    }

    public static func agentsAllowedLine(_ count: Int) -> String {
        if count == 1 { return "1 agent allowed" }
        return count > 0 ? "\(count) agents allowed" : "No agents allowed"
    }

    public static func lastUsedLine(_ ago: String) -> String { "Last used \(ago)" }

    /// How long ago, in the biggest unit that fits, rounded down; under a minute, in the future or not a number is "Just now".
    public static func agoLine(seconds: Double) -> String {
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

    public static func ago(since date: Date, now: Date = Date()) -> String {
        agoLine(seconds: now.timeIntervalSince(date))
    }

    /// "512 B", "2.1 KB", "3 MB": the biggest unit that fits, one decimal below ten.
    public static func bytesLine(_ bytes: Int) -> String {
        guard bytes >= 1 else { return "0 B" }
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var unit = 0
        while value.rounded() >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        let shown: String
        if unit == 0 || value >= 10 {
            shown = String(Int(value.rounded()))
        } else {
            let tenths = (value * 10).rounded() / 10
            shown = tenths == tenths.rounded() ? String(Int(tenths)) : String(tenths)
        }
        return "\(shown) \(units[unit])"
    }

    /// The prompt a person pastes into the assistant they already use. It
    /// carries no key: the doc it points at tells the assistant how to save.
    public static func starterPrompt(origin: String) -> String {
        let base = origin.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        return [
            "Read \(base)/start.md then help me keep one thing in my HyperVault.",
            "Ask me what I want to keep. If I don't know, suggest two concrete things based on this chat.",
            "When I pick one, save it and give me the link.",
        ].joined(separator: "\n")
    }

    public static func explainPrompt(origin: String) -> String {
        let base = origin.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        return "Read \(base)/explain.md and tell me, in under a minute, how HyperVault works. Use one example from this chat. Do not list features."
    }
}
