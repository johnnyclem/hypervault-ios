import HyperVaultKit
import SwiftUI
import XCTest
@testable import HyperVault

/// The banner for a background job that finished while nobody watched, alone and over the Library.
@MainActor
final class JobNoticeSnapshotTests: XCTestCase {
    private func notice(
        _ status: BackgroundJobStatus, label: String, result: JSONValue? = nil, error: String? = nil
    ) throws -> BackgroundJobNotice {
        let job = BackgroundJob(id: "j1", kind: "artifact_repair", status: status, label: label, result: result, error: error)
        return try XCTUnwrap(BackgroundJobNotice(job: job))
    }

    private func page(_ notice: BackgroundJobNotice, waiting: Int) -> some View {
        VStack {
            JobNoticeBanner(notice: notice, waiting: waiting, onDismiss: {})
                .padding(HV.Space.m)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background)
        .tint(HVColor.primary)
    }

    func testARepairThatWorked() throws {
        let worked = try notice(
            .succeeded, label: "Repairing \u{201C}Trip plan\u{201D}",
            result: ["changed": true, "message": "My Claude took a pass at it \u{2014} reload the artifact to see if it renders now."]
        )
        try snapshot(page(worked, waiting: 0), named: "job-notice", size: CGSize(width: 393, height: 240))
    }

    func testARepairThatFailedWithMoreWaiting() throws {
        let failed = try notice(.failed, label: "Repairing \u{201C}Budget 2026\u{201D}", error: "No LLM backend is connected.")
        try snapshot(page(failed, waiting: 2), named: "job-notice-failed", size: CGSize(width: 393, height: 240))
    }

    func testALongMessageAtTheLargestType() throws {
        let long = try notice(
            .succeeded, label: "Repairing \u{201C}Trip plan\u{201D}",
            result: [
                "changed": false,
                "message": "My Claude looked it over but didn't change anything \u{2014} the render error may be a runtime bug rather than a syntax slip. Open the source to check, or try a different backend.",
            ]
        )
        try snapshot(
            page(long, waiting: 1).environment(\.dynamicTypeSize, .accessibility3),
            named: "job-notice-large", size: CGSize(width: 393, height: 560)
        )
    }

    /// The notice over the Library: it asks the server on appearing, as it does on the phone.
    func testOverTheLibrary() throws {
        let jobs = #"""
        {"jobs":[{"id":"j1","kind":"artifact_repair","status":"succeeded","label":"Repairing \#u{201C}Pomodoro Timer\#u{201D}","result":{"changed":true,"message":"My Claude took a pass at it \#u{2014} reload the artifact to see if it renders now."},"error":null}]}
        """#
        try snapshot(
            PreviewHost(routes: LibrarySnapshotTests.routes + [.json(.get, "/api/jobs", jobs)]) {
                LibraryRootView().environment(\.scenePhase, .active)
            },
            named: "library-job-notice", settle: 2
        )
    }
}
