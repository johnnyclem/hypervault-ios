import Foundation

// What a model on the device is told, as against what the server sent.
//
// `POST /api/chat/context` builds its system prompt for models with room to
// spare and a habit of obeying it: a recall block that says "treat it as
// established context and answer from it" and, if the excerpts fall short,
// "say what IS covered and invite a follow-up", the truth ledger's legend,
// links to pages, thumbs examples. Handed whole to a model that reads a few
// thousand tokens, that prompt did the opposite of help: asked for parts to
// build a jog wheel, the model answered about the excerpts ("it seems there is
// no memory directly related...") or repeated one back.
//
// `OnDeviceBrief` keeps what the server knows (what the person asserted, what
// they pulled onto their page, the notes that bear on this question) and says
// it in the device's own voice: a short directive that makes the question the
// job, then the notes, labelled as optional background. The server's own
// instructions about how to treat its blocks are left out on purpose.
//
// The blocks are read by the markers the server writes (lib/recall.ts,
// lib/chat/pulled.ts, lib/truth/format.ts, lib/shorthand/compact.ts,
// lib/stenographer/client.ts, lib/chat/feedback.ts), the way `ChatToolProtocol`
// reads the server's tool fences. A block this file does not know is left out;
// a prompt it knows nothing of is passed on whole, under the directive, so a
// server that changes its wording costs the model some tidiness and nothing else.

public struct OnDeviceBrief: Sendable, Equatable {
    /// The instructions for the model: the directive, then the notes (if any).
    public let system: String
    /// The directive alone, for a second try when a reply only repeated the notes.
    public let plainSystem: String
    /// What the reply can be said to rest on: the server's grounding, narrowed
    /// to what this brief carries.
    public let grounding: ChatGrounding
    /// Whether any of the person's own words are in `system`.
    public let hasNotes: Bool

    /// When the server could not be asked: no notes, and a line that says so.
    public static let offline = OnDeviceBrief(
        system: OnDevicePrompt.offlineSystem, plainSystem: OnDevicePrompt.offlineSystem, grounding: .none, hasNotes: false
    )

    /// `server` is `ChatContext.system`; `question` the person's new message;
    /// `budget` the provider's `contextBudget` in characters.
    public static func make(server: String, question: String, grounding: ChatGrounding, budget: Int) -> OnDeviceBrief {
        let directive = OnDevicePrompt.defaultInstructions
        let context = OnDeviceServerContext.parse(server)
        if context.isBlank {
            return OnDeviceBrief(system: directive, plainSystem: directive, grounding: grounding, hasNotes: false)
        }

        let room = notesRoom(budget: budget, directive: directive)
        guard let notes = OnDeviceNotes.write(from: context, question: question, room: room) else {
            return OnDeviceBrief(system: directive, plainSystem: directive, grounding: .none, hasNotes: false)
        }
        let system = directive + "\n\n" + notes.text
        return OnDeviceBrief(system: system, plainSystem: directive, grounding: notes.narrow(grounding), hasNotes: true)
    }

    /// The system prompt may use 45% of the budget (`ChatContextFitter`); the
    /// notes get what the directive leaves, up to 40%, so they are never the
    /// part that gets cut.
    static func notesRoom(budget: Int, directive: String) -> Int {
        let ceiling = Int(Double(budget) * 0.45) - directive.count - 200
        return max(0, min(ceiling, Int(Double(budget) * 0.40)))
    }
}

// MARK: Reading the server's prompt

/// The server's system prompt, taken apart by its own markers.
struct OnDeviceServerContext {
    /// One memory, page, group, file or key the server quoted.
    struct Item: Equatable {
        enum Kind: String, CaseIterable { case memory = "Memory", page = "Page", group = "Group", file = "File", key = "Key" }

        var kind: Kind
        var title: String
        var tags: [String] = []
        var summary = ""
        /// Plain lines under the header that are not a quote: when a page last changed, a group's files.
        var facts: [String] = []
        /// The quoted text, whitespace folded.
        var body = ""

        /// Everything the item says, for matching it to a question.
        var text: String { ([title] + tags + [summary] + facts + [body]).joined(separator: " ") }
    }

    /// The ledger section whole (its legend, then its lines), and the lines alone.
    var truth: (whole: String, lines: String)?
    /// The compacted-history section, without its note to the model.
    var history: String?
    /// The conversation graph's entries, one per line.
    var deep: [String] = []
    /// Things the person pulled onto their page.
    var pulled: [Item] = []
    /// What recall found for this message, best match first.
    var recalled: [Item] = []
    /// Whether any block of the server's was recognised.
    var recognized = false
    /// The prompt as it came, for when nothing in it was recognised.
    var raw = ""

