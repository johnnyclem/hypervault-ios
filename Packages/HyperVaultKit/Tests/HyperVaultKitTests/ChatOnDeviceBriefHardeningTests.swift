import XCTest
@testable import HyperVaultKit

// What an independent review of the brief found: the parser's guarantees, what a retry keeps, the chips, the
// relevance gate pinned at its edges, and the reply screen reading words and not reasoning. Fixtures are
// `ServerPrompt` (ChatOnDeviceBriefTests.swift), built the way the server builds the prompt.

private let notesReply = "Use an AS5600: it reads a diametric magnet and reports angle, direction and velocity over I2C, in a 3 mm package."

/// A context reply the way the route writes it, with `system` JSON-escaped.
private func contextJSON(system: String, question: String, memories: [String] = [], pulled: [[String: String]] = [], deep: [String]? = nil) throws -> String {
    let object: [String: Any] = [
        "conversation_id": "c1", "system": system, "messages": [["role": "user", "content": question]], "next_position": 0,
        "recalled": [], "recalled_memories": memories, "pulled": pulled, "smart_context": false,
        "deep_memory": deep.map { $0 as Any } ?? NSNull(), "truth": NSNull(),
    ]
    return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

private func chat(_ model: ChatModelProvider, system: String, question: String, memories: [String] = [], pulled: [[String: String]] = []) throws -> OnDeviceChat {
    let transport = MockTransport(routes: [
        .json(.post, "/api/chat/context", try contextJSON(system: system, question: question, memories: memories, pulled: pulled)),
        .json(.post, "/api/chat/turns", #"{"conversation_id":"c1","reply":{"id":"m1","role":"assistant","content":"x","model":"scripted-on-device"}}"#),
    ])
    let client = HVClient(baseURL: URL(string: "https://hv.test")!, transport: transport, tokens: StaticTokenProvider(), retry: .none, sleep: { _ in })
    let outbox = ChatTurnOutbox(cache: DiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("hv-hard-\(UUID().uuidString)")), namespace: "u1")
    return OnDeviceChat(client: client, provider: model, outbox: outbox)
}

private func note(_ title: String, tags: [String] = [], summary: String = "", body: String = "") -> OnDeviceServerContext.Item {
    OnDeviceServerContext.Item(kind: .memory, title: title, tags: tags, summary: summary, body: body)
}

private let directionPhrases = ["answer from it", "invite a follow-up", "established context", "quoted directly from the vault", "Never claim the vault lacks"]

// MARK: The parser's guarantees

final class OnDeviceParserHardeningTests: XCTestCase {
    private let encoder = ServerPrompt.memory("Encoder shortlist", tags: ["hardware"], summary: "magnetic encoder jog wheel platter", body: "AS5600 and AS5048 read a magnet.")

    /// What the server writes when its recall intro is worded differently from the one this was written against.
    private func drifted(_ memories: [String]) -> String {
        ServerPrompt.recall(memories).replacingOccurrences(of: "The user keeps a private memory wiki", with: "Your user keeps a private memory wiki")
    }

    func testALedgerFollowedByAnIntroInOtherWordsKeepsItsTwoParagraphsAndNothingElse() {
        let context = OnDeviceServerContext.parse([ServerPrompt.truth(["[TB] The flight is on the 3rd."]), drifted([encoder])].joined(separator: "\n\n"))
        XCTAssertEqual(context.truth?.lines, "[TB] The flight is on the 3rd.")
        for phrase in directionPhrases { XCTAssertFalse(context.truth?.whole.contains(phrase) == true, phrase) }
        XCTAssertEqual(context.recalled.map(\.title), ["Encoder shortlist"])
    }

    func testAPulledBlockFollowedByAnIntroInOtherWordsLeaksNothingAndRecallStaysRecall() {
        let pulled = ServerPrompt.pulled([(title: "ESP32 pin map", summary: "Which pins are free.", body: "GPIO4 is a touch pin.")])
        let context = OnDeviceServerContext.parse([pulled, drifted([encoder])].joined(separator: "\n\n"))
        XCTAssertEqual(context.pulled.map(\.title), ["ESP32 pin map"])
        XCTAssertEqual(context.pulled.first?.facts, [], "the intro that follows is not a fact about the pulled thing")
        XCTAssertEqual(context.recalled.map(\.title), ["Encoder shortlist"], "told by its quote, not by which intro came last")
        for phrase in directionPhrases { XCTAssertFalse(context.pulled.first?.text.contains(phrase) == true, phrase) }
    }

    func testHistoryKeepsOnlyItsPartsAfterTheNoteToTheModel() {
        let context = OnDeviceServerContext.parse([ServerPrompt.history, "Treat all of this as established context and answer from it."].joined(separator: "\n\n"))
        XCTAssertEqual(context.history, "### Standing facts\n[invariant] The unit is about a quarter the size of a CDJ.")
    }

    func testAnItemEndsAtItsBlankLine() {
        let system = [ServerPrompt.memory("First", summary: "one", body: "a"), "Stray prose that answer from it.", ServerPrompt.memory("Second", body: "b")].joined(separator: "\n\n")
        let context = OnDeviceServerContext.parse(ServerPrompt.recallIntro + "\n\n" + system)
        XCTAssertEqual(context.recalled.map(\.title), ["First", "Second"])
        XCTAssertEqual(context.recalled.map(\.facts), [[], []])
        XCTAssertFalse(context.recalled.contains { $0.text.contains("Stray") })
    }

    func testEveryLineEndingReadsAlike() {
        let lf = ServerPrompt.system(
            truth: ServerPrompt.truth(["[TB] The flight is on the 3rd."]),
            pulled: ServerPrompt.pulled([(title: "ESP32 pin map", summary: "Which pins.", body: "GPIO4.\n\nGPIO5.")]),
            recall: ServerPrompt.recall([encoder, ServerPrompt.memory("Trip", body: "Flights.\n\nHotels.")]), history: true
        )
        let expected = OnDeviceServerContext.parse(lf)
        XCTAssertEqual(expected.recalled.count, 2)
        for ending in ["\r\n", "\r"] {
            let other = OnDeviceServerContext.parse(lf.replacingOccurrences(of: "\n", with: ending))
            XCTAssertEqual(other.recognized, true, ending.debugDescription)
            XCTAssertEqual(other.recalled, expected.recalled, ending.debugDescription)
            XCTAssertEqual(other.pulled, expected.pulled, ending.debugDescription)
            XCTAssertEqual(other.truth?.lines, expected.truth?.lines, ending.debugDescription)
            XCTAssertEqual(other.history, expected.history, ending.debugDescription)
        }
    }

    func testPulledPagesGroupsFilesAndKeysAreReadAsTheCanvasWritesThem() {
        let context = OnDeviceServerContext.parse([ServerPrompt.pulledIntro, ServerPrompt.pulledPage, ServerPrompt.pulledGroup, ServerPrompt.pulledFile, ServerPrompt.pulledKey].joined(separator: "\n\n"))
        XCTAssertEqual(context.pulled.map(\.kind), [.page, .group, .file, .key])
        XCTAssertEqual(context.pulled.map(\.title), ["Trip plan", "Site", "datasheet.pdf", "Stripe"])
        XCTAssertEqual(context.pulled[0].facts, ["Last changed 2026-10-01."])
        XCTAssertEqual(context.pulled[0].body, "Day one: fly out. Day two: the market.")
        XCTAssertEqual(context.pulled[1].facts, ["Last changed 2026-10-02.", "Files (2):", "- index.html (120 bytes)", "- style.css (30 bytes)"])
        XCTAssertEqual(context.pulled[1].body, "<h1>Hello</h1>")
        XCTAssertEqual(context.pulled[2].facts.count, 2)
        XCTAssertEqual(context.pulled[2].body, "")
        XCTAssertEqual(context.pulled[3].facts.count, 1)
        XCTAssertTrue(context.recalled.isEmpty)

        // And they reach the model as what they are, labelled as the kind of thing, without the label lines.
        let brief = OnDeviceBrief.make(server: context.pulled.isEmpty ? "" : [ServerPrompt.pulledIntro, ServerPrompt.pulledPage, ServerPrompt.pulledGroup].joined(separator: "\n\n"), question: "what is on my page?", grounding: ChatGrounding(), budget: 7_000)
        XCTAssertTrue(brief.system.contains("page \"Trip plan\": Last changed 2026-10-01. Day one: fly out. Day two: the market."))
        XCTAssertTrue(brief.system.contains("group \"Site\": Last changed 2026-10-02. Files (2): - index.html (120 bytes) - style.css (30 bytes) <h1>Hello</h1>"))
        XCTAssertFalse(brief.system.contains("Text of the page ("))
        XCTAssertFalse(brief.system.contains("Start of index.html"))
    }

    func testAPulledTitleIsJSONUnescapedAndARecalledOneIsNot() {
        let jsonTitle = String(decoding: try! JSONEncoder().encode(#"C:\notes\esp32 "pins""#), as: UTF8.self)  // what JSON.stringify writes
        let pulled = ["### Memory: \(jsonTitle) [esp32]", "Summary: s", "```", "body", "```"].joined(separator: "\n")
        let recalled = ServerPrompt.memory(#"C:\notes\esp32 "pins""#, body: "body")
        let context = OnDeviceServerContext.parse([ServerPrompt.pulledIntro, pulled, ServerPrompt.recallIntro, recalled].joined(separator: "\n\n"))
        XCTAssertEqual(context.pulled.map(\.title), [#"C:\notes\esp32 "pins""#])
        XCTAssertEqual(context.recalled.map(\.title), [#"C:\notes\esp32 "pins""#], "recall does not escape, so there is nothing to undo")
    }

    func testFoldMakesTheOmissionMarkPlainAndOneSpaceOfEveryRun() {
        XCTAssertEqual(OnDeviceServerContext.fold("a  b\n\n[…] c\t d"), "a b … c d")
    }
}

// MARK: What a brief carries and what it says it carries

final class OnDeviceBriefHardeningTests: XCTestCase {
    let directive = OnDevicePrompt.defaultInstructions
    private let encoder = ServerPrompt.memory("Encoder shortlist", tags: ["hardware"], summary: "magnetic encoder jog wheel platter", body: "AS5600 and AS5048 read a magnet.")

    func testTheRetryKeepsWhatWasPulledAndRecordedAndDropsOnlyWhatRecallGuessedAt() {
        let system = ServerPrompt.system(
            truth: ServerPrompt.truth(["[TB] The flight is on the 3rd."]),
            pulled: ServerPrompt.pulled([(title: "Trip budget", summary: "The budget.", body: "Flights 420, hotel 610, food 200.")]),
            deep: true, recall: ServerPrompt.recall([encoder]), history: true
        )
        var given = ChatGrounding(memories: ["Encoder shortlist"], deepMemory: ["decision: Chose the ESP32-S3", "past message: BPM"], smartContext: true)
        given.pulled = [ChatPulledUse(kind: .memory, id: "m1", title: "Trip budget")]
        let brief = OnDeviceBrief.make(server: system, question: "summarize this", grounding: given, budget: 7_000)

        XCTAssertTrue(brief.system.contains("Encoder shortlist"))
        XCTAssertTrue(brief.system.contains("Chose the ESP32-S3"))
        XCTAssertEqual(brief.grounding.memories, ["Encoder shortlist"])

        XCTAssertFalse(brief.retrySystem.contains("Encoder shortlist"), "a guess by recall is not asked about")
        XCTAssertFalse(brief.retrySystem.contains("Chose the ESP32-S3"))
        XCTAssertTrue(brief.retrySystem.contains("Flights 420, hotel 610, food 200."), "what they pulled onto their page is")
        XCTAssertTrue(brief.retrySystem.contains("The flight is on the 3rd."), "and so is what they recorded")
        XCTAssertTrue(brief.retrySystem.contains("Earlier in this conversation:"))
        XCTAssertEqual(brief.retryGrounding.memories, [])
        XCTAssertEqual(brief.retryGrounding.deepMemory, [])
        XCTAssertEqual(brief.retryGrounding.pulled.map(\.title), ["Trip budget"])
        XCTAssertTrue(brief.retryGrounding.smartContext)
    }

    func testTheChipsNameOnlyWhatTheModelWasShown() {
        let titles = (1...8).map { "Pulled thing \($0)" }
        let body = String(repeating: "esp32 touch jog wheel platter sensor ", count: 12)
        let deep = (["## Long-horizon memory (conversation graph)", "The user's past conversations are indexed.", (1...5).map { "- [decision] Decision \($0) about the unit." }.joined(separator: "\n")]).joined(separator: "\n\n")
        let system = [ServerPrompt.pulled(titles.map { (title: $0, summary: "esp32 touch", body: body) }), deep].joined(separator: "\n\n")
        var given = ChatGrounding(deepMemory: (1...5).map { "decision: Decision \($0)" })
        given.pulled = titles.map { ChatPulledUse(kind: .memory, id: $0, title: $0) }
        let brief = OnDeviceBrief.make(server: system, question: "esp32 touch jog wheel platter sensor", grounding: given, budget: 7_000)

        let shown = Set(titles.filter { brief.system.contains("\"\($0)\"") })
        XCTAssertFalse(shown.isEmpty)
        XCTAssertLessThan(shown.count, 8, "the room does not hold eight pulled things")
        XCTAssertEqual(Set(brief.grounding.pulled.map(\.title)), shown, "the chips are the ones in the prompt, no more and no fewer")
        XCTAssertEqual(brief.grounding.deepMemory.count, 3, "three graph entries went in, of the five the server found")
        XCTAssertEqual(brief.grounding.deepMemory, ["decision: Decision 1", "decision: Decision 2", "decision: Decision 3"])
        for index in 1...3 { XCTAssertTrue(brief.system.contains("Decision \(index) about the unit")) }
        XCTAssertFalse(brief.system.contains("Decision 4 about the unit"))
    }

    func testTheChipsKeepAPulledThingWhoseTitleHasABackslash() {
        let title = #"C:\notes\esp32 pins"#
        let jsonTitle = String(decoding: try! JSONEncoder().encode(title), as: UTF8.self)
        let block = ["### Memory: \(jsonTitle) [esp32]", "Summary: pins", "```", "GPIO4", "```"].joined(separator: "\n")
        var given = ChatGrounding()
        given.pulled = [ChatPulledUse(kind: .memory, id: "m", title: title)]
        let brief = OnDeviceBrief.make(server: [ServerPrompt.pulledIntro, block].joined(separator: "\n\n"), question: "which pin?", grounding: given, budget: 7_000)
        XCTAssertEqual(brief.grounding.pulled.map(\.title), [title])
    }

    func testTheLedgerAndEarlierTurnsAreClaimedOnlyWhenTheModelWasGivenThem() {
        let claimed = ChatGrounding(truth: ChatTruthSummary(cited: 2), smartContext: true)
        let without = OnDeviceBrief.make(server: ServerPrompt.system(recall: ServerPrompt.recall([encoder])), question: "which encoder?", grounding: claimed, budget: 7_000)
        XCTAssertNil(without.grounding.truth)
        XCTAssertFalse(without.grounding.smartContext)

        let with = OnDeviceBrief.make(server: ServerPrompt.system(truth: ServerPrompt.truth(["[TB] The flight is on the 3rd."]), history: true), question: "when do we fly?", grounding: claimed, budget: 7_000)
        XCTAssertEqual(with.grounding.truth?.cited, 2)
        XCTAssertTrue(with.grounding.smartContext)
    }

    func testABigWindowTrustsTheServersRankingBySenseAndReadsFourNotes() {
        let auth = ServerPrompt.memory("Auth architecture decision", tags: ["ios"], summary: "Chose OAuth with PKCE for the iOS client", body: "We picked OAuth2 plus PKCE. Session tokens live in the Keychain.")
        let question = "What did I decide about auth for the mobile app last week?"
        XCTAssertEqual(MemoryRecallScorer.keywords(question).count, 6)

        // Apple's window cannot afford a neighbour that shares one word: the note is left out.
        let small = OnDeviceBrief.make(server: ServerPrompt.system(recall: ServerPrompt.recall([auth])), question: question, grounding: ChatGrounding(memories: ["Auth architecture decision"]), budget: 7_000)
        XCTAssertFalse(small.hasNotes)

        // A model on the person's own network can, and the server's ranking goes by meaning, which words cannot judge.
        let big = OnDeviceBrief.make(server: ServerPrompt.system(recall: ServerPrompt.recall([auth])), question: question, grounding: ChatGrounding(memories: ["Auth architecture decision"]), budget: 60_000)
        XCTAssertTrue(big.hasNotes)
        XCTAssertEqual(big.grounding.memories, ["Auth architecture decision"])

        let four = (1...4).map { ServerPrompt.memory("Auth note \($0)", summary: "login", body: "tokens") }
        let many = OnDeviceBrief.make(server: ServerPrompt.system(recall: ServerPrompt.recall(four)), question: question, grounding: ChatGrounding(memories: (1...4).map { "Auth note \($0)" }), budget: 60_000)
        XCTAssertEqual(many.grounding.memories, (1...4).map { "Auth note \($0)" })

        // What a saved bad reply teaches is not read back at any size.
        let poisoned = ServerPrompt.memory("Chat: auth", summary: "auth", body: "You:\nwhat did I decide?\n\nAssistant:\nBased on the excerpts provided there is nothing.")
        let none = OnDeviceBrief.make(server: ServerPrompt.system(recall: ServerPrompt.recall([poisoned])), question: question, grounding: ChatGrounding(memories: ["Chat: auth"]), budget: 60_000)
        XCTAssertFalse(none.hasNotes)
    }

    func testASavedChatSaysWhoSpoke() {
        let chatNote = ServerPrompt.memory("Chat: encoders", body: "You:\nwhich encoder?\n\nAssistant:\nUse an AS5600.")
        let brief = OnDeviceBrief.make(server: ServerPrompt.system(recall: ServerPrompt.recall([chatNote])), question: "which encoder?", grounding: ChatGrounding(memories: ["Chat: encoders"]), budget: 7_000)
        XCTAssertTrue(brief.system.contains("Person said: which encoder? Assistant said: Use an AS5600."))
        XCTAssertFalse(brief.system.contains("You: which"), "\"You\" in the directive is the model")
    }

    // MARK: Through the turn

    func testTheTurnHandsTheBriefTheQuestionAndTheBudget() async throws {
        let unrelated = ServerPrompt.memory("Hiring plan", summary: "Roles for next quarter.", body: "Two engineers, one designer.")

        // The question: an unrelated note for the DJ question never reaches the model.
        let model = ScriptedModel([[notesReply]])
        let asked = try chat(model, system: ServerPrompt.system(recall: ServerPrompt.recall([unrelated])), question: djQuestion, memories: ["Hiring plan"])
        _ = try await asked.run(OnDeviceTurn(message: djQuestion, conversationID: "c1")) { _ in }
        XCTAssertEqual(model.seen[0].system, OnDevicePrompt.defaultInstructions)

        // The budget: what the provider says it can read is what the notes are cut to, not clipped mid-note by the fitter.
        let big = String(repeating: "esp32 touch jog wheel platter sensor ", count: 400)
        let system = ServerPrompt.system(pulled: ServerPrompt.pulled([(title: "Pins", summary: "esp32 touch", body: big), (title: "Wheel", summary: "jog wheel", body: big)]))
        let small = ScriptedModel([[notesReply]], contextBudget: 4_000)
        let squeezed = try chat(small, system: system, question: "esp32 touch jog wheel platter sensor")
        _ = try await squeezed.run(OnDeviceTurn(message: "esp32 touch jog wheel platter sensor", conversationID: "c1")) { _ in }
        XCTAssertLessThanOrEqual(small.seen[0].system.count, 1_800)
        XCTAssertFalse(small.seen[0].system.contains(ChatContextFitter.shortenedMarker), "the fitter had nothing left to cut")
        XCTAssertTrue(small.seen[0].system.hasPrefix(OnDevicePrompt.defaultInstructions))
    }

    func testARetryAfterANonAnswerStillHasWhatThePersonPulledAndRecorded() async throws {
        let system = ServerPrompt.system(
            truth: ServerPrompt.truth(["[TB] The flight is on the 3rd."]),
            pulled: ServerPrompt.pulled([(title: "Trip budget", summary: "The budget.", body: "Flights 420, hotel 610, food 200.")]),
            recall: ServerPrompt.recall([encoder])
        )
        let model = ScriptedModel([["Based on the excerpts provided, I cannot see anything."], [notesReply]])
        let asked = try chat(model, system: system, question: "summarize this", memories: ["Encoder shortlist"], pulled: [["kind": "memory", "id": "m1", "title": "Trip budget"]])
        let outcome = try await asked.run(OnDeviceTurn(message: "summarize this", conversationID: "c1")) { _ in }

        XCTAssertEqual(model.seen.count, 2)
        XCTAssertTrue(model.seen[0].system.contains("Encoder shortlist"))
        XCTAssertTrue(model.seen[1].system.contains("Flights 420, hotel 610, food 200."))
        XCTAssertTrue(model.seen[1].system.contains("The flight is on the 3rd."))
        XCTAssertFalse(model.seen[1].system.contains("Encoder shortlist"))
        XCTAssertEqual(outcome.grounding.pulled.map(\.title), ["Trip budget"], "the reply still rests on what was pulled")
        XCTAssertEqual(outcome.grounding.memories, [])
    }
}

// MARK: The relevance gate, pinned at its edges

final class OnDeviceRelevanceGateTests: XCTestCase {
    /// Eight keywords: display, encoder, esp32-s3, jog, magnetic, platter, touch, wheel.
    private let question = "which magnetic encoder should the jog wheel platter use with the ESP32-S3 touch display"
    private let small = 7_000

    private func kept(_ item: OnDeviceServerContext.Item, to question: String? = nil, room: Int = 2_000) -> Bool {
        !OnDeviceNotes.related([item], to: question ?? self.question, room: room).isEmpty
    }

    func testTheQuestionsKeywordsAreWhatTheseTestsCount() {
        XCTAssertEqual(Set(MemoryRecallScorer.keywords(question)), ["magnetic", "encoder", "jog", "wheel", "platter", "esp32-s3", "touch", "display"])
    }

    func testTwoSharedHeadingWordsAreEnough() {
        XCTAssertTrue(kept(note("Jog wheel ideas")))
        XCTAssertFalse(kept(note("Wheel ideas")), "one heading word alone is not")
    }

    func testOneHeadingWordNeedsTwoBodyWords() {
        XCTAssertTrue(kept(note("Display notes", body: "The encoder and the platter.")))
        XCTAssertFalse(kept(note("Display notes", body: "Touch it twice.")), "one and one is not enough")
    }

    func testThreeBodyWordsAreEnoughWithNoHeadingWord() {
        XCTAssertTrue(kept(note("Meeting minutes", body: "We agreed the magnetic encoder goes under the platter")))
        XCTAssertFalse(kept(note("Meeting minutes", body: "The magnetic encoder is nice.")), "two body words are not")
    }

    func testTagsAndSummariesCountAsTheHeading() {
        XCTAssertTrue(kept(note("Hardware", tags: ["jog", "wheel"])))
        XCTAssertTrue(kept(note("Hardware", summary: "an encoder for the platter")))
    }

    func testAQuestionOfFourKeywordsIsNotToldApartByItsWordsAndOneOfFiveIs() {
        let unrelated = note("Hiring plan", summary: "Roles for next quarter.", body: "Two engineers.")
        let four = "magnetic encoder jog wheel"
        let five = "magnetic encoder jog wheel platter"
        XCTAssertEqual(MemoryRecallScorer.keywords(four).count, 4)
        XCTAssertEqual(MemoryRecallScorer.keywords(five).count, 5)
        XCTAssertTrue(kept(unrelated, to: four), "the server's ranking is trusted")
        XCTAssertFalse(kept(unrelated, to: five), "five words are enough to tell")
    }

    func testABigWindowIsNotGatedButAStillDropsSavedNonAnswers() {
        let unrelated = note("Hiring plan", summary: "Roles", body: "Two engineers.")
        XCTAssertFalse(kept(unrelated, room: 2_000))
        XCTAssertTrue(kept(unrelated, room: OnDeviceNotes.trustRankingRoom))
        let poisoned = note("Reply", body: "Based on the excerpts provided, there is nothing.")
        XCTAssertFalse(kept(poisoned, room: OnDeviceNotes.trustRankingRoom))
    }
}

// MARK: What the screen reads

final class OnDeviceReplyScreenTableTests: XCTestCase {
    func testEveryOpeningThatIsANoteHandedBackIsCaught() {
        for echo in [
            "memory: x", "Content (excerpted around the topic", "you: hi", "assistant: hi", "person: hi", "Person said: hi", "Assistant said: hi",
            "The user keeps a private memory wiki", "The person has pulled the things below",
            "Notes from the person's vault. Background only", "Notes that may be related (background only):\n- \"A\"",
            "What the person has open on their page:", "From their other chats:", "Earlier in this conversation:", "Things the person has recorded (use them",
            "Notes from the person\u{2019}s vault", "  \n\nMEMORY: x",
        ] {
            XCTAssertEqual(OnDeviceReplyScreen.check(echo, isFinal: true), .unusable, echo)
        }
    }

    func testEveryNonAnswerPhraseIsCaughtWhereverItIsInTheOpening() {
        for phrase in [
            "Based on the excerpts", "Here are the excerpts provided", "The excerpts don't say", "The excerpts don\u{2019}t say", "The excerpts do not cover it",
            "These memory excerpts", "There is no memory directly related", "There are no memories directly about it",
        ] {
            XCTAssertEqual(OnDeviceReplyScreen.check("Well. " + phrase + " so I will guess.", isFinal: true), .unusable, phrase)
        }
    }

    func testAnOpeningIsOnlyAnOpening() {
        for fine in ["A quick summary: use an AS5600.", "Specs. Memory: 512 KB SRAM, 8 MB flash.", "Ask them: you: are the owner.", "Use an AS5600; the assistant: none needed."] {
            XCTAssertEqual(OnDeviceReplyScreen.check(fine, isFinal: true), .fine, fine)
        }
    }

    func testAnHonestDontHaveThatSavedIsNotANonAnswer() {
        for honest in ["I don't have that saved.", "I don't have any memories of that quote.", "There are no relevant memories about the kitchen quote, and I don't have it saved."] {
            XCTAssertEqual(OnDeviceReplyScreen.check(honest, isFinal: true), .fine, honest)
        }
    }

    func testTheHistoryKeepsThePersonsOwnWordsAndWhatTheAssistantSaidNotWhatItThought() {
        let kept = ChatContextFitter.sanitize([
            ChatWireMessage(role: .user, content: "Summary: give me one for the datasheet I pasted"),
            ChatWireMessage(role: .assistant, content: "<think>Based on the excerpts provided there is nothing, so I will answer.</think>Use an AS5600."),
            ChatWireMessage(role: .assistant, content: "Memory: \"Chat: x\" [cdt]"),
            ChatWireMessage(role: .user, content: "and the magnet?"),
        ])
        XCTAssertEqual(kept.map(\.content), ["Summary: give me one for the datasheet I pasted", "Use an AS5600.", "and the magnet?"])
    }
}

// MARK: Words, not reasoning

final class OnDeviceThinkingScreenTests: XCTestCase {
    private let trace = "<think>" + String(repeating: "Hmm, which encoder? ", count: 12)
    private let notes = ServerPrompt.system(recall: ServerPrompt.recall([
        ServerPrompt.memory("Encoder shortlist", tags: ["hardware"], summary: "magnetic encoder jog wheel platter", body: "AS5600 and AS5048 read a magnet.")
    ]))
    private let question = "which magnetic encoder should the jog wheel platter use with the ESP32-S3 touch display"

    private func run(_ model: ScriptedModel, onPartial: @escaping @MainActor @Sendable (String) -> Void = { _ in }) async throws -> OnDeviceOutcome {
        try await chat(model, system: notes, question: question, memories: ["Encoder shortlist"]).run(OnDeviceTurn(message: question, conversationID: "c1"), onPartial: onPartial)
    }

    func testAnEchoThatFollowsALongTraceIsCaught() async throws {
        let model = ScriptedModel([[trace, trace + "</think>\nMemory: \"Chat: which magnetic encoder\" [cdt]"], [notesReply]])
        let outcome = try await run(model)
        XCTAssertEqual(model.seen.count, 2, "the trace did not use up the screen's window")
        XCTAssertEqual(outcome.reply, notesReply)
    }

    func testATraceThatMentionsTheExcerptsIsNotANonAnswer() async throws {
        let thought = "<think>Based on the excerpts provided there is nothing about encoders, so I will answer from my own knowledge. "
        let model = ScriptedModel([[thought, thought + "</think>\n" + notesReply]])
        let outcome = try await run(model)
        XCTAssertEqual(model.seen.count, 1, "what it said is an answer")
        XCTAssertEqual(outcome.reply, notesReply)
        XCTAssertEqual(outcome.grounding.memories, ["Encoder shortlist"])
    }

    func testTheTraceIsShownAsItIsWrittenAndTheWordsOnceTheyAreRead() async throws {
        let model = ScriptedModel([[trace, trace + "</think>\n" + notesReply]])
        let partials = TestBox<[String]>([])
        _ = try await run(model) { partials.value.append($0) }
        XCTAssertEqual(partials.value.first?.hasPrefix("Hmm, which encoder?"), true, "a reasoning model's bubble is not left blank")
        XCTAssertEqual(partials.value.last, notesReply)
        XCTAssertFalse(partials.value.contains { $0.contains("<think>") })
    }

    func testAReplyThatRepeatsTheBriefsOwnLabelsIsCaught() async throws {
        let model = ScriptedModel([["Notes that may be related (background only):\n- \"Encoder shortlist\" [hardware]: magnetic encoder jog wheel platter AS5600"], [notesReply]])
        let outcome = try await run(model)
        XCTAssertEqual(model.seen.count, 2)
        XCTAssertEqual(outcome.reply, notesReply)
    }
}
