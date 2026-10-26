import HyperVaultKit
import XCTest
@testable import HyperVault

/// The notices read the ledger beside the events, so each says what it is about and can open it.
@MainActor
final class TruthNoticesModelTests: XCTestCase {
    private let team = TruthLedger(id: "l1", slug: "team", name: "Team", kind: .hosted)

    private func model(_ routes: [MockRoute], ledger: TruthLedger? = nil) -> TruthNoticesModel {
        TruthNoticesModel(client: AppEnvironment.preview(routes: routes).client, ledger: ledger ?? team)
    }

    private func notices(_ model: TruthNoticesModel, file: StaticString = #filePath, line: UInt = #line) -> [TruthNotice] {
        guard case .loaded(let notices) = model.phase else {
            XCTFail("The notices did not load", file: file, line: line)
            return []
        }
        return notices
    }

    func testANoticeSaysTheClaimAndOpensTheEntry() async {
        let model = model(TruthPreviewData.noticeRoutes)
        await model.load()
        let list = notices(model)
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(
            list[0].sentence,
            "\u{201C}Retries are capped at 5; the old cap of 3 is dead\u{201D} is unsupported: a premise beneath it was struck."
        )
        XCTAssertEqual(list[1].sentence, "\u{201C}Retries are idempotent across regions\u{201D} was verified.")
        XCTAssertFalse(list.contains { $0.sentence.contains("01M1E6JK") })
        XCTAssertEqual(list[0].ref?.row.id, "01M1E6JK8SQAJ8K0JBRHTD10YG")
        XCTAssertEqual(list[0].ref?.ledger, "team")
        XCTAssertEqual(list[0].ref?.isHosted, true)
        XCTAssertEqual(list[0].detail?.hasPrefix("By kim"), true)
    }

    /// With no answer from the ledger the notice still reads, with the id cut short, and opens nothing.
    func testANoticeWithoutTheLedgerKeepsAShortId() async {
        let routes = TruthPreviewData.noticeRoutes.filter { $0.path != "/api/truth" }
        let model = model(routes)
        await model.load()
        let list = notices(model)
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0].sentence, "TB \u{2026}TD10YG is unsupported: a premise beneath it was struck.")
        XCTAssertNil(list[0].ref)
        XCTAssertNil(list[1].ref)
    }

    func testAnEntryFromAnotherLedgerIsNotClaimedByThisOne() async {
        let elsewhere = #"{"ledger":{"id":"l1","slug":"team","name":"Team","kind":"hosted"},"summary":{"cited":0,"contested":0,"flags":0,"displaced":0,"total":0,"open_proposals":0},"citable":[],"flags":[],"displaced":[],"entries":[]}"#
        let routes = [MockRoute.json(.get, "/api/truth", elsewhere)] + TruthPreviewData.noticeRoutes.filter { $0.path != "/api/truth" }
        let model = model(routes)
        await model.load()
        XCTAssertNil(notices(model).first?.ref)
    }

    func testTheNoticesFailWhenTheEventsDo() async {
        let routes = [MockRoute.failure(.get, "/api/truth/events", status: 400, message: "Nope")] + TruthPreviewData.noticeRoutes
        let model = model(routes)
        await model.load()
        guard case .failed = model.phase else { return XCTFail("Expected the notices to fail") }
    }
}