    var isBlank: Bool { raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private enum Section { case none, truth, history, deep, recallIntro, pulledIntro, dropped, item }

    /// What a line at the start of a line says about where it is.
    private enum Marker {
        case section(Section)
        case item(Item)

        init?(_ line: String) {
            switch true {
            case line == "## Asserted truth (ledger)": self = .section(.truth)
            case line == "## Conversation so far (compacted)": self = .section(.history)
            case line == "## Long-horizon memory (conversation graph)": self = .section(.deep)
            case line.hasPrefix("The user keeps a private memory wiki"): self = .section(.recallIntro)
            case line.hasPrefix("The person has pulled the things below"): self = .section(.pulledIntro)
            // Page links and thumbs examples: nothing a small model can use.
            case line.hasPrefix("The user also has a HyperVault wiki of AI artifacts"),
                 line.hasPrefix("The user rates assistant replies"):
                self = .section(.dropped)
            default:
                guard let item = Item(header: line) else { return nil }
                self = .item(item)
            }
        }
    }

    static func parse(_ system: String) -> OnDeviceServerContext {
        var result = OnDeviceServerContext()
        result.raw = system
        let lines = system.components(separatedBy: "\n")

        var section = Section.none
        var introduced = Section.recallIntro  // whose items these are: recall's or the canvas's
        var held: [String] = []  // lines of a truth, history or deep section
        var draft: Item?
        var body: [String] = []
        var fence: String?  // what closes the quoted text being read

        func closeSection() {
            let text = held.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            held = []
            guard !text.isEmpty else { return }
            // Each of these opens with one paragraph of the server's own instructions.
            let paragraphs = text.components(separatedBy: "\n\n")
            switch section {
            case .truth:
                result.truth = (text, paragraphs.count > 1 ? paragraphs.dropFirst().joined(separator: "\n\n") : text)
            case .history:
                let rest = paragraphs.dropFirst().joined(separator: "\n")
                if !rest.isEmpty { result.history = rest }
            case .deep:
                result.deep = text.components(separatedBy: "\n").filter { $0.hasPrefix("- [") }
            default:
                break
            }
        }
        func closeItem() {
            guard var item = draft else { return }
            item.body = fold(body.joined(separator: " "))
            if introduced == .pulledIntro { result.pulled.append(item) } else { result.recalled.append(item) }
            draft = nil
            body = []
            fence = nil
        }

        /// Whether the next non-blank line from `from` starts a block (or there is none).
        func endsHere(after from: Int) -> Bool {
            guard let next = lines[from...].first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return true }
            return Marker(next) != nil
        }
        /// Backtick fences are made longer than anything inside them, so the first one closes. Recall's are not.
        func closes(_ fence: String, at line: String, index: Int) -> Bool {
            line == fence && (fence != "\"\"\"" || endsHere(after: index))
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1

            if let closing = fence {
                // Inside quoted text nothing is a marker. The recall block's quotes are not escaped, so its `"""`
                // closes the quote only when what follows is another block or the end.
                if closes(closing, at: line, index: index) {
                    fence = nil
                } else {
                    body.append(line)
                }
                continue
            }

            if let marker = Marker(line) {
                closeSection()
                closeItem()
                result.recognized = true
                switch marker {
                case .section(let next):
                    section = next
                    if next == .recallIntro || next == .pulledIntro { introduced = next }
                case .item(let item):
                    section = .item
                    draft = item
                }
                continue
            }

            switch section {
            case .truth, .history, .deep:
                held.append(line)
            case .item:
                if line == "\"\"\"" || (line.count >= 3 && line.allSatisfy({ $0 == "`" })) {
                    fence = line
                } else {
                    draft?.read(line: line)
                }
            case .none, .recallIntro, .pulledIntro, .dropped:
                break
            }
        }
        closeSection()
        closeItem()
        return result
    }

    /// Whitespace folded to single spaces, the server's omission mark made plain.
    static func fold(_ text: String) -> String {
        text.replacingOccurrences(of: "[…]", with: "…")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

extension OnDeviceServerContext.Item {
    /// `### Memory: "Title" [tag, tag]`. Recall writes the title as it is, the canvas JSON-quoted.
    init?(header line: String) {
        guard let kind = Kind.allCases.first(where: { line.hasPrefix("### \($0.rawValue): ") }) else { return nil }
        var rest = String(line.dropFirst("### \(kind.rawValue): ".count)).trimmingCharacters(in: .whitespaces)
        var tags: [String] = []
        if rest.hasSuffix("]"), let open = rest.range(of: "\" [", options: .backwards) {
            tags = rest[open.upperBound...].dropLast().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            rest = String(rest[..<open.lowerBound]) + "\""
        }
        if rest.count >= 2, rest.hasPrefix("\""), rest.hasSuffix("\"") { rest = String(rest.dropFirst().dropLast()) }
        self.init(kind: kind, title: rest.replacingOccurrences(of: "\\\"", with: "\""), tags: tags)
    }

    /// A line under the header that is not part of the quoted text.
    mutating func read(line: String) {
        let text = line.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return }
        if text.hasPrefix("Summary:") {
            summary = OnDeviceServerContext.fold(String(text.dropFirst("Summary:".count)))
        } else if text.hasPrefix("Content (excerpted") || text.hasPrefix("Text of the page (") || text.hasPrefix("Start of ") {
            return  // the label before a quote
        } else {
            facts.append(OnDeviceServerContext.fold(text))
        }
    }
}

// MARK: Writing the notes

/// The notes a brief carries, and what they rest on.
struct OnDeviceNotes {
    let text: String
    private let memories: Set<String>
    private let pulled: Set<String>
    private let deep: Bool
    private let truth: Bool
    private let history: Bool
    private let narrowing: Bool

