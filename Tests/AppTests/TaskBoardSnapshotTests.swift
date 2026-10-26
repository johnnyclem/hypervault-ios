import HyperVaultKit
import SwiftUI
import XCTest
@testable import HyperVault

@MainActor
final class TaskBoardSnapshotTests: XCTestCase {
    func testBoards() throws {
        try snapshot(PreviewHost(routes: TaskBoardPreviewData.indexRoutes) { TaskBoardsRootView() }, named: "taskboards-list")
    }

    func testNoBoards() throws {
        try snapshot(
            PreviewHost(routes: [.json(.get, "/api/taskboards", #"{"boards":[]}"#)]) { TaskBoardsRootView() },
            named: "taskboards-empty"
        )
    }

    func testBoard() throws {
        try snapshot(
            PreviewHost(routes: TaskBoardPreviewData.boardRoutes) { TaskBoardView(listing: TaskBoardPreviewData.listing) },
            named: "taskboards-board"
        )
    }

    func testTaskDetail() throws {
        let env = AppEnvironment.preview(routes: TaskBoardPreviewData.boardRoutes)
        let model = TaskBoardModel(client: env.client, cache: env.cache, namespace: "snap", project: "eurorack-choir", title: "Eurorack Choir Module")
        try snapshot(
            PreviewHost { TaskDetailView(model: model, taskID: "t-panels").task { await model.start() } },
            named: "taskboards-task"
        )
    }

    func testCreate() throws {
        try snapshot(PreviewHost(embedInNavigation: false) { TaskBoardCreateView { _ in } }, named: "taskboards-create")
    }
}
