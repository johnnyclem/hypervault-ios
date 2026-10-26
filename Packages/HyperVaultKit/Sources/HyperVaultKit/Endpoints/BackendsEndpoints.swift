import Foundation

// Backend endpoints (`/api/backends`). The connect and edit calls make the
// server send a live test message to the model, which can take a minute.

/// The server's cap on the connect test is 60 seconds.
public let backendTestTimeout: TimeInterval = 75

private struct BackendsEnvelope: Decodable { let backends: [ChatBackend] }

extension Endpoint where Response == [ChatBackend] {
    /// The person's connected models, newest first. Keys are never in it.
    public static var backends: Endpoint<[ChatBackend]> {
        Endpoint(
            method: .get, path: "/api/backends",
            decode: { response, keys in
                do {
                    return try HVCoding.decoder(keys).decode(BackendsEnvelope.self, from: response.data).backends
                } catch {
                    throw HVError.decoding("\(error)")
                }
            }
        )
    }
}

extension Endpoint where Response == ChatBackendSaved {
    /// Connects a model. The key travels once, in this body, and only when the
    /// server says it can store keys safely (`serverCanStoreKeys`, from
    /// `Capabilities.Features.keyEncryption`).
    public static func connectBackend(_ draft: ChatBackendDraft, serverCanStoreKeys: Bool) -> Endpoint<ChatBackendSaved> {
        Endpoint(
            .post, "/api/backends",
            body: .jsonValue(draft.connectBody(serverCanStoreKeys: serverCanStoreKeys)),
            timeout: backendTestTimeout
        )
    }

    /// Edits a connected model in place. A blank key keeps the stored one; the
    /// provider is fixed. Changes to the key, model or address are re-tested.
    public static func updateBackend(
        id: String, _ draft: ChatBackendDraft, supportsEmbeddings: Bool, serverCanStoreKeys: Bool
    ) -> Endpoint<ChatBackendSaved> {
        Endpoint(
            .patch, "/api/backends",
            body: .jsonValue(draft.editBody(id: id, supportsEmbeddings: supportsEmbeddings, serverCanStoreKeys: serverCanStoreKeys)),
            timeout: backendTestTimeout
        )
    }
}

extension Endpoint where Response == NoContent {
    /// Disconnects a model. Rooms that used it lose that member.
    public static func disconnectBackend(id: String) -> Endpoint<NoContent> {
        Endpoint(.delete, "/api/backends", body: .jsonValue(["id": .string(id)]))
    }
}
