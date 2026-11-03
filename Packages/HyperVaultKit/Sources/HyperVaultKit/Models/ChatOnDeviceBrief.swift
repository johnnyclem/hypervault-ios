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
// `OnDeviceBrief` keeps what the server knows (what the person recorded, what
// they pulled onto their page, the notes that bear on this question) and says
// it in the device's own voice: a short directive that makes the question the
// job, then the notes, labelled as optional background. The server's own
// instructions about how to treat its blocks are left out on purpose.
//
// The blocks are read by the markers the server writes (lib/recall.ts,
// lib/chat/pulled.ts, lib/truth/format.ts, lib/shorthand/compact.ts,
// lib/stenographer/client.ts, lib/chat/feedback.ts), the way `ChatToolProtocol`
// reads the server's tool fences, and only in the shapes the server writes
// them: an item ends at its blank line, the ledger is two paragraphs, a quote
// ends at its fence. Anything else is not carried over. A prompt with none of
// the server's markers in it gives the model no notes at all, never the raw
// prompt, so a server that rewords itself costs the model its memory and not
// its sense: the directive still says to answer the question.

public struct OnDeviceBrief: Sendable, Equatable {
    /// The instructions for the model: the directive, then the notes (if any).
    public let system: String
    /// For a second try, when a reply only repeated the notes: the same, less
    /// the notes that recall guessed at. What the person pulled onto their page
    /// and what they recorded stay, because those are what they are asking about.
    public let retrySystem: String
    /// What the reply can be said to rest on: the server's grounding, narrowed
    /// to what `system` carries.
    public let grounding: ChatGrounding
    /// The same for `retrySystem`.
    public let retryGrounding: ChatGrounding
    /// Whether any of the person's own words are in `system`.
    public let hasNotes: Bool

    /// When the server could not be asked: no notes, and a line that says so.
    public static let offline = OnDeviceBrief(
        system: OnDevicePrompt.offlineSystem, retrySystem: OnDevicePrompt.offlineSystem,
        grounding: .none, retryGrounding: .none, hasNotes: false
    )

    /// `server` is `ChatContext.system`; `question` the person's new message;
    /// `budget` the provider's `contextBudget` in characters.
    public static func make(server: String, question: String, grounding: ChatGrounding, budget: Int) -> OnDeviceBrief {
        let directive = OnDevicePrompt.defaultInstructions
        let context = OnDeviceServerContext.parse(server)
        if context.isBlank {
            return OnDeviceBrief(system: directive, retrySystem: directive, grounding: grounding, retryGrounding: grounding, hasNotes: false)
        }

        let room = notesRoom(budget: budget, directive: directive)
        guard let notes = OnDeviceNotes.write(from: context, question: question, room: room) else {
            return OnDeviceBrief(system: directive, retrySystem: directive, grounding: .none, retryGrounding: .none, hasNotes: false)
        }

        var withoutGuesses = context
        withoutGuesses.recalled = []
        withoutGuesses.deep = []
        let retry = OnDeviceNotes.write(from: withoutGuesses, question: question, room: room)
        return OnDeviceBrief(
            system: directive + "\n\n" + notes.text,
            retrySystem: retry.map { directive + "\n\n" + $0.text } ?? directive,
            grounding: notes.narrow(grounding),
            retryGrounding: retry?.narrow(grounding) ?? .none,
            hasNotes: true
        )
    }

