import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Keeps a PDF or an image as a page: ask for a signed address, PUT the bytes
/// to it, then give the file its permanent link. The bytes go straight to
/// storage because a serverless body is too small for them.
public struct ArtifactUploader: Sendable {
    private let client: HVClient
    private let transport: HTTPTransport

    public init(client: HVClient, transport: HTTPTransport = URLSessionTransport()) {
        self.client = client
        self.transport = transport
    }

    public func upload(
        data: Data, filename: String, title: String? = nil, tags: [String] = [], visibility: ArtifactVisibility = .private
    ) async throws -> ArtifactSaveResult {
        guard let type = ArtifactFileType.forFilename(filename) else {
            throw HVError.invalidRequest("Unsupported file type. Upload a PDF or an image (png, jpg, gif, webp, svg).")
        }
        guard !data.isEmpty else { throw HVError.invalidRequest("That file is empty.") }

        let ticket = try await client.send(.artifactUploadTicket(filename: filename, size: data.count))
        guard let address = SignedUpload.address(from: ticket.signedUrl) else {
            throw SignedUpload.refusal(forAddress: ticket.signedUrl)
        }
        if let limit = ticket.maxBytes, data.count > limit {
            throw HVError.api(APIFailure(status: 413, message: "That file is too large."))
        }

        let response: HTTPResponse
        do {
            // The same PUT a memory file import makes: the type the server named, and no token of the app's.
            response = try await SignedUpload.put(
                data, to: address, contentType: ticket.contentType.isEmpty ? type.mime : ticket.contentType, using: transport
            )
        } catch {
            throw HVError.transport(error.localizedDescription)
        }
        guard (200..<300).contains(response.status) else {
            throw HVError.api(APIFailure(status: response.status, message: "The upload didn't go through. Try again."))
        }

        let base = (filename as NSString).deletingPathExtension
        return try await client.send(.importArtifactFile(path: ticket.path, title: title ?? (base.isEmpty ? nil : base), tags: tags, visibility: visibility))
    }
}
