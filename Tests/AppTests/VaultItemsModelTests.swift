import HyperVaultKit
import XCTest
@testable import HyperVault

/// The Vault list (App/Features/Vault/VaultItemsModel.swift): what it shows and in what order, how a list that cannot be read
/// is told apart from one that is empty, and what a save, a rename, a replace and a delete do with the answers, the 404s
/// and the 409s included.
@MainActor
final class VaultItemsModelTests: XCTestCase {
    private func loaded(_ world: VaultWorld) async -> VaultItemsModel {
        let model = world.list()
        await model.load()
        return model
    }

    private func entry(_ id: String, _ name: String, kind: String = "login") -> String {
        #"{"id":"\#(id)","name":"\#(name)","kind":"\#(kind)","description":null,"created_at":"2026-10-20T10:00:00Z","updated_at":"2026-10-20T10:00:00Z","last_accessed_at":null,"hint":null}"#
    }

    private func list(_ entries: [String]) -> MockRoute {
        .json(.get, "/api/secrets", #"{"secrets":[\#(entries.joined(separator: ","))]}"#)
    }

    // MARK: Showing

    func testTheRowsAreInTheWebsFixedEnglishOrderByName() async {
        let model = await loaded(VaultWorld())

        XCTAssertEqual(model.visible.map(\.name), ["amex-0005", "contact", "github.com", "home", "stripe-restricted-key", "visa-4242"])
    }

    func testCaseDoesNotCountAndANameTheCollatorCannotTellApartKeepsItsPlace() async {
        let world = VaultWorld(extra: [list([entry("1", "Zed"), entry("2", "Github"), entry("3", "apple"), entry("4", "github")])])
        let model = await loaded(world)

        XCTAssertEqual(model.visible.map(\.name), ["apple", "Github", "github", "Zed"])
    }

    func testTheCountsAddUpToAllAndDoNotFollowTheSearch() async {
        let model = await loaded(VaultWorld())
        model.query = "visa"

        XCTAssertEqual(model.count(in: nil), 6)
        XCTAssertEqual(model.count(in: .logins), 1)
        XCTAssertEqual(model.count(in: .cards), 2)
        XCTAssertEqual(model.count(in: .contact), 2)
        XCTAssertEqual(model.count(in: .keys), 1)
        XCTAssertEqual(VaultCategory.allCases.map { model.count(in: $0) }.reduce(0, +), model.count(in: nil))
        XCTAssertEqual(model.visible.map(\.name), ["visa-4242"])
    }

    func testAFilterKeepsOneCategory() async {
        let model = await loaded(VaultWorld())
        model.filter = .cards

        XCTAssertEqual(model.visible.map(\.name), ["amex-0005", "visa-4242"])
    }

    func testSearchReadsTheNameTheHintAndTheKindButNotTheDescription() async {
        let model = await loaded(VaultWorld())

        model.query = "appleseed"
        XCTAssertEqual(model.visible.map(\.name), ["contact", "github.com"], "the hint")
        model.query = "mc"
        XCTAssertTrue(model.visible.isEmpty)
        model.query = "login"
        XCTAssertEqual(model.visible.map(\.name), ["github.com"], "the kind")
        model.query = "work account"
        XCTAssertTrue(model.visible.isEmpty, "a description is not on any screen, so it is not searched")
    }

    func testTheAccountIsFullAtAHundredEntries() async {
        let hundred = (1...100).map { entry("id\($0)", "entry-\($0)") }
        let full = await loaded(VaultWorld(extra: [list(hundred)]))
        XCTAssertTrue(full.isFull)

        let almost = await loaded(VaultWorld(extra: [list(Array(hundred.dropFirst()))]))
        XCTAssertFalse(almost.isFull)
    }

    // MARK: Loading

    func testAFirstReadThatFailsIsTheScreensErrorAndIsAnnounced() async {
        let world = VaultWorld(extra: [.failure(.get, "/api/secrets", status: 500, message: "The database is busy.")])
        let model = await loaded(world)

        XCTAssertEqual(model.phase, .failed("The database is busy."))
        XCTAssertEqual(world.announcer.spoken, ["The database is busy."])
    }

    func testAFirstReadWithNoSignalSaysTheProductsLoadLine() async {
        let model = await loaded(VaultWorld(wrapping: { _ in NoSignal() }))

        XCTAssertEqual(model.phase, .failed(HVCopy.yoursOfflineLine))
    }

    func testARefreshThatFailsKeepsTheListAndSaysSo() async {
        let reads = Sequenced([
            Sequenced.json(#"{"secrets":[\#(entry("1", "github.com"))]}"#),
            Sequenced.error("The database is busy.", status: 503),
            Sequenced.json(#"{"secrets":[\#(entry("1", "github.com")),\#(entry("2", "gitlab.com"))]}"#),
        ])
        let world = VaultWorld(extra: [reads.route(.get, "/api/secrets")])
        let model = await loaded(world)
        XCTAssertNil(model.refreshError)

        await model.load()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.visible.map(\.name), ["github.com"], "what was there stays")
        XCTAssertEqual(model.refreshError, "The database is busy.")
        XCTAssertEqual(world.announcer.spoken, ["The database is busy."])

        await model.load()
        XCTAssertNil(model.refreshError)
        XCTAssertEqual(model.visible.map(\.name), ["github.com", "gitlab.com"])
    }

    // MARK: Saving

    func testASaveAddsTheEntryAndSendsNoHintAndNoDescription() async throws {
        let made = #"{"secret":\#(entry("s9", "gitlab.com"))}"#
        let world = VaultWorld(extra: [.json(.post, "/api/secrets", made, status: 201)])
        let model = await loaded(world)

        let outcome = await model.create(name: "gitlab.com", kind: .login, value: #"{"username":"sam","password":"x"}"#)

        guard case .created(let secret) = outcome else { return XCTFail("expected the entry to be created, got \(outcome)") }
        XCTAssertEqual(secret.name, "gitlab.com")
        XCTAssertEqual(model.count(in: nil), 7)
        let sent = await world.transport.requests(matching: "/api/secrets").last { $0.httpMethod == "POST" }
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: sent?.httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["name", "kind", "value"], "no hint and no description are ever sent")
    }

    func testATakenNameIsAConflictWithTheServersWords() async {
        let world = VaultWorld(extra: [.failure(.post, "/api/secrets", status: 409, message: "A secret with that name already exists.")])
        let model = await loaded(world)

        let outcome = await model.create(name: "github.com", kind: .login, value: "{}")

        XCTAssertEqual(outcome, .failure(VaultFailure(message: "A secret with that name already exists.", status: 409)))
        XCTAssertEqual(model.count(in: nil), 6)
    }

    func testASaveWithNoSignalSaysTheProductsLine() async {
        let world = VaultWorld(wrapping: { OfflineWrites(inner: $0) })
        let model = await loaded(world)

        let outcome = await model.create(name: "gitlab.com", kind: .login, value: "{}")

        XCTAssertEqual(outcome, .failure(VaultFailure(message: VaultCopy.keyChangeOfflineLine)))
        XCTAssertEqual(world.announcer.spoken, [VaultCopy.keyChangeOfflineLine])
    }

    // MARK: Renaming and replacing

    func testARenameKeepsTheEntryUnderItsNewName() async throws {
        let renamed = #"{"secret":\#(entry("s1", "github.com-work"))}"#
        let world = VaultWorld(extra: [.json(.patch, "/api/secrets/github.com", renamed)])
        let model = await loaded(world)
        let before = try XCTUnwrap(model.secret(named: "github.com"))

        let outcome = await model.change(before, newName: "github.com-work")

        guard case .updated(let after) = outcome else { return XCTFail("expected an update, got \(outcome)") }
        XCTAssertEqual(after.id, before.id)
        XCTAssertNil(model.secret(named: "github.com"))
        XCTAssertEqual(model.secret(id: "s1")?.name, "github.com-work")
        let sent = await world.transport.requests(matching: "/api/secrets/github.com").first { $0.httpMethod == "PATCH" }
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: sent?.httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual(body["new_name"] as? String, "github.com-work")
        XCTAssertNil(body["description"])
    }

    func testAnEntryThatIsGoneWhenItIsChangedLeavesTheListAndTheListIsReadAgain() async throws {
        let world = VaultWorld(extra: [.failure(.patch, "/api/secrets/visa-4242", status: 404, message: "No such secret.")])
        let model = await loaded(world)
        let card = try XCTUnwrap(model.secret(named: "visa-4242"))

        let outcome = await model.change(card, value: "{}")

        XCTAssertEqual(outcome, .entryGone)
        XCTAssertNil(model.secret(id: card.id), "'No such secret.' is not a line: the entry is just gone")
        let reread = await vaultEventually { await world.seen().filter { $0 == "GET /api/secrets" }.count == 2 }
        XCTAssertTrue(reread, "the list is read again")
    }

    func testAChangeThatFailsIsAnnouncedAndTheEntryStays() async throws {
        let world = VaultWorld(extra: [.failure(.patch, "/api/secrets/github.com", status: 409, message: "A secret with that name already exists.")])
        let model = await loaded(world)
        let login = try XCTUnwrap(model.secret(named: "github.com"))

        let outcome = await model.change(login, newName: "visa-4242")

        XCTAssertEqual(outcome, .failure(VaultFailure(message: "A secret with that name already exists.", status: 409)))
        XCTAssertEqual(world.announcer.spoken, ["A secret with that name already exists."])
        XCTAssertNotNil(model.secret(named: "github.com"))
    }

    // MARK: Deleting

    func testADeleteTakesTheEntryOffTheList() async throws {
        let world = VaultWorld(extra: [.json(.delete, "/api/secrets/visa-4242", #"{"ok":true,"deleted":"visa-4242"}"#)])
        let model = await loaded(world)
        let card = try XCTUnwrap(model.secret(named: "visa-4242"))

        let outcome = await model.delete(card)

        XCTAssertEqual(outcome, .deleted)
        XCTAssertNil(model.secret(named: "visa-4242"))
    }

    func testDeletingAnEntryThatIsAlreadyGoneIsDeletedAndTheListIsReadAgain() async throws {
        let world = VaultWorld(extra: [.failure(.delete, "/api/secrets/visa-4242", status: 404, message: "No such secret.")])
        let model = await loaded(world)
        let card = try XCTUnwrap(model.secret(named: "visa-4242"))

        let outcome = await model.delete(card)

        XCTAssertEqual(outcome, .entryGone)
        XCTAssertNil(model.secret(named: "visa-4242"))
        let reread = await vaultEventually { await world.seen().filter { $0 == "GET /api/secrets" }.count == 2 }
        XCTAssertTrue(reread)
    }

    func testADeleteThatFailsKeepsTheEntry() async throws {
        let world = VaultWorld(extra: [.failure(.delete, "/api/secrets/visa-4242", status: 500, message: "The database is busy.")])
        let model = await loaded(world)
        let card = try XCTUnwrap(model.secret(named: "visa-4242"))

        let outcome = await model.delete(card)

        XCTAssertEqual(outcome, .failure(VaultFailure(message: "The database is busy.", status: 500)))
        XCTAssertNotNil(model.secret(named: "visa-4242"))
    }
}
