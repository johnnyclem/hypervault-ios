import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

/// Helpers the room tests share: a client over a transport, messages and room reads to build, and a way to wait for
/// something another task is doing.
class RoomTestCase: XCTestCase {
    let base = URL(string: "https://hv.test")!

    func client(_ transport: any HTTPTransport) -> HVClient {
        HVClient(baseURL: base, transport: transport, tokens: StaticTokenProvider(), retry: .none, sleep: { _ in })
    }

    func message(_ id: String, _ position: Int, kind: ChatRoomMessage.Sender = .agent, handle: String? = "claude") -> ChatRoomMessage {
        ChatRoomMessage(id: id, position: position, senderKind: kind, senderHandle: handle, content: "words")
    }

    func detail(_ messages: [ChatRoomMessage], running: Bool = false, pending: [String] = [], current: String? = nil) -> ChatRoomDetail {
        ChatRoomDetail(
            room: ChatRoomHeader(
                id: "r1", title: "All hands", pending: pending.map { ChatRoomTurn(handle: $0) }, budget: 12, running: running,
                current: current.map { ChatRoomCurrentTurn(handle: $0) }
            ),
            members: [], messages: messages
        )
    }

    /// Fails the test, rather than hanging it, when `condition` does not come true in time.
    func eventually(_ what: String, timeout: Double = 5, _ condition: @escaping @Sendable () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for: \(what)", file: file, line: line)
    }

    static let emptyRoom = #"{"room":{"id":"r1","title":"T","pending":[],"budget":12,"running":false},"members":[],"messages":[]}"#
}
