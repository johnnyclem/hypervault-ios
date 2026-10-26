import Foundation

// Room endpoints (docs/rooms.md). A message or a run can take up to two
// minutes: the server makes several model calls in one request.

private struct RoomsEnvelope: Decodable { let rooms: [ChatRoomSummary] }
private struct MembersEnvelope: Decodable { let members: [ChatRoomMember] }

extension Endpoint where Response == [ChatRoomSummary] {
    /// The person's rooms, newest activity first, with members and queued turns.
    public static var rooms: Endpoint<[ChatRoomSummary]> {
        Endpoint(
            method: .get, path: "/api/rooms",
            decode: { response, keys in
                do {
                    return try HVCoding.decoder(keys).decode(RoomsEnvelope.self, from: response.data).rooms
                } catch {
                    throw HVError.decoding("\(error)")
                }
            }
        )
    }
}

extension Endpoint where Response == ChatRoomDetail {
    /// A room with its members and transcript. `after` returns only messages
    /// past that position, the cheap way to poll.
    public static func room(id: String, after position: Int? = nil) -> Endpoint<ChatRoomDetail> {
        Endpoint(.get, "/api/rooms/\(id)", query: .make([("after", position.map(String.init))]))
    }
}

extension Endpoint where Response == ChatRoomCreated {
    /// Starts a room. Handles must be unique and URL-safe; the backends must be the person's own.
    public static func createRoom(title: String?, members: [ChatRoomMemberDraft]) -> Endpoint<ChatRoomCreated> {
        var object: [String: JSONValue] = ["members": .array(members.map(\.json))]
        let name = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { object["title"] = .string(String(name.prefix(ChatRoomHandles.maxTitle))) }
        return Endpoint(.post, "/api/rooms", body: .jsonValue(.object(object)))
    }
}

extension Endpoint where Response == NoContent {
    public static func renameRoom(id: String, title: String) -> Endpoint<NoContent> {
        Endpoint(.patch, "/api/rooms/\(id)", body: .jsonValue(["title": .string(title)]))
    }

    /// Deletes the room and its transcript.
    public static func deleteRoom(id: String) -> Endpoint<NoContent> {
        Endpoint(.delete, "/api/rooms/\(id)")
    }

    public static func removeRoomMember(roomID: String, memberID: String) -> Endpoint<NoContent> {
        Endpoint(.delete, "/api/rooms/\(roomID)/members", body: .jsonValue(["member_id": .string(memberID)]))
    }
}

extension Endpoint where Response == [ChatRoomMember] {
    public static func addRoomMembers(roomID: String, members: [ChatRoomMemberDraft]) -> Endpoint<[ChatRoomMember]> {
        Endpoint(
            method: .post, path: "/api/rooms/\(roomID)/members",
            body: .jsonValue(["members": .array(members.map(\.json))]),
            decode: { response, keys in
                do {
                    return try HVCoding.decoder(keys).decode(MembersEnvelope.self, from: response.data).members
                } catch {
                    throw HVError.decoding("\(error)")
                }
            }
        )
    }
}

extension Endpoint where Response == ChatRoomRun {
    /// Says something to the room. The addressed members take turns (everyone,
    /// when nobody is addressed); what did not fit in the request comes back as `pending`.
    public static func postRoomMessage(roomID: String, content: String) -> Endpoint<ChatRoomRun> {
        Endpoint(
            .post, "/api/rooms/\(roomID)/messages", body: .jsonValue(["content": .string(content)]),
            timeout: chatTurnTimeout
        )
    }

    /// Continues the queued turns. Safe to repeat: with an empty queue it does
    /// nothing, and `busy` says another run holds the room.
    public static func runRoom(id: String) -> Endpoint<ChatRoomRun> {
        Endpoint(.post, "/api/rooms/\(id)/run", timeout: chatTurnTimeout, idempotent: true)
    }
}