    /// The system prompt may use 45% of the budget (`ChatContextFitter`); the
    /// notes get what the directive leaves, up to 40%, so they are never the
    /// part that gets cut. (Below about 2,600 characters, a window of under
    /// 1,500 tokens, the directive alone outgrows that share and the fitter cuts
    /// its tail; its first lines, which say what the job is, are the ones that
    /// stay. No note fits there.)
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
    var isBlank = true

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
        result.isBlank = system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Any line ending. A CRLF is one Character in Swift and does not split on "\n".
        let lines = system.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }).map(String.init)

        var section = Section.none
        var introduced = Section.recallIntro  // whose items these are, when nothing else says
        var held: [String] = []  // lines of a truth, history or deep section
        var draft: Item?
        var body: [String] = []
        var fence: String?  // what closes the quoted text being read
        var opened: String?  // what opened it
        var quoted = false  // the item's quote has been read: nothing after it is the item's

        func closeSection() {
            let text = held.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            held = []
            guard !text.isEmpty else { return }
            // Each of these opens with one paragraph of the server's own instructions.
            let paragraphs = text.components(separatedBy: "\n\n")
            switch section {
            case .truth:
                // The legend, then the lines. A paragraph after those is not the ledger's.
                result.truth = paragraphs.count > 1 ? (paragraphs.prefix(2).joined(separator: "\n\n"), paragraphs[1]) : (paragraphs[0], paragraphs[0])
            case .history:
                // After the note to the model, each part is `### label` and its text.
                let rest = paragraphs.dropFirst().filter { $0.hasPrefix("### ") }.joined(separator: "\n")
                if !rest.isEmpty { result.history = rest }
            case .deep:
                result.deep = text.components(separatedBy: "\n").filter { $0.hasPrefix("- [") }
            default:
                break
            }
        }
        func closeItem() {
            defer {
                draft = nil
                body = []
                fence = nil
                opened = nil
                quoted = false
            }
            guard var item = draft else { return }
            item.body = fold(body.joined(separator: " "))
            // The canvas quotes in backticks and JSON-quotes the title; recall quotes in `"""` and does not.
            let backticks = opened?.hasPrefix("`") == true
            if item.kind != .memory || backticks || (opened == nil && introduced == .pulledIntro) {
                item.title = unescapedJSON(item.title)
                result.pulled.append(item)
            } else {
                result.recalled.append(item)
            }
        }
        /// Whether a block ends at the line before `from`: the server follows every block with a blank line or the
        /// next block, or it is the last. (A `"""` inside a memory's text has more text right after it.)
        func endsHere(after from: Int) -> Bool {
            guard from < lines.count else { return true }
            return lines[from].trimmingCharacters(in: .whitespaces).isEmpty || Marker(lines[from]) != nil
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
                // Inside quoted text nothing is a marker.
                if closes(closing, at: line, index: index) {
                    fence = nil
                    quoted = true
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
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    closeItem()  // the server puts a blank line between blocks
                    section = .none
                } else if quoted {
                    break
                } else if line == "\"\"\"" || (line.count >= 3 && line.allSatisfy({ $0 == "`" })) {
                    fence = line
                    opened = line
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

    /// A title the canvas wrote with `JSON.stringify`, without its quotes: `C:\\notes` is `C:\notes`.
    static func unescapedJSON(_ text: String) -> String {
        guard let data = "\"\(text)\"".data(using: .utf8), let decoded = try? JSONDecoder().decode(String.self, from: data) else { return text }
        return decoded
    }
}

extension OnDeviceServerContext.Item {
    /// `### Memory: "Title" [tag, tag]`. The title is as the server wrote it (see `unescapedJSON`).
    init?(header line: String) {
        guard let kind = Kind.allCases.first(where: { line.hasPrefix("### \($0.rawValue): ") }) else { return nil }
        var rest = String(line.dropFirst("### \(kind.rawValue): ".count)).trimmingCharacters(in: .whitespaces)
        var tags: [String] = []
        if rest.hasSuffix("]"), let open = rest.range(of: "\" [", options: .backwards) {
            tags = rest[open.upperBound...].dropLast().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            rest = String(rest[..<open.lowerBound]) + "\""
        }
        if rest.count >= 2, rest.hasPrefix("\""), rest.hasSuffix("\"") { rest = String(rest.dropFirst().dropLast()) }
        self.init(kind: kind, title: rest, tags: tags)
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
    private let deep: Int
    private let truth: Bool
    private let history: Bool

    static let heading = "Notes from the person's vault. Background only: they may have nothing to do with the message."
    static let relatedLabel = "Notes that may be related (background only):"
    static let pulledLabel = "What the person has open on their page:"
    static let deepLabel = "From their other chats:"
    static let historyLabel = "Earlier in this conversation:"
    static let truthLabel = "Things the person has recorded (use them only if they bear on the message):"
    private static let truthStem = "Things the person has recorded"

    /// How a reply opens when it is the brief handed back (see `OnDeviceReplyScreen`).
    static let openings = ["Notes from the person's vault", relatedLabel, pulledLabel, deepLabel, historyLabel, truthStem]

    /// A window this big (a model on the person's own network) is read by a model that can ignore what does not
    /// help, so the server's ranking, which goes by meaning, is trusted over a count of shared words.
    static let trustRankingRoom = 8_000
    /// How many recalled notes a small model reads, however much room there is.
    private static let maxRecalled = 3

    /// Writes what fits in `room` characters, or nil when none of the server's blocks is worth the model's attention
    /// (or none was recognised: the raw prompt is never passed on).
    static func write(from context: OnDeviceServerContext, question: String, room: Int) -> OnDeviceNotes? {
        guard context.recognized, room >= 200 else { return nil }

        var blocks: [String] = []
        var left = room - heading.count
        /// What a block may use: its share of what is left, less its label.
        func allowance(_ label: String, share: Double) -> Int { Int(Double(left) * share) - label.count - 2 }
        func add(_ label: String, _ text: String, share: Double = 1) {
            let allowed = allowance(label, share: share)
            guard allowed >= 80, !text.isEmpty else { return }
            let block = label + "\n" + cut(text, to: allowed)
            blocks.append(block)
            left -= block.count + 2
        }
        /// Adds the lines that fit whole (the first is cut to fit if it must be) and says how many went in.
        func addLines(_ label: String, _ lines: [String], share: Double = 1) -> Int {
            let allowed = allowance(label, share: share)
            guard allowed >= 80, !lines.isEmpty else { return 0 }
            var kept: [String] = []
            var used = 0
            for line in lines {
                let cost = line.count + (kept.isEmpty ? 0 : 1)
                if used + cost > allowed {
                    if kept.isEmpty { kept.append(cut(line, to: allowed)) }
                    break
                }
                kept.append(line)
                used += cost
            }
            let block = label + "\n" + kept.joined(separator: "\n")
            blocks.append(block)
            left -= block.count + 2
            return kept.count
        }

        var usedTruth = false
        if let truth = context.truth {
            // The legend says what the markers mean, which is worth having when it fits. When it does not, the lines
            // go in with the one thing in it that matters: an unproven belief is not a fact.
            if truth.whole.count <= allowance(truthLabel, share: 0.5) {
                add(truthLabel, truth.whole, share: 0.5)
            } else {
                add(linesLabel(legend: truth.whole), truth.lines, share: 0.5)
            }
            usedTruth = blocks.last?.hasPrefix(truthStem) == true
        }

        var pulledTitles: Set<String> = []
        if !context.pulled.isEmpty {
            let each = max(200, left / 2 / context.pulled.count)
            let kept = addLines(pulledLabel, context.pulled.map { "- " + describe($0, limit: each) }, share: 0.5)
            pulledTitles = Set(context.pulled.prefix(kept).map { key($0.title) })
        }

        var usedDeep = 0
        if !context.deep.isEmpty {
            usedDeep = addLines(deepLabel, context.deep.prefix(3).map { cut($0, to: 220) }, share: 0.25)
        }

        var usedHistory = false
        if let history = context.history {
            let before = blocks.count
            add(historyLabel, history, share: 0.25)
            usedHistory = blocks.count > before
        }

        var memoryTitles: Set<String> = []
        let related = related(context.recalled, to: question, room: room)
        if !related.isEmpty {
            let count = min(related.count, room >= trustRankingRoom ? 4 : (left >= 1_800 ? maxRecalled : 2))
            let each = max(300, left / count)
            let kept = addLines(relatedLabel, related.prefix(count).map { "- " + describe($0, limit: each) })
            memoryTitles = Set(related.prefix(kept).map { key($0.title) })
        }

        guard !blocks.isEmpty else { return nil }
        return OnDeviceNotes(
            text: heading + "\n\n" + blocks.joined(separator: "\n\n"),
            memories: memoryTitles, pulled: pulledTitles, deep: usedDeep, truth: usedTruth, history: usedHistory
        )
    }

    /// The label for the ledger's lines when the legend was left out. The legend names the marker of each unproven
    /// kind of line ("A `X` line is believed but unproven", "A `Y` line is a UV ..."); those are named here.
    static func linesLabel(legend: String) -> String {
        var markers: [String] = []
        if let regex = try? NSRegularExpression(pattern: #"`([^`]+)`\s+line is (?:believed but unproven|a UV)"#) {
            for match in regex.matches(in: legend, range: NSRange(legend.startIndex..., in: legend)) {
                if let range = Range(match.range(at: 1), in: legend), !markers.contains(String(legend[range])) { markers.append(String(legend[range])) }
            }
        }
        let lead = truthStem + ". Trust them over the notes below, and use them only if they bear on the message."
        if markers.isEmpty { return lead + " A line that says it is unverified is a belief, not a fact:" }
        return lead + " Lines marked \(markers.joined(separator: ", ")) are unproven beliefs, not facts; say so if you use one:"
    }

    /// What the reply can be said to rest on when only these notes were given.
    func narrow(_ grounding: ChatGrounding) -> ChatGrounding {
        var kept = grounding
        kept.pages = []  // the model is not given page links
        kept.memories = grounding.memories.filter { memories.contains(Self.key($0)) }
        kept.pulled = grounding.pulled.filter { pulled.contains(Self.key($0.title)) }
        kept.deepMemory = Array(grounding.deepMemory.prefix(deep))
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
    /// so there the server's ranking is trusted, as it is for a big window.)
    static func related(_ recalled: [OnDeviceServerContext.Item], to question: String, room: Int) -> [OnDeviceServerContext.Item] {
        let wanted = Set(MemoryRecallScorer.keywords(question))
        let enoughToTell = wanted.count >= 5 && room < trustRankingRoom
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
        // "You:" in a saved chat means the person; in the directive "You" means the model. Say who spoke.
        let body = item.body.replacingOccurrences(of: "You:", with: "Person said:").replacingOccurrences(of: "Assistant:", with: "Assistant said:")
        let said = ([item.summary] + item.facts + [body]).filter { !$0.isEmpty }.joined(separator: " ")
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
/// person has read them, and the question is asked again.
///
/// Pass the words of the reply, not a reasoning trace (`ThinkingSplit.text`).
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

    /// How a reply opens when it is the notes handed back: the server's block format, and the brief's own labels.
    /// Only openings: "memory:" in the middle of a reply is a spec sheet, not an echo.
    private static let echoes =
        [
            "memory:", "content (excerpted", "you:", "assistant:", "person:", "person said:", "assistant said:",
            "the user keeps a private memory", "the person has pulled the things",
        ] + OnDeviceNotes.openings.map { $0.lowercased() }

    /// What a model says when it answers about the excerpts instead of the question. Not an honest "I don't have
    /// that saved", which is what the directive asks for when the person asks about their own notes.
    private static let nonAnswers = [
        "based on the excerpts", "excerpts provided", "the excerpts don't", "the excerpts do not", "memory excerpts",
        "no memory directly", "no memories directly",
    ]

    public static func check(_ reply: String, isFinal: Bool) -> Verdict {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return isFinal ? .fine : .undecided }
        if isUnusable(text) { return .unusable }
        return isFinal || text.count >= hold ? .fine : .undecided
    }

    /// Whether `text` (a reply, or a saved one in a thread's history) is a non-answer or a copy of the notes.
    public static func isUnusable(_ text: String) -> Bool {
        let lowered = normalized(text)
        return echoes.contains { lowered.hasPrefix($0) } || isNonAnswer(String(lowered.prefix(400)))
    }

    /// Whether `text` says, anywhere, what a non-answer says.
    static func isNonAnswer(_ text: String) -> Bool {
        let lowered = normalized(text)
        return nonAnswers.contains { lowered.contains($0) }
    }

    /// Whether a saved note is, or holds, a reply that was a non-answer: a reply kept as a memory, or an
    /// `Assistant:` turn of a chat kept as one. Taken into a prompt, it teaches the model to answer the same way.
    /// A note that only talks about excerpts (design notes for this very app) is not one.
    static func holdsSavedNonAnswer(_ note: String) -> Bool {
        if isNonAnswer(String(note.prefix(400))) { return true }
        let lowered = normalized(note)
        var from = lowered.startIndex
        while let label = lowered.range(of: "assistant:", range: from..<lowered.endIndex) {
            if isNonAnswer(String(lowered[label.upperBound...].prefix(400))) { return true }
            from = label.upperBound
        }
        return false
    }

    /// Lowercase, trimmed, and one kind of apostrophe, since a model writes the curly one.
    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
    }
}
