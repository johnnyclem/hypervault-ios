import Foundation

// The calls behind a kept page, file or group (`app/api/artifacts`,
// `app/api/save`, `app/api/artifact-groups`, `app/api/shares`,
// `app/api/connections`). Every one reads the same bearer token.

// MARK: Pages

extension Endpoint where Response == ArtifactList {
    /// The caller's 200 newest artifacts: pages, stored files and groups, without content.
    public static var artifacts: Endpoint<ArtifactList> {
        Endpoint(.get, "/api/artifacts")
    }
}

extension Endpoint where Response == ArtifactSaveResult {
    /// Keeps something an AI made. The server detects React and wraps it unless `forceHtml`;
    /// the same content kept twice answers the first link with `duplicate`.
    public static func saveArtifact(_ request: ArtifactSaveRequest) -> Endpoint<ArtifactSaveResult> {
        Endpoint(.post, "/api/save", body: .json(request))
    }

    /// Gives an uploaded PDF or image (see `artifactUploadTicket`) a permanent link.
    public static func importArtifactFile(path: String, title: String?, tags: [String] = [], visibility: ArtifactVisibility = .private) -> Endpoint<ArtifactSaveResult> {
        var body: [String: JSONValue] = [
            "path": .string(path),
            "tags": .array(tags.map(JSONValue.string)),
            "visibility": .string(visibility.rawValue),
        ]
        if let title, !title.isEmpty { body["title"] = .string(title) }
        return Endpoint(.post, "/api/artifacts/import-file", body: .jsonValue(.object(body)))
    }
}

extension Endpoint where Response == ArtifactPatchResult {
    /// Flips who can open a page. The owner may; so may a person with the edit role.
    public static func setArtifactVisibility(slug: String, to visibility: ArtifactVisibility) -> Endpoint<ArtifactPatchResult> {
        Endpoint(.patch, "/api/artifacts", body: .jsonValue(["slug": .string(slug), "visibility": .string(visibility.rawValue)]))
    }

    /// Sets the home-screen glyph, or clears it (nil) back to the title's initial. Owner only.
    public static func setArtifactIcon(slug: String, glyph: String?) -> Endpoint<ArtifactPatchResult> {
        Endpoint(.patch, "/api/artifacts", body: .jsonValue(["slug": .string(slug), "icon": glyph.map(JSONValue.string) ?? .null]))
    }
}

extension Endpoint where Response == ArtifactDeleteResult {
    /// Deletes a page for good: its link stops working and its connections go.
    public static func deleteArtifact(slug: String) -> Endpoint<ArtifactDeleteResult> {
        Endpoint(.delete, "/api/artifacts", body: .jsonValue(["slug": .string(slug)]))
    }
}

// MARK: Source and history

extension Endpoint where Response == ArtifactContent {
    /// The editable source and the commit it is at. `version` reads an earlier commit (the owner's only).
    public static func artifactContent(slug: String, version: String? = nil) -> Endpoint<ArtifactContent> {
        Endpoint(.get, "/api/artifacts/\(slug)/content", query: .make([("version", version)]))
    }
}

extension Endpoint where Response == ArtifactWriteResult {
    /// Commits a new version of a living page. A refusal (409, 412, 428) carries the head: read it with `ArtifactConflict`.
    public static func writeArtifact(slug: String, _ request: ArtifactWriteRequest) -> Endpoint<ArtifactWriteResult> {
        Endpoint(.put, "/api/artifacts/\(slug)/content", body: .json(request))
    }

    /// Makes an earlier version the head again, as a new commit. `baseVersionId` is the head the person looked at.
    public static func revertArtifact(slug: String, to versionId: String, base baseVersionId: String?) -> Endpoint<ArtifactWriteResult> {
        var body: [String: JSONValue] = ["version_id": .string(versionId)]
        if let baseVersionId { body["base_version_id"] = .string(baseVersionId) }
        return Endpoint(.post, "/api/artifacts/\(slug)/revert", body: .jsonValue(.object(body)))
    }
}

