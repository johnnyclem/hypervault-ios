import Foundation

/// A room's messages as this phone knows them, and the place to ask from for the rest.
///
/// The server gives every message of a room the next position, and a message is never there before the one under it
/// (positions are unique per room, and a writer that loses a slot takes the next), so "everything past the highest
/// position a read of the room reported" is a sound place to poll from. "The highest position I hold" is not: the
/// answer to `POST .../run` carries only what that one run wrote, so merging it would move the place past messages
/// another request wrote earlier (an answer whose response never reached the phone), and the poll would never fetch
/// them. A message that arrives with a post or a run is shown at once; only a read of the room moves the cursor.
public struct ChatRoomTranscript: Sendable, Equatable {
    /// Every message held, by position.
    public private(set) var messages: [ChatRoomMessage] = []
    /// The highest position a read of the room has reported (-1 for a room that was read empty); nil before any read.
    /// Ask for `after: cursor` to get what the room has said since.
    public private(set) var cursor: Int?
    private var ids: Set<String> = []

    public init() {}

    /// A read of the room: its newest messages when it was opened, or what came `after` the cursor in a poll. The
    /// messages are merged, and the cursor moves to the highest position the read reported. Returns the messages
    /// that were new, in position order.
    @discardableResult
    public mutating func apply(_ detail: ChatRoomDetail) -> [ChatRoomMessage] {
        let fresh = merge(detail.messages)
        if let top = detail.messages.map(\.position).max() {
            cursor = Swift.max(cursor ?? top, top)
        } else if cursor == nil {
            cursor = -1
        }
        return fresh
    }

    /// Messages that came with a post or a run. They are shown, and the cursor stays where it is. Returns the ones
    /// that were new, in position order. A message held already (by id) is not added twice.
    @discardableResult
    public mutating func merge(_ incoming: [ChatRoomMessage]) -> [ChatRoomMessage] {
        var fresh: [ChatRoomMessage] = []
        for message in incoming where ids.insert(message.id).inserted { fresh.append(message) }
        guard !fresh.isEmpty else { return [] }
        fresh.sort { $0.position < $1.position }
        messages = (messages + fresh).sorted { $0.position < $1.position }
        return fresh
    }

    /// Whether a message with this id is held.
    public func contains(id: String) -> Bool { ids.contains(id) }
}
