import HyperVaultKit
import SwiftUI
import XCTest
@testable import HyperVault

/// Every state is rendered with no delay on the canned answers, and given time to settle, so a screen is
/// never captured while it is still showing its loading skeleton.
@MainActor
final class TaskBoardSnapshotTests: XCTestCase {
    func testBoards() throws {
        try snapshot(PreviewHost(routes: TaskBoardPreviewData.indexRoutes, delay: 0) { TaskBoardsRootView() }, named: "taskboards-list", settle: 2)
    }

    func testNoBoards() throws {
        try snapshot(
            PreviewHost(routes: [.json(.get, "/api/taskboards", #"{"boards":[]}"#)], delay: 0) { TaskBoardsRootView() },
            named: "taskboards-empty", settle: 2
        )
    }

    func testBoard() throws {
        try snapshot(
            PreviewHost(routes: TaskBoardPreviewData.boardRoutes, delay: 0) { TaskBoardView(listing: TaskBoardPreviewData.listing) },
            named: "taskboards-board", settle: 2
        )
    }

    func testBoardAtLargeType() throws {
        try snapshot(
            PreviewHost(routes: TaskBoardPreviewData.boardRoutes, delay: 0) { TaskBoardView(listing: TaskBoardPreviewData.listing) }
                .environment(\.dynamicTypeSize, .accessibility2),
            named: "taskboards-board-large", settle: 2, schemes: [.light]
        )
    }

    func testTaskDetail() throws {
        let env = AppEnvironment.preview(routes: TaskBoardPreviewData.boardRoutes)
        let model = TaskBoardModel(client: env.client, cache: env.cache, namespace: "snap", project: "eurorack-choir", title: "Eurorack Choir Module")
        try snapshot(
            PreviewHost(delay: 0) { TaskDetailView(model: model, taskID: "t-panels").task { await model.start() } },
            named: "taskboards-task", settle: 2
        )
    }

    func testCreate() throws {
        try snapshot(PreviewHost(embedInNavigation: false) { TaskBoardCreateView { _ in } }, named: "taskboards-create", settle: 1)
    }
}