extension Endpoint where Response == ArtifactSource {
    /// The markup exactly as stored (for a React page, the wrapped page, not its JSX).
    public static func artifactSource(slug: String) -> Endpoint<ArtifactSource> {
        Endpoint(.get, "/api/artifacts/\(slug)/source")
    }
}

extension Endpoint where Response == ArtifactVersionList {
    public static func artifactVersions(slug: String, limit: Int = 100) -> Endpoint<ArtifactVersionList> {
        Endpoint(.get, "/api/artifacts/\(slug)/versions", query: [URLQueryItem(name: "limit", value: String(limit))])
    }
}

extension Endpoint where Response == ArtifactDiff {
    /// The unified diff from one commit to another; `to` defaults to the head.
    public static func artifactDiff(slug: String, from: String, to: String? = nil) -> Endpoint<ArtifactDiff> {
        Endpoint(.get, "/api/artifacts/\(slug)/diff", query: .make([("from", from), ("to", to)]))
    }
}

// MARK: Feedback and repair

extension Endpoint where Response == ArtifactFeedbackState {
    public static func artifactFeedback(slug: String) -> Endpoint<ArtifactFeedbackState> {
        Endpoint(.get, "/api/artifacts/\(slug)/feedback")
    }
}

extension Endpoint where Response == ArtifactMessage {
    /// A thumb on a page; nil clears the rating.
    public static func rateArtifact(slug: String, _ feedback: ArtifactFeedback?) -> Endpoint<ArtifactMessage> {
        Endpoint(.post, "/api/artifacts/\(slug)/feedback", body: .jsonValue(["feedback": feedback.map { JSONValue.string($0.rawValue) } ?? JSONValue.null]))
    }
}

extension Endpoint where Response == ArtifactRepairStart {
    /// Hands a broken page to the person's connected model. It answers at once with a job to poll.
    public static func repairArtifact(slug: String, renderError: String? = nil) -> Endpoint<ArtifactRepairStart> {
        var body: [String: JSONValue] = [:]
        if let renderError, !renderError.isEmpty { body["render_error"] = .string(String(renderError.prefix(2_000))) }
        return Endpoint(.post, "/api/artifacts/\(slug)/repair", body: .jsonValue(.object(body)))
    }
}

extension Endpoint where Response == ArtifactJob {
    public static func artifactJob(id: String) -> Endpoint<ArtifactJob> {
        Endpoint(
            method: .get, path: "/api/jobs/\(id)"
        ) { response, keys in
            do {
                return try HVCoding.decoder(keys).decode(ArtifactJobEnvelope.self, from: response.data).job
            } catch {
                throw HVError.decoding("\(error)")
            }
        }
    }
}

extension Endpoint where Response == NoContent {
    /// Tells the server a finished job has been seen, so it stops being announced.
    public static func acknowledgeArtifactJob(id: String) -> Endpoint<NoContent> {
        Endpoint(.post, "/api/jobs/\(id)")
    }
}

// MARK: People

extension Endpoint where Response == ArtifactShareList {
    /// Who has the page. The owner's to read; anyone else is told there is no such page.
    public static func artifactShares(slug: String) -> Endpoint<ArtifactShareList> {
        Endpoint(.get, "/api/shares", query: [URLQueryItem(name: "artifact", value: slug)])
    }
}

extension Endpoint where Response == ArtifactShareAdded {
    /// Gives a person with an account a role on the page; adding them again with another role changes it.
    public static func shareArtifact(slug: String, email: String, role: ArtifactShareRole) -> Endpoint<ArtifactShareAdded> {
        Endpoint(
            .post, "/api/shares",
            body: .jsonValue(["artifact": .string(slug), "email": .string(email.trimmingCharacters(in: .whitespacesAndNewlines)), "role": .string(role.rawValue)]),
            idempotent: true
        )
    }
}

