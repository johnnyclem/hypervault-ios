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

/// Chips that wrap onto as many lines as they need.
struct ChatFlowLayout: Layout {
    var spacing: CGFloat = HV.Space.xs

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arranged = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in arranged.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + rowHeight), origins)
    }
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
