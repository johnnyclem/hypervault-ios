import Foundation

/// The Library's and the page screens' sentences, from the web's `lib/copy.ts`,
/// word for word. A screen that says the same thing says it with these.
public enum LibraryCopy {
    public static let title = "Library"
    public static let searchLabel = "Search by name"
    public static let filterGroupLabel = "Show"
    public static let showMore = "Show more"
    /// Under a list that stopped at the most the server reads, so its end is not taken for the end of everything.
    public static let truncated = "These are the most recent. Search by name to find the rest."
    public static let emptyVault = "Nothing kept yet."
    public static let nothingHere = "Nothing here."
    // The web ends these with "Try again." because its error has no button. Here the screen has one,
    // so the line says what happened and the button says what to do.
    public static let failed = "That did not load."
    public static let offline = "Network hiccup. That did not load."
    public static let tryAgain = "Try again"
    public static let newLabel = "New"

    public static let kept = "Kept. Here's the link."
    public static let alreadyKept = "Already kept. Here's the link."
    public static let onlyYou = "Only you can open it."

    public static let sharePeople = "People"
    public static let shareFooter = "Only people you add can open this."
    public static let shareEmail = "Email"
    public static let shareAdd = "Add"
    public static let shareRole = "Role"
    public static let shareRemove = "Remove"
    public static let sharedWithYou = "Shared with you"

    public static let copyLink = "Copy link"
    public static let linkCopied = "Copied"
    public static let linkCopyFailed = "Could not copy"

    /// What each filter is called.
    public static func title(for filter: YoursFilter) -> String { filter.title }

    /// What an empty list says: an empty vault, or a filter or a name that matched nothing.
    public static func emptyLine(filter: YoursFilter, query: String) -> String {
        filter == .all && query.trimmingCharacters(in: .whitespaces).isEmpty ? emptyVault : nothingHere
    }

    /// How long ago, in the biggest unit that fits, rounded down (`agoLine`). Under a minute, in the future or not a number is "Just now".
    public static func ago(seconds: TimeInterval) -> String {
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

    public static func ago(since date: Date?, now: Date = Date()) -> String? {
        date.map { ago(seconds: now.timeIntervalSince($0)) }
    }

    /// When a thing was last in use: opened, else changed. Yours puts things in this order.
    public static func ago(for item: KeptItem, now: Date = Date()) -> String? {
        ago(since: item.lastOpenedAt ?? item.updatedAt, now: now)
    }
}