    /// How many recalled notes a model reads, however much room there is.
    private static let maxRecalled = 3

    /// Writes what fits in `room` characters, or nil when none of the server's blocks is worth the model's attention.
    static func write(from context: OnDeviceServerContext, question: String, room: Int) -> OnDeviceNotes? {
        guard room >= 200 else { return nil }

        // Nothing here was recognised: pass the prompt on whole rather than say nothing.
        guard context.recognized else {
            let kept = cut(OnDeviceServerContext.fold(context.raw), to: room - heading.count)
            return OnDeviceNotes(text: heading + "\n" + kept, memories: [], pulled: [], deep: false, truth: false, history: false, narrowing: false)
        }

        var blocks: [String] = []
        var left = room - heading.count
        /// What a block may use: its share of what is left, less its label.
        func allowance(_ label: String, share: Double) -> Int { Int(Double(left) * share) - label.count - 2 }
        func add(_ label: String, _ text: String, share: Double = 1) -> Bool {
            let allowed = allowance(label, share: share)
            guard allowed >= 80, !text.isEmpty else { return false }
            let block = label + "\n" + cut(text, to: allowed)
            blocks.append(block)
            left -= block.count + 2
            return true
        }

        var usedTruth = false
        if let truth = context.truth {
            // The ledger's legend is worth having when it fits; the facts are worth having when it does not.
            let label = "Facts the person has asserted (prefer these to anything else):"
            usedTruth = add(label, truth.whole.count <= allowance(label, share: 0.5) ? truth.whole : truth.lines, share: 0.5)
        }

        var pulledTitles: Set<String> = []
        if !context.pulled.isEmpty {
            let each = max(200, left / 2 / context.pulled.count)
            let lines = context.pulled.map { "- " + describe($0, limit: each) }
            if add("What the person has open on their page:", lines.joined(separator: "\n"), share: 0.5) {
                pulledTitles = Set(context.pulled.map { key($0.title) })
            }
        }

        var usedDeep = false
        if !context.deep.isEmpty {
            usedDeep = add("From their other chats:", context.deep.prefix(3).map { cut($0, to: 220) }.joined(separator: "\n"), share: 0.25)
        }

        var usedHistory = false
        if let history = context.history {
            usedHistory = add("Earlier in this conversation:", history, share: 0.25)
        }

        var memoryTitles: Set<String> = []
        let related = related(context.recalled, to: question)
        if !related.isEmpty {
            let count = min(related.count, left >= 1_800 ? maxRecalled : 2)
            let each = max(300, left / count)
            let lines = related.prefix(count).map { "- " + describe($0, limit: each) }
            if add("Notes that may be related (background only):", lines.joined(separator: "\n")) {
                memoryTitles = Set(related.prefix(count).map { key($0.title) })
            }
        }

        guard !blocks.isEmpty else { return nil }
        return OnDeviceNotes(
            text: heading + "\n\n" + blocks.joined(separator: "\n\n"),
            memories: memoryTitles, pulled: pulledTitles, deep: usedDeep, truth: usedTruth, history: usedHistory, narrowing: true
        )
    }

    static let heading = "Notes from the person's vault. Background only: they may have nothing to do with the message."

    /// What the reply can be said to rest on when only these notes were given.
    func narrow(_ grounding: ChatGrounding) -> ChatGrounding {
        guard narrowing else { return grounding }
        var kept = grounding
        kept.pages = []  // the model is not given page links
        kept.memories = grounding.memories.filter { memories.contains(Self.key($0)) }
        kept.pulled = grounding.pulled.filter { pulled.contains(Self.key($0.title)) }
        if !deep { kept.deepMemory = [] }
        if !truth { kept.truth = nil }
        if !history { kept.smartContext = false }
        return kept
    }

    // MARK: Which recalled notes are worth reading