extension Endpoint where Response == ArtifactMessage {
    /// Ends a share: the owner removes a person, a person leaves.
    public static func endShare(id: String) -> Endpoint<ArtifactMessage> {
        Endpoint(.delete, "/api/shares", body: .jsonValue(["share_id": .string(id)]))
    }
}

// MARK: Passwords

extension Endpoint where Response == ArtifactPasswordList {
    public static func artifactPasswords(slug: String) -> Endpoint<ArtifactPasswordList> {
        Endpoint(.get, "/api/artifacts/\(slug)/passwords")
    }
}

extension Endpoint where Response == ArtifactPasswordMinted {
    /// Mints a password (a blank `password` has the server make one). It is returned once, here.
    public static func mintArtifactPassword(slug: String, password: String? = nil, label: String? = nil, maxUses: Int? = nil) -> Endpoint<ArtifactPasswordMinted> {
        var body: [String: JSONValue] = [:]
        if let password, !password.isEmpty { body["password"] = .string(password) }
        if let label, !label.isEmpty { body["label"] = .string(label) }
        if let maxUses { body["maxUses"] = .int(maxUses) }
        return Endpoint(.post, "/api/artifacts/\(slug)/passwords", body: .jsonValue(.object(body)))
    }
}

extension Endpoint where Response == ArtifactPassword {
    public static func setArtifactPasswordDisabled(slug: String, id: String, disabled: Bool) -> Endpoint<ArtifactPassword> {
        Endpoint(
            method: .patch, path: "/api/artifacts/\(slug)/passwords/\(id)",
            body: .jsonValue(["disabled": .bool(disabled)])
        ) { response, keys in
            do {
                return try HVCoding.decoder(keys).decode(ArtifactPasswordEnvelope.self, from: response.data).password
            } catch {
                throw HVError.decoding("\(error)")
            }
        }
    }
}

extension Endpoint where Response == NoContent {
    public static func deleteArtifactPassword(slug: String, id: String) -> Endpoint<NoContent> {
        Endpoint(.delete, "/api/artifacts/\(slug)/passwords/\(id)")
    }
}

// MARK: Connections

extension Endpoint where Response == ArtifactEdges {
    /// Every edge the caller owns. Edge ids name an artifact by its row id, not its slug.
    public static var artifactEdges: Endpoint<ArtifactEdges> {
        Endpoint(.get, "/api/connections")
    }
}

extension Endpoint where Response == ArtifactConnected {
    /// Connects two things the caller owns, each an id, a slug or a title.
    public static func connectArtifact(source: String, target: String) -> Endpoint<ArtifactConnected> {
        Endpoint(.post, "/api/connections", body: .jsonValue(["source": .string(source), "target": .string(target)]), idempotent: true)
    }
}

extension Endpoint where Response == NoContent {
    public static func disconnect(edge id: String) -> Endpoint<NoContent> {
        Endpoint(.delete, "/api/connections", body: .jsonValue(["id": .string(id)]))
    }
}

// MARK: Groups

extension Endpoint where Response == ArtifactGroupList {
    public static var artifactGroups: Endpoint<ArtifactGroupList> {
        Endpoint(.get, "/api/artifact-groups")
    }
}

extension Endpoint where Response == ArtifactGroupDetail {
    /// A group and every file's content. The owner's only.
    public static func artifactGroup(slug: String) -> Endpoint<ArtifactGroupDetail> {
        Endpoint(.get, "/api/artifact-groups/\(slug)")
    }
}

extension Endpoint where Response == ArtifactGroupCreated {
    public static func createArtifactGroup(title: String, files: [ArtifactGroupFile], tags: [String], visibility: ArtifactVisibility) -> Endpoint<ArtifactGroupCreated> {
        let list = files.map { JSONValue.object(["path": .string($0.path), "content": .string($0.content)]) }
        let body: JSONValue = [
            "title": .string(title),
            "files": .array(list),
            "tags": .array(tags.map(JSONValue.string)),
            "visibility": .string(visibility.rawValue),
        ]
        return Endpoint(.post, "/api/artifact-groups", body: .jsonValue(body))
    }
}

