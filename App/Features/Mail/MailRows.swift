import HyperVaultKit
import SwiftUI
import UIKit

// The small pieces of the Mail screens: time, the two tags, a thread's row, a
// search hit, and a message in full. Mail text is written by someone else, so
// it is only ever shown as plain text.

enum MailTimeFormat {
    static func string(for date: Date?, now: Date = Date()) -> String {
        switch MailTimeBucket.bucket(for: date, now: now) {
        case .today(let day):
            return day.formatted(date: .omitted, time: .shortened)
        case .yesterday:
            return "Yesterday"
        case .thisWeek(let day):
            return day.formatted(.dateTime.weekday(.abbreviated))
        case .earlier(let day, let sameYear):
            return sameYear ? day.formatted(.dateTime.month(.abbreviated).day()) : day.formatted(.dateTime.month(.abbreviated).day().year())
        case .unknown:
            return ""
        }
    }

    /// The full stamp on a message in a thread.
    static func full(_ date: Date?) -> String {
        guard let date else { return "" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// The tag beside the name on mail an agent wrote. It is part of the screen,
/// not of the name: an agent chooses its name, and one that signs "You" still
/// gets this tag, which the person's own mail never does.
struct MailAgentTag: View {
    var body: some View {
        HVTag(text: "agent", tint: Palette.textSecondary)
            .accessibilityLabel("Written by an agent")
    }
}

/// On a note of the person's that agents cannot read.
struct MailNotSharedTag: View {
    var body: some View {
        // Always on a line of its own, so it never has a reason to wrap into a tall two-line capsule.
        HVTag(text: "Not shared with agents", tint: Palette.amber)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}

/// A row of the inbox: who, when, what about, and an unread dot.
struct MailThreadRow: View {
    let thread: MailThread

    var body: some View {
        let newest = thread.newest
        HStack(alignment: .top, spacing: HV.Space.s) {
            Circle()
                .fill(thread.unread ? Palette.blue : Color.clear)
                .frame(width: 10, height: 10)
                .padding(.top, 6)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: HV.Space.xs) {
                    Text(newest.author.label)
                        .font(.system(.body, weight: thread.unread ? .bold : .semibold))
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                    if newest.author.isAgent { MailAgentTag() }
                    Spacer(minLength: HV.Space.xs)
                    Text(MailTimeFormat.string(for: newest.createdAt))
                        .font(.hvCaption)
                        .foregroundStyle(Palette.textSecondary)
                }
                Text(newest.displaySubject)
                    .font(.system(.subheadline, weight: thread.unread ? .semibold : .regular))
                    .foregroundStyle(thread.unread ? Palette.textPrimary : Palette.textSecondary)
                    .lineLimit(2)
                if newest.attachmentCount > 0 {
                    Label("\(newest.attachmentCount)", systemImage: "paperclip")
                        .font(.hvCaption)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
        }
        .padding(.vertical, HV.Space.xxs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let newest = thread.newest
        var parts: [String] = []
        if thread.unread { parts.append("Unread") }
        parts.append(newest.author.isAgent ? "From \(newest.author.label), an agent" : "From \(newest.author.label)")
        parts.append(newest.displaySubject)
        let when = MailTimeFormat.string(for: newest.createdAt)
        if !when.isEmpty { parts.append(when) }
        if newest.attachmentCount > 0 { parts.append("\(newest.attachmentCount) attachment" + (newest.attachmentCount == 1 ? "" : "s")) }
        return parts.joined(separator: ". ")
    }
}

/// A search hit: the row, and the words around the match.
struct MailHitRow: View {
    let message: MailMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: HV.Space.xs) {
                Text(message.author.label)
                    .font(.system(.body, weight: .semibold))
                    .lineLimit(1)
                if message.author.isAgent { MailAgentTag() }
                Spacer(minLength: HV.Space.xs)
                Text(MailTimeFormat.string(for: message.createdAt))
                    .font(.hvCaption)
                    .foregroundStyle(Palette.textSecondary)
            }
            Text(message.displaySubject)
                .font(.hvSubheadline)
                .lineLimit(1)
            if let snippet = message.snippet, !snippet.isEmpty {
                Text(snippet)
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, HV.Space.xxs)
        .accessibilityElement(children: .combine)
    }
}

/// One message in full, as the person reads it in a thread.
struct MailMessageCard: View {
    /// A thread names its subject in the screen's title, so its cards do not repeat it. Held mail has no
    /// such screen: the person is deciding whether to release it, so the card carries the subject and
    /// the address it came from.
    enum Style {
        case thread
        case held
    }

    let message: MailMessage
    var style: Style = .thread
    var onOpenAttachment: (String) -> Void = { _ in }

    private var isMine: Bool { message.author.type == .owner }

    var body: some View {
        VStack(alignment: .leading, spacing: HV.Space.s) {
            header
            if message.isHiddenFromAgents { MailNotSharedTag() }
            Text(verbatim: message.text ?? "")
                .font(.hvBody)
                .foregroundStyle(Palette.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !message.attachments.isEmpty { attachments }
        }
        .padding(HV.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isMine ? Palette.blue.opacity(0.09) : Palette.surface,
            in: RoundedRectangle(cornerRadius: HV.Radius.l, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HV.Radius.l, style: .continuous)
                .strokeBorder(isMine ? Palette.blue.opacity(0.28) : Palette.border, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var header: some View {
        switch style {
        case .thread: threadHeader
        case .held: heldHeader
        }
    }

    /// Who and when on one line; when the name and the stamp do not fit together, the stamp goes under.
    private var threadHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: HV.Space.xs) {
                sender
                Spacer(minLength: HV.Space.xs)
                timestamp
            }
            VStack(alignment: .leading, spacing: 2) {
                sender
                timestamp
            }
        }
    }

    private var sender: some View {
        HStack(alignment: .firstTextBaseline, spacing: HV.Space.xs) {
            Text(message.author.label)
                .font(.hvHeadline)
                .lineLimit(2)
            if message.author.isAgent { MailAgentTag() }
        }
    }

    private var timestamp: some View {
        Text(MailTimeFormat.full(message.createdAt))
            .font(.hvCaption)
            .foregroundStyle(Palette.textSecondary)
    }

    /// The subject first, then who sent it. For held mail the sender's address is what tells the person
    /// whether to trust it, so it stands where the agent tag would.
    private var heldHeader: some View {
        VStack(alignment: .leading, spacing: HV.Space.xxs) {
            Text(message.displaySubject)
                .font(.hvHeadline)
                .foregroundStyle(Palette.textPrimary)
            VStack(alignment: .leading, spacing: 2) {
                Text(message.author.label)
                    .font(.hvSubheadline)
                    .foregroundStyle(Palette.textPrimary)
                if !message.from.isEmpty {
                    Text(message.from)
                        .font(.hvMono)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                timestamp
            }
        }
    }

    private var attachments: some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            Divider()
            ForEach(message.attachments) { attachment in
                if let slug = attachment.slug {
                    Button {
                        Haptics.tap()
                        onOpenAttachment(slug)
                    } label: {
                        Label(attachment.filename, systemImage: "paperclip")
                            .font(.hvSubheadline)
                            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .accessibilityHint("Opens it in your library")
                } else {
                    Label {
                        Text("\(attachment.filename) (no longer available)")
                    } icon: {
                        Image(systemName: "paperclip")
                    }
                    .font(.hvSubheadline)
                    .foregroundStyle(Palette.textSecondary)
                }
            }
        }
    }
}

/// The chips under the title: Inbox, Unread, Sent, Archive, Trash.
struct MailFilterBar: View {
    let selected: MailFilter
    let unreadCount: Int
    let onSelect: (MailFilter) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: HV.Space.xs) {
                ForEach(MailFilter.allCases) { filter in
                    Button {
                        Haptics.select()
                        onSelect(filter)
                    } label: {
                        HVChip(title: title(for: filter), isSelected: selected == filter)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected == filter ? .isSelected : [])
                }
            }
        }
        // The first chip lines up with the text of the rows below; the rest scroll out to the edge.
        .contentMargins(.horizontal, HV.Space.m, for: .scrollContent)
        .scrollClipDisabled()
    }

    private func title(for filter: MailFilter) -> String {
        filter == .unread && unreadCount > 0 ? "Unread \(unreadCount)" : filter.title
    }
}

/// UIKit's share sheet, for a file the app just made.
struct MailActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// A file ready to share; `Identifiable` so a sheet can show it.
struct MailSharedFile: Identifiable {
    let id = UUID()
    let url: URL
}
