import Foundation

// Room endpoints (docs/rooms.md). A message or a run can take up to two
// minutes: the server makes several model calls in one request (a message
// posted with `run: false` and a run limited with `turns` are the short ones).

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
    /// Says something to the room. The addressed members take turns (everyone, when nobody is addressed); what did
    /// not fit in the request comes back as `pending`.
    ///
    /// With `run: false` the server only keeps the message and queues the turns, and answers at once: the phone
    /// drives them one request at a time (`runRoom`) and shows each answer as it lands. A server that has not
    /// learned `run` ignores it and answers after the turns, as it always did, so the field is left out of the body
    /// unless it is asked for.
    public static func postRoomMessage(roomID: String, content: String, run: Bool = true) -> Endpoint<ChatRoomRun> {
        var object: [String: JSONValue] = ["content": .string(content)]
        if !run { object["run"] = .bool(false) }
        return Endpoint(
            .post, "/api/rooms/\(roomID)/messages", body: .jsonValue(.object(object)),
            timeout: chatTurnTimeout
        )
    }

    /// Continues the queued turns, at most `turns` of them (the server's own cap, three, when nil; it clamps what
    /// it is given). Safe to repeat: with an empty queue it does nothing, and `busy` says another run holds the
    /// room. A server that has not learned `turns` ignores it.
    public static func runRoom(id: String, turns: Int? = nil) -> Endpoint<ChatRoomRun> {
        Endpoint(
            .post, "/api/rooms/\(id)/run", query: .make([("turns", turns.map { String(Swift.max(1, $0)) })]),
            timeout: chatTurnTimeout, idempotent: true
        )
    }
}
