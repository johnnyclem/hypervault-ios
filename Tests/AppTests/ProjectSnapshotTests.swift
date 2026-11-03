import HyperVaultKit
import SwiftUI
import UIKit
import XCTest
@testable import HyperVault

/// A project's overview, rendered with no delay on the canned answers and given time to settle, so a screen is never captured
/// while it is still showing its loading skeleton.
@MainActor
final class ProjectSnapshotTests: XCTestCase {
    private let project = "eurorack-choir"

    func testOverview() throws {
        try snapshot(
            PreviewHost(routes: ProjectPreviewData.overviewRoutes, delay: 0) { ProjectOverviewView(project: project) },
            named: "projects-overview", settle: 2, schemes: [.dark, .light]
        )
    }

    /// The same, with "Show possibly related" open: the pages and memories the server only guessed at, each saying so.
    func testOverviewWithThePossiblyRelatedShown() throws {
        try snapshot(
            PreviewHost(routes: ProjectPreviewData.overviewRoutes, delay: 0) { ProjectOverviewView(project: project, showPossibly: true) },
            named: "projects-overview-possibly", settle: 2
        )
    }

    /// Nine pages tagged for the project: six, and "Show 3 more".
    func testOverviewWithASectionThatHasMore() throws {
        try snapshot(
            PreviewHost(routes: ProjectPreviewData.longRoutes, delay: 0) { ProjectOverviewView(project: project) },
            named: "projects-overview-long", settle: 2
        )
    }

    func testOverviewAtLargeType() throws {
        try snapshot(
            PreviewHost(routes: ProjectPreviewData.overviewRoutes, delay: 0) { ProjectOverviewView(project: project) }
                .environment(\.dynamicTypeSize, .accessibility2),
            named: "projects-overview-large", settle: 2
        )
    }

    /// A board and nothing else in the vault.
    func testOverviewWithOnlyTheBoard() throws {
        try snapshot(
            PreviewHost(routes: ProjectPreviewData.emptyRoutes, delay: 0) { ProjectOverviewView(project: project) },
            named: "projects-overview-empty", settle: 2
        )
    }

    /// The chat list will not load: that section says so, and the rest is there.
    func testOverviewWhenTheChatsWillNotLoad() throws {
        try snapshot(
            PreviewHost(routes: ProjectPreviewData.partialRoutes, delay: 0) { ProjectOverviewView(project: project) },
            named: "projects-overview-partial", settle: 2
        )
    }

    /// A link to a project that is not in this vault: the server's words and nothing else.
    func testOverviewOfAProjectThatIsNotHere() throws {
        try snapshot(
            PreviewHost(routes: ProjectPreviewData.missingRoutes, delay: 0) { ProjectOverviewView(project: project) },
            named: "projects-overview-missing", settle: 2
        )
    }
}
