import HyperVaultKit
import SwiftUI
import UIKit

/// What the thread is made of: a message, or a run of tool steps folded into one line.
enum ChatThreadItem: Identifiable {
    case message(ChatThreadRow)
    case tools([ChatThreadRow])

    var id: String {
        switch self {
        case .message(let row): return row.id
        case .tools(let rows): return "tools-\(rows.first?.id ?? "")"
        }
    }

    /// Consecutive tool rows become one collapsible group.
    static func items(from rows: [ChatThreadRow]) -> [ChatThreadItem] {
        var items: [ChatThreadItem] = []
        var group: [ChatThreadRow] = []
        func flush() {
            if !group.isEmpty { items.append(.tools(group)) }
            group = []
        }
        for row in rows {
            if row.kind == .tool {
                group.append(row)
            } else {
                flush()
                items.append(.message(row))
            }
        }
        flush()
        return items
    }
}

// MARK: Person's message

struct ChatUserBubble: View {
    let row: ChatThreadRow
    var onRetry: () -> Void
    var onEdit: () -> Void

    @State private var expanded = false
    private static let collapsedLimit = 1_200

    private var isLong: Bool { row.text.count > Self.collapsedLimit }

    var body: some View {
        VStack(alignment: .trailing, spacing: HV.Space.xs) {
            HStack(spacing: 0) {
                Spacer(minLength: 56)
                bubble
            }
            if case .failed(let message) = row.state {
                ChatFailedNote(message: message, onRetry: onRetry, onEdit: onEdit)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            Text(row.text)
                .font(.hvBody)
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
                .lineLimit(isLong && !expanded ? 14 : nil)
                .textSelection(.enabled)
            if isLong {
                Button(expanded ? "Show less" : "Show more") {
                    HV.Motion.animate { expanded.toggle() }
                }
                .font(.hvCaption.weight(.semibold))
                .foregroundStyle(.white)
                .frame(minHeight: 44, alignment: .leading)
            }
        }
        .padding(.horizontal, HV.Space.m)
        .padding(.vertical, HV.Space.s)
        // `action` is the one flat fill white text reads on at body size in both looks (5.17:1), and the words
        // the person just wrote stay at full strength while the reply is on its way: the line under the bubble
        // already says the model is working.
        .background(Palette.action, in: RoundedRectangle(cornerRadius: HV.Radius.l, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You said: \(row.text)")
        .accessibilityValue(row.state == .sending ? "Sending" : "")
    }
}

private struct ChatFailedNote: View {
    let message: String
    var onRetry: () -> Void
    var onEdit: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: HV.Space.xxs) {
            Text(message)
                .font(.hvFootnote)
                .foregroundStyle(Palette.danger)
                .multilineTextAlignment(.trailing)
            // The ghost style has no side padding, so the gap between the two words is set here.
            HStack(spacing: HV.Space.m) {
                Button("Edit", action: onEdit).buttonStyle(.hvGhost)
                Button("Try again", action: onRetry).buttonStyle(.hvGhost)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: Reply

struct ChatAssistantMessageView: View {
    let row: ChatThreadRow
    let isLast: Bool
    let model: ChatConversationModel
    var speech: ChatSpeechController
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: HV.Space.s) {
            if row.state == .streaming && row.text.isEmpty {
                ChatThinkingDots()
            } else {
                ChatMarkdownView(text: row.text)
            }

            if row.truncated {
                Label(HVCopy.replyCutShortLine, systemImage: "scissors").hvRowLabel()
                    .font(.hvFootnote)
                    .foregroundStyle(Palette.warning)
            }

            if let selection = row.toolSelection, isLast {
                ChatToolPickerView(selection: selection, disabled: model.isWorking) { option in
                    model.choose(option, intent: selection.intent)
                }
            }

            ChatGroundingView(grounding: row.grounding) { slug in
                app.router.push(.artifact(slug: slug))
            }

            stateNote

            if row.state != .streaming && !row.text.isEmpty {
                ChatReplyActions(row: row, model: model, speech: speech)
            }

            if let note = model.keptNotes[row.id] {
                ChatKeptNoteView(note: note) { slug in app.router.push(.artifact(slug: slug)) }
            }

            if let name = ChatModelNames.display(row.model), row.state != .streaming {
                Text(name)
                    .font(.hvCaption)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var stateNote: some View {
        switch row.state {
        case .waitingToSync:
            Label("Saved on this iPhone. It will go to your vault when you're online.", systemImage: "icloud.slash").hvRowLabel()
                .font(.hvFootnote)
                .foregroundStyle(Palette.textSecondary)
        case .notSaved(let message):
            Label("This reply is only on this iPhone. \(message)", systemImage: "exclamationmark.triangle").hvRowLabel()
                .font(.hvFootnote)
                .foregroundStyle(Palette.warning)
        default:
            EmptyView()
        }
    }
}

/// Copy, keep, save as a memory, thumbs and read aloud. Each is a 44-point target.
struct ChatReplyActions: View {
    let row: ChatThreadRow
    let model: ChatConversationModel
    var speech: ChatSpeechController
    @Environment(AppModel.self) private var app
    @State private var copied = false
    @State private var keeping = false
    @State private var savingMemory = false
    @ScaledMetric(relativeTo: .body) private var glyphSize: CGFloat = 16

    var body: some View {
        HStack(spacing: 0) {
            action(copied ? HVSymbol.copied : HVSymbol.copy, label: copied ? "Copied" : "Copy reply", tint: copied ? Palette.mint : nil) {
                UIPasteboard.general.string = row.text
                Haptics.tap()
                copied = true
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(HV.Motion.copiedHold * 1_000_000_000))
                    copied = false
                }
            }
            action(keeping ? "hourglass" : HVSymbol.keep, label: "Keep this reply", tint: nil) {
                guard !keeping else { return }
                keeping = true
                Task {
                    defer { keeping = false }
                    do {
                        try await model.keep(row)
                        Haptics.success()
                    } catch {
                        app.toasts.show(error: error)
                    }
                }
            }
            action(savingMemory ? "hourglass" : HVSymbol.saveMemory, label: "Save as memory", tint: nil) {
                saveAsMemory()
            }
            if row.serverID != nil {
                action(row.feedback == .up ? "hand.thumbsup.fill" : "hand.thumbsup", label: "Good reply", tint: row.feedback == .up ? Palette.mint : nil, selected: row.feedback == .up) {
                    rate(.up)
                }
                action(row.feedback == .down ? "hand.thumbsdown.fill" : "hand.thumbsdown", label: "Bad reply", tint: row.feedback == .down ? Palette.danger : nil, selected: row.feedback == .down) {
                    rate(.down)
                }
            }
            action(
                speech.isSpeaking(row.id) ? "stop.circle.fill" : HVSymbol.speak,
                label: speech.isSpeaking(row.id) ? "Stop reading" : "Read aloud",
                tint: speech.isSpeaking(row.id) ? Color.accentColor : nil
            ) {
                speech.toggle(id: row.id, text: row.text)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, -HV.Space.xs)
    }

    private func saveAsMemory() {
        guard !savingMemory else { return }
        savingMemory = true
        Task {
            defer { savingMemory = false }
            do {
                let line = try await model.saveAsMemory(row)
                app.toasts.success(line)
            } catch {
                app.toasts.show(error: error)
            }
        }
    }

    private func rate(_ value: ChatFeedback) {
        Haptics.select()
        Task {
            do { try await model.rate(row, value) } catch { app.toasts.show(error: error) }
        }
    }

    private func action(_ symbol: String, label: String, tint: Color?, selected: Bool = false, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol)
                .font(.system(size: glyphSize, weight: .regular))
                .foregroundStyle(tint ?? Palette.textSecondary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ChatKeptNoteView: View {
    let note: ChatKeptNote
    var onOpen: (String) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: HV.Space.xs) {
                    message
                    HStack(spacing: HV.Space.xs) { actions }
                }
                .padding(.vertical, HV.Space.xs)
            } else {
                // The 44pt Open button sets the height of the row and the words are centred on it, so a two-line
                // note has the same room above and below. The words carry their own padding for the sizes at which
                // they grow taller than the button.
                HStack(alignment: .center, spacing: HV.Space.xs) {
                    message.padding(.vertical, HV.Space.xs)
                    Spacer(minLength: HV.Space.xs)
                    actions
                }
            }
        }
        .padding(.horizontal, HV.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: HV.Radius.card, style: .continuous))
    }

    private var message: some View {
        HStack(alignment: .firstTextBaseline, spacing: HV.Space.xs) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.mint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: HV.Space.xxs) {
                Text(note.line).font(.hvFootnote.weight(.medium))
                if note.isPrivate {
                    Text(HVCopy.onlyYouLine).font(.hvCaption).foregroundStyle(Palette.textSecondary)
                }
            }
        }
    }

