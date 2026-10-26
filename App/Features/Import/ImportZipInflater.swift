import Compression
import Foundation
import HyperVaultKit

/// Inflates what a zip stores (raw DEFLATE, with no zlib header) into a file,
/// a megabyte at a time, with the system's Compression framework. The Kit's
/// zip reader hands over the compressed bytes of one entry; the result can be
/// hundreds of megabytes, so it is streamed to disk instead of held in memory.
struct ImportZipInflater: ImportZipInflating {
    func inflate(_ compressed: Data, to destination: URL) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw ImportZipError.corrupt("could not write the temporary file")
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        var writeError: Error?
        let filter = try OutputFilter(.decompress, using: .zlib) { chunk in
            guard let chunk, writeError == nil else { return }
            do { try output.write(contentsOf: chunk) } catch { writeError = error }
        }

        let step = 1 << 20
        var offset = 0
        do {
            while offset < compressed.count {
                let end = min(offset + step, compressed.count)
                try filter.write(compressed[offset..<end])
                if let writeError { throw writeError }
                offset = end
            }
            try filter.finalize()
        } catch let error as ImportZipError {
            throw error
        } catch {
            if let writeError { throw writeError }
            throw ImportZipError.corrupt("deflate")
        }
        if let writeError { throw writeError }
    }
}
