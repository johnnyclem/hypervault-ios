import Foundation
import HyperVaultKit

/// What reading the chosen files turned up.
struct ImportReadResult: Sendable {
    var documents: [ImportDocument] = []
    /// Plain sentences about what was done ("Used 2 of the 9 JSON files in export.zip").
    var notes: [String] = []
    /// Temporary copies that back the documents; deleted when the import is over.
    var temporaryFiles: [URL] = []
}

enum ImportFileReader {
    /// Reads picked files: JSON and text as they are, a zip by looking
    /// through its JSON files for the ones that hold conversations. The work is
    /// done on a background thread; a big export is read from disk by the
    /// system as needed, not loaded into memory.
    static func read(_ urls: [URL], chosen: ImportPlatform?) async throws -> ImportReadResult {
        let work = Task.detached(priority: .userInitiated) { () throws -> ImportReadResult in
            var result = ImportReadResult()
            do {
                for url in urls {
                    try Task.checkCancellation()
                    try readOne(url, chosen: chosen, into: &result)
                }
            } catch {
                remove(result.temporaryFiles)
                throw error
            }
            result.documents = keepTheMainService(result.documents, notes: &result.notes)
            return result
        }
        // A detached task does not hear that its caller was cancelled.
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private static func readOne(_ url: URL, chosen: ImportPlatform?, into result: inout ImportReadResult) throws {
        let copy = try temporaryCopy(of: url)
        result.temporaryFiles.append(copy)
        let name = url.lastPathComponent

        guard isZip(copy) else {
            let data = try Data(contentsOf: copy, options: .alwaysMapped)
            result.documents.append(ImportInspector.inspect(data, name: name, hint: chosen))
            return
        }

        let archive: ImportZipArchive
        do {
            archive = try ImportZipArchive(fileURL: copy)
        } catch {
            throw ImportReadError(message: (error as? LocalizedError)?.errorDescription ?? "That zip file could not be opened.")
        }
        let candidates = Array(archive.jsonEntries.prefix(300))
        var used = 0
        for entry in candidates {
            try Task.checkCancellation()
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("hv-import-\(UUID().uuidString).json")
            do {
                try archive.extract(entry, to: out, inflater: ImportZipInflater())
            } catch let error as ImportZipError {
                try? FileManager.default.removeItem(at: out)
                // One file this app cannot open is not the end of the others.
                if case .unsupported = error, candidates.count > 1 { continue }
                throw ImportReadError(message: error.errorDescription ?? "That zip file could not be read.")
            }
            guard let data = try? Data(contentsOf: out, options: .alwaysMapped) else {
                try? FileManager.default.removeItem(at: out)
                continue
            }
            let document = ImportInspector.inspect(data, name: entry.lastComponent, hint: chosen)
            if document.isImportable {
                result.documents.append(document)
                result.temporaryFiles.append(out)
                used += 1
            } else {
                try? FileManager.default.removeItem(at: out)
            }
        }
        let skippedImages = archive.entries.count - candidates.count
        var note = "Looked through \(candidates.count) JSON file\(candidates.count == 1 ? "" : "s") in \(name)"
        note += used == 0 ? " and found no conversations." : " and used \(used)."
        if skippedImages > 0 { note += " Images and other files stayed in the zip." }
        result.notes.append(note)
    }

    /// Many files can be picked at once; a zip also holds JSON of other kinds.
    /// Keep the service with the most conversations so a stray file cannot
    /// mix into the import.
    static func keepTheMainService(_ documents: [ImportDocument], notes: inout [String]) -> [ImportDocument] {
        let importable = documents.filter(\.isImportable)
        if importable.isEmpty { return documents }
        guard importable.count > 1 else { return importable }
        var counts: [ImportPlatform: Int] = [:]
        for document in importable { counts[document.platform, default: 0] += document.conversationCount }
        guard counts.count > 1, let winner = counts.max(by: { $0.value < $1.value })?.key else { return importable }
        let kept = importable.filter { $0.platform == winner }
        notes.append("Found more than one kind of history; importing the \(winner.title) one.")
        return kept
    }

    // MARK: Files

    /// A copy in the app's temporary folder. Coordinating the read makes iOS
    /// download a file that lives in iCloud Drive first.
    private static func temporaryCopy(of url: URL) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("hv-import-\(UUID().uuidString)-\(url.lastPathComponent)")
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { readable in
            do { try FileManager.default.copyItem(at: readable, to: destination) } catch { copyError = error }
        }
        if let failure = coordinationError ?? copyError as NSError? {
            throw ImportReadError(message: "That file could not be read (\(failure.localizedDescription)). If it is in iCloud, open it in Files once so it downloads, then try again.")
        }
        return destination
    }

    private static func isZip(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 4)) ?? Data()
        return head.count == 4 && head[0] == 0x50 && head[1] == 0x4B && head[2] == 0x03 && head[3] == 0x04
    }

    static func remove(_ files: [URL]) {
        for file in files { try? FileManager.default.removeItem(at: file) }
    }
}

struct ImportReadError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