    @ViewBuilder private var actions: some View {
        if let slug = note.slug {
            Button("Open") { onOpen(slug) }.buttonStyle(.hvGhost)
        }
        if let url = note.url {
            ShareLink(item: url) {
                Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Share link")
        }
    }
}

// MARK: Where it came from

/// The sources a reply leaned on, as chips: recalled pages (they open), recalled
/// memories, the conversation graph, the truth ledger and what was on the canvas.
struct ChatGroundingView: View {
    let grounding: ChatGrounding
    var onOpenPage: (String) -> Void
    @State private var showAll = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .caption) private var glyphSize: CGFloat = 11

    private enum Chip: Identifiable {
        case page(ChatRecalledPage)
        case memory(String)
        case graph(String)

        var id: String {
            switch self {
            case .page(let page): return "p-\(page.slug)"
            case .memory(let title): return "m-\(title)"
            case .graph(let label): return "g-\(label)"
            }
        }
    }

    private var chips: [Chip] {
        grounding.pages.map(Chip.page) + grounding.memories.map(Chip.memory) + grounding.deepMemory.map(Chip.graph)
    }

    var body: some View {
        if !grounding.isEmpty {
            VStack(alignment: .leading, spacing: HV.Space.xs) {
                if !chips.isEmpty {
                    HVSectionHeader(title: "From your memory")
                    ChatFlowLayout(spacing: HV.Space.xs) {
                        ForEach(showAll ? chips : Array(chips.prefix(5))) { chip in
                            chipView(chip)
                        }
                        if !showAll && chips.count > 5 {
                            Button("+\(chips.count - 5) more") { HV.Motion.animate(.default) { showAll = true } }
                                .font(.hvCaption.weight(.medium))
                                .buttonStyle(.plain)
                                .foregroundStyle(Color.accentColor)
                                .frame(minHeight: 44)
                        }
                    }
                }
                if !grounding.pulled.isEmpty {
                    Text(HVCopy.usingLine(grounding.pulled.map(\.title).joined(separator: ", ")))
                        .font(.hvCaption)
                        .foregroundStyle(Palette.textSecondary)
                }
                if let footnote = grounding.truth?.footnote {
                    Label(footnote, systemImage: "checkmark.seal").hvRowLabel()
                        .font(.hvCaption)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder private func chipView(_ chip: Chip) -> some View {
        switch chip {
        case .page(let page):
            Button { onOpenPage(page.slug) } label: {
                sourceChip(page.title, symbol: "doc.text")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Page: \(page.title)")
            .accessibilityHint("Opens the page")
        case .memory(let title):
            sourceChip(title, symbol: HVSymbol.memory)
                .accessibilityLabel("Memory: \(title)")
        case .graph(let label):
            sourceChip(label, symbol: "point.3.connected.trianglepath.dotted")
                .accessibilityLabel("From your conversations: \(label)")
        }
    }

    /// One source. At large text sizes the title wraps over a few lines and the chip takes the whole
    /// width, so nothing the reply leaned on is cut to an ellipsis.
    private func sourceChip(_ title: String, symbol: String) -> some View {
        let large = typeSize.isAccessibilitySize
        return HStack(alignment: large ? .firstTextBaseline : .center, spacing: HV.Space.hair) {
            HVIcon(symbol).font(.system(size: glyphSize, weight: .semibold))
            Text(title)
                .lineLimit(large ? 4 : 1)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: large)
        }
        .font(.hvCaption.weight(.medium))
        .foregroundStyle(Palette.textSecondary)
        .padding(.horizontal, HV.Space.s)
        .padding(.vertical, 6)
        // The flow layout offers the chip the full width, which a greedy frame would take: only the
        // large-text chip spreads, the rest hug their words and wrap side by side.
        .frame(maxWidth: large ? .infinity : nil, alignment: .leading)
        .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: large ? HV.Radius.card : 100, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: large ? HV.Radius.card : 100, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
    }
}

// MARK: Tools

/// A run of tool steps, folded into one line that opens into the transcript.
struct ChatToolGroupView: View {
    let steps: [ChatToolTurn]
    @State private var open = false

    init(rows: [ChatThreadRow]) {
        steps = rows.compactMap(\.toolTurn)
    }

    init(steps: [ChatToolTurn]) {
        self.steps = steps
    }

    private var failures: Int { steps.filter { !$0.ok }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                HV.Motion.animate { open.toggle() }
            } label: {
                HStack(spacing: HV.Space.xs) {
                    HVIcon("wrench.and.screwdriver").font(.hvFootnote.weight(.semibold))
                    Text(steps.count == 1 ? "Used a tool" : "Used \(steps.count) tools")
                        .font(.hvFootnote.weight(.medium))
                    if failures > 0 {
                        HVTag(text: failures == 1 ? "1 failed" : "\(failures) failed", tint: Palette.danger)
                    }
                    Spacer(minLength: 0)
                    HVIcon(HVSymbol.open)
                        .font(.hvCaption.weight(.bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .foregroundStyle(Palette.textSecondary)
                .padding(.horizontal, HV.Space.s)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(steps.count == 1 ? "Used a tool" : "Used \(steps.count) tools")
            .accessibilityValue(open ? "Expanded" : "Collapsed")

            if open {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(steps) { step in
                        ChatToolStepView(step: step)
                    }
                }
                .padding(.bottom, HV.Space.xs)
            }
        }
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: HV.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: HV.Radius.card, style: .continuous).strokeBorder(Palette.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ChatToolStepView: View {
    let step: ChatToolTurn
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: HV.Space.xxs) {
            Button {
                HV.Motion.animate { open.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: HV.Space.xs) {
                    Image(systemName: step.ok ? "checkmark.circle" : "xmark.circle")
                        .foregroundStyle(step.ok ? Palette.mint : Palette.danger)
                    Text(step.summary)
                        .font(.hvFootnote)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(open ? nil : 2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    if let tier = step.tierLabel {
                        HVTag(text: tier, tint: step.ok ? Palette.textSecondary : Palette.danger)
                    }
                }
                .padding(.horizontal, HV.Space.s)
                .frame(minHeight: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                detail.padding(.horizontal, HV.Space.s)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let refinement = step.refinement {
            VStack(alignment: .leading, spacing: HV.Space.xxs) {
                Text(refinement.question).font(.hvFootnote)
                ForEach(Array(refinement.options.enumerated()), id: \.offset) { _, option in
                    Text("\u{2022} \(option.label)").font(.hvCaption).foregroundStyle(Palette.textSecondary)
                }
            }
        } else if let text = step.detail, !text.isEmpty {
            Text(text)
                .font(.hvMono)
                .foregroundStyle(Palette.textSecondary)
                .textSelection(.enabled)
                .lineLimit(14)
                .padding(HV.Space.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Inside the tool group's card, whose last step ends 8 above its edge: the card's radius less that gap.
                .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: HV.Radius.inner(of: HV.Radius.card, inset: HV.Space.xs), style: .continuous))
        } else {
            Text("No output.").font(.hvCaption).foregroundStyle(Palette.textTertiary)
        }
    }
}

/// The model could not pick a tool; the person does.
struct ChatToolPickerView: View {
    let selection: ChatToolSelection
    let disabled: Bool
    var onPick: (ChatToolSelection.Option) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: HV.Space.xs) {
            ForEach(selection.options.prefix(12)) { option in
                Button { onPick(option) } label: {
                    HStack(spacing: HV.Space.xs) {
                        HVIcon("wrench.and.screwdriver").font(.hvFootnote)
                        Text(option.label).font(.hvFootnote.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, HV.Space.s)
                    .frame(minHeight: 44)
                    .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: HV.Radius.card, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(disabled)
            }
        }
    }
}

// MARK: Waiting

/// Three dots that breathe. Still when the person asks for less motion.
struct ChatThinkingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                dots(phase: 0.6)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
                    dots(phase: context.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .accessibilityLabel(HVCopy.thinkingLine)
    }

    private func dots(phase: Double) -> some View {
        HStack(spacing: HV.Space.xxs) {
            ForEach(0..<3, id: \.self) { index in
                let wave = (sin(phase * 3.2 - Double(index) * 0.7) + 1) / 2
                Circle()
                    .fill(Palette.textTertiary)
                    .frame(width: 7, height: 7)
                    .opacity(0.35 + 0.65 * wave)
                    .scaleEffect(0.85 + 0.25 * wave)
            }
        }
        .frame(height: 24, alignment: .leading)
    }
}

/// The wait for a model that does not stream: it can take two minutes, so the
/// screen says what is going on and offers a way out.
struct ChatThinkingBubble: View {
    let startedAt: Date
    let usesRecall: Bool
    var onStop: () -> Void

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(startedAt)))
            VStack(alignment: .leading, spacing: HV.Space.s) {
                HStack(spacing: HV.Space.s) {
                    ChatThinkingDots()
                    Text(Self.line(seconds: seconds, usesRecall: usesRecall))
                        .font(.hvCallout)
                        .foregroundStyle(Palette.textSecondary)
                        .contentTransition(.opacity)
                        .hvAnimation(.easeOut(duration: 0.25), value: Self.line(seconds: seconds, usesRecall: usesRecall))
                    Spacer(minLength: 0)
                    if seconds >= 3 {
                        Text(Self.clock(seconds))
                            .font(.hvCaption.monospacedDigit())
                            .foregroundStyle(Palette.textTertiary)
                    }
                }
                if seconds >= 8 {
                    Button(action: onStop) {
                        Label("Stop", systemImage: "stop.fill").font(.hvFootnote.weight(.semibold))
                    }
                    .buttonStyle(.hvGhost)
                    .frame(minHeight: 44)
                    .transition(.opacity)
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    static func line(seconds: Int, usesRecall: Bool) -> String {
        switch seconds {
        case ..<6: return HVCopy.thinkingLine
        case 6..<20: return usesRecall ? "Looking through your memories..." : "Working on it..."
        case 20..<50: return "Still going. Some models take a minute."
        default: return "This one is slow. It can take up to two minutes."
        }
    }

    static func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
