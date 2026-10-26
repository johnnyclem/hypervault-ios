import Foundation

// A minimal zip reader for data exports. ChatGPT, Claude and Grok send their
// histories as a zip that holds the conversation JSON beside account files and
// (for Grok) hundreds of megabytes of images. Reading the zip's directory and
// pulling out the few JSON entries it needs keeps the images untouched on
// disk. Foundation cannot inflate, so the app supplies the inflater (the
// system Compression framework); stored entries need none.

public enum ImportZipError: Error, Sendable, Equatable, LocalizedError {
    case notAZip
    case corrupt(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .notAZip: return "That file is not a zip archive."
        case .corrupt: return "That zip file looks damaged. Download the export again and retry."
        case .unsupported(let what): return "This zip uses something the app cannot open (\(what)). Unzip it in Files and pick conversations.json instead."
        }
    }
}

/// Turns raw DEFLATE data (what a zip stores) into a file.
public protocol ImportZipInflating: Sendable {
    func inflate(_ compressed: Data, to destination: URL) throws
}

public struct ImportZipEntry: Sendable, Hashable {
    public let name: String
    let flags: UInt16
    let method: UInt16
    public let compressedSize: UInt64
    public let uncompressedSize: UInt64
    let localOffset: UInt64

    public var isDirectory: Bool { name.hasSuffix("/") }
    public var lastComponent: String { name.split(separator: "/").last.map(String.init) ?? name }
}

/// The directory of a zip file on disk. Opening one reads only the directory
/// at the end of the file; entries are read on demand.
public struct ImportZipArchive: Sendable {
    /// The largest entry the app will unpack (the biggest histories are a few hundred MB).
    public static let maxEntryBytes: UInt64 = 1_500_000_000

    public let url: URL
    public let entries: [ImportZipEntry]

    public init(fileURL: URL) throws {
        url = fileURL
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        let size = try handle.seekToEnd()
        guard size >= 22 else { throw ImportZipError.notAZip }
        let tailLength = min(size, 22 + 65_535)
        try handle.seek(toOffset: size - tailLength)
        let tail = try handle.read(upToCount: Int(tailLength)) ?? Data()

        guard let eocd = Self.lastSignature(0x0605_4B50, in: tail) else { throw ImportZipError.notAZip }
        var entryCount = UInt64(tail.le16(eocd + 10))
        var directorySize = UInt64(tail.le32(eocd + 12))
        var directoryOffset = UInt64(tail.le32(eocd + 16))

        if entryCount == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            // ZIP64: the real numbers live in a second record the locator points to.
            guard eocd >= 20, tail.le32(eocd - 20) == 0x0706_4B50 else { throw ImportZipError.corrupt("zip64 locator") }
            let recordOffset = tail.le64(eocd - 20 + 8)
            try handle.seek(toOffset: recordOffset)
            let record = try handle.read(upToCount: 56) ?? Data()
            guard record.count >= 56, record.le32(0) == 0x0606_4B50 else { throw ImportZipError.corrupt("zip64 record") }
            entryCount = record.le64(32)
            directorySize = record.le64(40)
            directoryOffset = record.le64(48)
        }

