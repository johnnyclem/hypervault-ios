import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Turns a file (a PDF, a Word document, Markdown, text) into a memory, however big the server allows it to be.
///
/// A file that fits in the import request goes in it, as it always has (`Endpoint.memoryImport(filename:data:)`).
/// A larger one, up to `Limits.importFileBytes`, cannot: the platform turns away a request body of about 4.5 MB
/// before the route runs, so the file is put in storage first and the request only names it:
///
///   1. `POST /api/memories/import/upload-url` says where, and which `Content-Type` the PUT must carry;
///   2. the bytes are PUT to that address with no token of the app's (the address carries its own permission);
///   3. `POST /api/memories/import` with `{ upload, filename }` reads the file from storage and makes the memory.
///
/// Cancelling the task stops it: the request in flight ends as `HVError.cancelled` (not a failure to word: the person
/// asked for it) and nothing is sent after it. A cancel that comes after the import was asked for cannot undo it; the
/// server may still make the memory.
///
/// Every step fails with a sentence a person can read: the server's own for steps 1 and 3 (`HVError.userMessage`),
/// the app's for step 2, which storage answers in a way that means nothing to a person.
public struct MemoryFileImporter: Sendable {
    /// Where a staged import is. The inline path is one request and has no stages to report.
    public enum Stage: Sendable, Equatable {
        /// Asking where to put the file, and putting it there: the long part for a big file.
        case uploading
        /// The file is in storage and the server is reading it into a memory.
        case reading

        public var line: String {
            switch self {
            case .uploading: return "Uploading the file…"
            case .reading: return "Reading the file…"
            }
        }
    }

    /// What storage's refusal of the PUT is turned into, when it is not that the file is too big.
    public static let storageFailedLine = "The upload to storage didn't go through. Try again in a moment."

    private let client: HVClient
    private let transport: HTTPTransport
    private let limits: Capabilities.Limits

    /// `transport` carries only the PUT to storage; every call to the app's server goes through `client`.
    public init(client: HVClient, limits: Capabilities.Limits, transport: HTTPTransport = URLSessionTransport()) {
        self.client = client
        self.limits = limits
        self.transport = transport
    }

    /// Sends the file by the way its size allows and answers with the memory it became. A file that is over the
    /// limit, or not a kind the import reads, is refused before anything is sent. `progress` is told when a staged
    /// import moves to its next stage.
    public func importFile(
        filename: String, data: Data, branch: String? = nil, progress: (@MainActor @Sendable (Stage) -> Void)? = nil
    ) async throws -> MemoryKept {
        if let refusal = MemoryImportPolicy.problem(filename: filename, byteCount: data.count, limits: limits) {
            throw HVError.invalidRequest(refusal)
        }
        guard let kind = MemoryImportPolicy.kind(forFilename: filename),
              let route = MemoryImportPolicy.route(byteCount: data.count, limits: limits)
        else { throw HVError.invalidRequest(MemoryImportPolicy.unsupportedTypeMessage) }

        switch route {
        case .inline:
            return try await client.send(.memoryImport(filename: filename, data: data, branch: branch))
        case .staged:
            await progress?(.uploading)
            let ticket = try await client.send(.memoryImportUploadURL(filename: filename, size: data.count))
            try await put(data, to: ticket, filename: filename, kind: kind)
            // Cancelled just as the last byte went: the file stays in storage for the sweep, and nobody is told the
            // server is reading it.
            if Task.isCancelled { throw HVError.cancelled }
            await progress?(.reading)
            return try await client.send(.memoryImport(upload: ticket.path, filename: filename, branch: branch))
        }
    }

    private func put(_ data: Data, to ticket: MemoryUploadTicket, filename: String, kind: MemoryImportPolicy.FileKind) async throws {
        guard let address = SignedUpload.address(from: ticket.signedUrl) else {
            throw HVError.decoding("The upload address was not a link.")
        }
        let response: HTTPResponse
        do {
            // The type the server named is the one storage will accept; the one the file's name implies is only the
            // fallback for a server that did not name it.
            response = try await SignedUpload.put(data, to: address, contentType: ticket.contentType ?? kind.mimeType, using: transport)
        } catch is CancellationError {
            throw HVError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw HVError.cancelled
        } catch {
            throw HVError.transport(error.localizedDescription)
        }
        guard (200..<300).contains(response.status) else {
            throw Self.storageFailure(status: response.status, filename: filename, limitBytes: ticket.maxBytes ?? limits.importFileBytes)
        }
    }

    /// The failure for storage turning the PUT away. It carries a code so that `MemoryImportPolicy.message(for:)`
    /// leaves the sentence alone: it is the app's wording, not the platform's plain-text 413.
    static func storageFailure(status: Int, filename: String, limitBytes: Int) -> HVError {
        if status == 413 {
            let sentence = MemoryImportPolicy.overTheLimit(filename: filename, label: MemoryLimits.label(forBytes: limitBytes))
            return .api(APIFailure(status: status, message: sentence, code: "storage_file_too_large"))
        }
        return .api(APIFailure(status: status, message: storageFailedLine, code: "storage_upload_failed"))
    }
}