extension Endpoint where Response == ArtifactMessage {
    /// Changes a group's title, tags or visibility; its files have their own calls.
    public static func updateArtifactGroup(slug: String, title: String? = nil, tags: [String]? = nil, visibility: ArtifactVisibility? = nil) -> Endpoint<ArtifactMessage> {
        var body: [String: JSONValue] = [:]
        if let title { body["title"] = .string(title) }
        if let tags { body["tags"] = .array(tags.map(JSONValue.string)) }
        if let visibility { body["visibility"] = .string(visibility.rawValue) }
        return Endpoint(.patch, "/api/artifact-groups/\(slug)", body: .jsonValue(.object(body)))
    }

    public static func deleteArtifactGroup(slug: String) -> Endpoint<ArtifactMessage> {
        Endpoint(.delete, "/api/artifact-groups/\(slug)")
    }

    /// Adds a file. 409 when the path is already there.
    public static func addGroupFile(slug: String, path: String, content: String) -> Endpoint<ArtifactMessage> {
        Endpoint(.post, "/api/artifact-groups/\(slug)/files", body: .jsonValue(["path": .string(path), "content": .string(content)]))
    }

    /// Overwrites a file. The path is the group's own, with its slashes.
    public static func writeGroupFile(slug: String, path: String, content: String) -> Endpoint<ArtifactMessage> {
        Endpoint(.put, "/api/artifact-groups/\(slug)/files/\(path)", body: .jsonValue(["content": .string(content)]), idempotent: true)
    }

    /// Removes a file. The root index.html is refused.
    public static func deleteGroupFile(slug: String, path: String) -> Endpoint<ArtifactMessage> {
        Endpoint(.delete, "/api/artifact-groups/\(slug)/files/\(path)")
    }
}

// MARK: Stored files

extension Endpoint where Response == ArtifactUploadTicket {
    /// Asks for a signed address to PUT a PDF or image to. 413 when it is over the plan's limit.
    public static func artifactUploadTicket(filename: String, size: Int) -> Endpoint<ArtifactUploadTicket> {
        Endpoint(.post, "/api/artifacts/upload-url", body: .jsonValue(["filename": .string(filename), "size": .int(size)]))
    }
}

// MARK: Addresses and pins

/// What `PATCH /api/claim-domain` answers when it set or cleared a home page.
public struct ArtifactRealmHomeResult: Sendable, Decodable {
    public let domain: String
    public let defaultArtifact: String?
    public let url: String?
    /// A private or password page still serves: as its lock screen. The server says so.
    public let warning: String?
    public let message: String

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        domain = try c.decodeIfPresent(String.self, forKey: .domain) ?? ""
        defaultArtifact = try c.decodeIfPresent(String.self, forKey: .defaultArtifact)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        warning = try c.decodeIfPresent(String.self, forKey: .warning)
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
    }

    enum Keys: String, CodingKey { case domain, defaultArtifact, url, warning, message }
}

extension Endpoint where Response == ArtifactRealmHomeResult {
    /// Makes a claimed address open on one of the person's pages (nil: back to the vault index).
    /// Single pages only; a group is refused.
    public static func setRealmHome(subdomain: String, baseDomain: String, slug: String?) -> Endpoint<ArtifactRealmHomeResult> {
        Endpoint(
            .patch, "/api/claim-domain",
            body: .jsonValue([
                "subdomain": .string(subdomain),
                "base_domain": .string(baseDomain),
                "default_artifact": slug.map(JSONValue.string) ?? .null,
            ]),
            idempotent: true
        )
    }
}

struct SidebarPinsBody: Sendable, Encodable {
    let pins: [SidebarPin]
}

extension Endpoint where Response == NoContent {
    /// Replaces the whole side-menu pin list, in display order.
    public static func replaceSidebarPins(_ pins: [SidebarPin]) -> Endpoint<NoContent> {
        Endpoint(.patch, "/api/sidebar-pins", body: .json(SidebarPinsBody(pins: pins)), idempotent: true)
    }
}