        guard directorySize <= 256_000_000, directoryOffset <= size, directorySize <= size - directoryOffset else { throw ImportZipError.corrupt("directory") }
        try handle.seek(toOffset: directoryOffset)
        let directory = try handle.read(upToCount: Int(directorySize)) ?? Data()
        entries = try Self.parseDirectory(directory, count: Int(min(entryCount, 5_000_000)))
    }

    /// The JSON entries worth looking inside: not folders, not macOS resource
    /// forks, not absurdly large.
    public var jsonEntries: [ImportZipEntry] {
        entries.filter { entry in
            !entry.isDirectory
                && entry.name.lowercased().hasSuffix(".json")
                && !entry.name.hasPrefix("__MACOSX/")
                && !entry.lastComponent.hasPrefix("._")
                && entry.uncompressedSize > 2
                && entry.uncompressedSize <= Self.maxEntryBytes
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Writes one entry's bytes to `destination`.
    public func extract(_ entry: ImportZipEntry, to destination: URL, inflater: ImportZipInflating?) throws {
        guard entry.flags & 1 == 0 else { throw ImportZipError.unsupported("a password") }
        guard entry.method == 0 || entry.method == 8 else { throw ImportZipError.unsupported("compression method \(entry.method)") }
        guard entry.compressedSize <= Self.maxEntryBytes else { throw ImportZipError.unsupported("a very large file") }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: entry.localOffset)
        let header = try handle.read(upToCount: 30) ?? Data()
        guard header.count == 30, header.le32(0) == 0x0403_4B50 else { throw ImportZipError.corrupt("local header") }
        let dataStart = entry.localOffset + 30 + UInt64(header.le16(26)) + UInt64(header.le16(28))
        try handle.seek(toOffset: dataStart)

        if entry.method == 8 {
            guard let inflater else { throw ImportZipError.unsupported("compressed files") }
            let compressed = try handle.read(upToCount: Int(entry.compressedSize)) ?? Data()
            guard UInt64(compressed.count) == entry.compressedSize else { throw ImportZipError.corrupt("entry data") }
            try inflater.inflate(compressed, to: destination)
            return
        }

        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw ImportZipError.corrupt("could not write the temporary file")
        }
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }
        var remaining = entry.compressedSize
        while remaining > 0 {
            let chunk = try handle.read(upToCount: Int(min(remaining, 4_000_000))) ?? Data()
            guard !chunk.isEmpty else { throw ImportZipError.corrupt("entry data") }
            try out.write(contentsOf: chunk)
            remaining -= UInt64(chunk.count)
        }
    }

    // MARK: Directory

    private static func lastSignature(_ signature: UInt32, in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        var i = data.count - 22
        while i >= 0 {
            if data.le32(i) == signature { return i }
            i -= 1
        }
        return nil
    }

    private static func parseDirectory(_ data: Data, count: Int) throws -> [ImportZipEntry] {
        var entries: [ImportZipEntry] = []
        entries.reserveCapacity(min(count, 100_000))
        var p = 0
        for _ in 0..<count {
            guard p + 46 <= data.count, data.le32(p) == 0x0201_4B50 else { throw ImportZipError.corrupt("directory entry") }
            let flags = data.le16(p + 8)
            let method = data.le16(p + 10)
            var compressed = UInt64(data.le32(p + 20))
            var uncompressed = UInt64(data.le32(p + 24))
            let nameLength = Int(data.le16(p + 28))
            let extraLength = Int(data.le16(p + 30))
            let commentLength = Int(data.le16(p + 32))
            var offset = UInt64(data.le32(p + 42))
            let next = p + 46 + nameLength + extraLength + commentLength
            guard next <= data.count else { throw ImportZipError.corrupt("directory entry") }

            let nameBytes = data.subdata(in: (data.startIndex + p + 46)..<(data.startIndex + p + 46 + nameLength))
            let name = String(data: nameBytes, encoding: .utf8) ?? String(data: nameBytes, encoding: .isoLatin1) ?? ""

            // ZIP64 extra field (id 1): the fields whose 32-bit value is all ones, in this order.
            var x = p + 46 + nameLength
            let extraEnd = x + extraLength
            while x + 4 <= extraEnd {
                let id = data.le16(x)
                let size = Int(data.le16(x + 2))
                if id == 1 {
                    var y = x + 4
                    if uncompressed == 0xFFFF_FFFF, y + 8 <= extraEnd { uncompressed = data.le64(y); y += 8 }
                    if compressed == 0xFFFF_FFFF, y + 8 <= extraEnd { compressed = data.le64(y); y += 8 }
                    if offset == 0xFFFF_FFFF, y + 8 <= extraEnd { offset = data.le64(y) }
                }
                x += 4 + size
            }

            entries.append(ImportZipEntry(
                name: name, flags: flags, method: method,
                compressedSize: compressed, uncompressedSize: uncompressed, localOffset: offset
            ))
            p = next
        }
        return entries
    }
}

extension Data {
    // Little-endian reads that work on a slice too.
    fileprivate func byte(_ offset: Int) -> UInt64 {
        let index = startIndex + offset
        return index < endIndex ? UInt64(self[index]) : 0
    }

    fileprivate func le16(_ offset: Int) -> UInt16 {
        UInt16(byte(offset) | byte(offset + 1) << 8)
    }

    fileprivate func le32(_ offset: Int) -> UInt32 {
        UInt32(truncatingIfNeeded: byte(offset) | byte(offset + 1) << 8 | byte(offset + 2) << 16 | byte(offset + 3) << 24)
    }

    fileprivate func le64(_ offset: Int) -> UInt64 {
        UInt64(le32(offset)) | UInt64(le32(offset + 4)) << 32
    }
}