    /// The recalled notes a small model should see, best match first. The
    /// server sends its nearest neighbours whether or not they are near, and a
    /// chat that was saved with a bad reply comes back too. So: no note that
    /// holds a saved non-answer, and, once the question has enough words in it
    /// to tell, only notes that share several with it. One shared word is not
    /// enough: "quarter" is in a note about hiring and in a question about the
    /// size of a jog wheel. (A short question cannot be told apart by its words,
    /// so there the server's ranking is trusted.)
    static func related(_ recalled: [OnDeviceServerContext.Item], to question: String) -> [OnDeviceServerContext.Item] {
        let wanted = Set(MemoryRecallScorer.keywords(question))
        let enoughToTell = wanted.count >= 5
        return recalled.filter { item in
            if OnDeviceReplyScreen.holdsSavedNonAnswer(item.body) { return false }
            guard enoughToTell else { return true }
            let heading = Set(MemoryRecallScorer.keywords(([item.title, item.summary] + item.tags).joined(separator: " "))).intersection(wanted).count
            let body = Set(MemoryRecallScorer.keywords(String(item.body.prefix(4_000)))).intersection(wanted).count
            return heading >= 2 || (heading >= 1 && body >= 2) || body >= 3
        }
    }

    // MARK: Small helpers

    static func key(_ title: String) -> String { OnDeviceServerContext.fold(title).lowercased() }

    static func describe(_ item: OnDeviceServerContext.Item, limit: Int) -> String {
        var head = item.kind == .memory ? "\"\(item.title)\"" : "\(item.kind.rawValue.lowercased()) \"\(item.title)\""
        if !item.tags.isEmpty { head += " [\(item.tags.prefix(5).joined(separator: ", "))]" }
        let said = ([item.summary] + item.facts + [item.body]).filter { !$0.isEmpty }.joined(separator: " ")
        return cut(said.isEmpty ? head : head + ": " + said, to: limit)
    }

    /// At most `limit` characters, cut at a word.
    static func cut(_ text: String, to limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard text.count > limit else { return text }
        let head = String(text.prefix(max(limit - 2, 0)))
        if let space = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: space) > limit * 6 / 10 {
            return String(head[..<space]) + " …"
        }
        return head + " …"
    }
}

// MARK: Reading what the model wrote

/// A small model told to answer "from the excerpts" does one of two things
/// when they do not fit the question: it says it found nothing, or it hands the
/// excerpt back (`Memory: "..." [tags] Summary: ...`). Neither is an answer,
/// and both are said in the first words, so they are caught there, before the
/// person has read them, and the question is asked again without the notes.
public enum OnDeviceReplyScreen {
    public enum Verdict: Sendable, Equatable {
        /// Too little written to tell.
        case undecided
        case fine
        /// A non-answer or a copy of the notes.
        case unusable
    }

    /// How much of a reply is held back (when it has to be screened) before it is shown.
    static let hold = 120

    /// How a reply opens when it is the notes handed back.
    private static let echoes = [
        "memory:", "summary:", "content (excerpted", "you:", "assistant:", "person:",
        "notes from the person's vault", "the user keeps a private memory", "the person has pulled the things",
    ]

    /// What a model says when it answers about the notes instead of the question.
    private static let nonAnswers = [
        "based on the excerpts", "excerpts provided", "the excerpts don't", "the excerpts do not", "memory excerpts",
        "no memory directly", "no memories directly", "no relevant memor", "don't have any memories", "do not have any memories",
    ]

    public static func check(_ reply: String, isFinal: Bool) -> Verdict {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return isFinal ? .fine : .undecided }
        if isUnusable(text) { return .unusable }
        return isFinal || text.count >= hold ? .fine : .undecided
    }

    /// Whether `text` (a reply, or a saved one in a thread's history) is a non-answer or a copy of the notes.
    public static func isUnusable(_ text: String) -> Bool {
        let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return echoes.contains { lowered.hasPrefix($0) } || isNonAnswer(String(lowered.prefix(400)))
    }

    /// Whether `text` says, anywhere, what a non-answer says.
    static func isNonAnswer(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return nonAnswers.contains { lowered.contains($0) }
    }

    /// Whether a saved note is, or holds, a reply that was a non-answer: a reply kept as a memory, or an
    /// `Assistant:` turn of a chat kept as one. Taken into a prompt, it teaches the model to answer the same way.
    /// A note that only talks about excerpts (design notes for this very app) is not one.
    static func holdsSavedNonAnswer(_ note: String) -> Bool {
        if isNonAnswer(String(note.prefix(400))) { return true }
        let lowered = note.lowercased()
        var from = lowered.startIndex
        while let label = lowered.range(of: "assistant:", range: from..<lowered.endIndex) {
            if isNonAnswer(String(lowered[label.upperBound...].prefix(400))) { return true }
            from = label.upperBound
        }
        return false
    }
}
