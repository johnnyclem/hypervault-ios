import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HyperVaultKit

final class ImportZipTests: XCTestCase {
    /// Made with Python's zipfile (deflate for the two JSON files, stored for the
    /// rest), the way a data export is packed: a folder entry, a macOS resource
    /// fork, an image beside the conversations.
    static let exportZip = "UEsDBBQAAAAAADIOWl0AAAAAAAAAAAAAAAAHAAAAZXhwb3J0L1BLAwQUAAAACAAAACEALFbcUXUAAADLAAAAGQAAAGV4cG9ydC9jb252ZXJzYXRpb25zLmpzb26LrlbKTFGyUlBKNlTSUVAqySzJSQVxPVJzcvJBIrmJBQWZeelAsWqlRDAJUZ8IlkwtLk5MB2nIK83JAQoUJBal5pUg+MkZmTkpQCGgSHRsbS1IpLQIpCQ+Lz8lFWIOUBTuCCMURwSnJufnpaC5AoshIMtqYwFQSwMEFAAAAAgAAAAhAE3rQtEdAAAAHgAAABAAAABleHBvcnQvdXNlci5qc29uq1bKTFGyUlAqVdJRUErNTczMAfESHZL0kvOVagFQSwMEFAAAAAAAAAAhAGVKBAwwAAAAMAAAABcAAABleHBvcnQvaW1hZ2VzL3Bob3RvLnBuZ4lQTkcNChoKMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMFBLAwQUAAAAAAAAACEAOZz7BgQAAAAEAAAAJAAAAF9fTUFDT1NYL2V4cG9ydC8uX2NvbnZlcnNhdGlvbnMuanNvbmp1bmtQSwECFAMUAAAAAAAyDlpdAAAAAAAAAAAAAAAABwAAAAAAAAAAABAA/UEAAAAAZXhwb3J0L1BLAQIUAxQAAAAIAAAAIQAsVtxRdQAAAMsAAAAZAAAAAAAAAAAAAACAASUAAABleHBvcnQvY29udmVyc2F0aW9ucy5qc29uUEsBAhQDFAAAAAgAAAAhAE3rQtEdAAAAHgAAABAAAAAAAAAAAAAAAIAB0QAAAGV4cG9ydC91c2VyLmpzb25QSwECFAMUAAAAAAAAACEAZUoEDDAAAAAwAAAAFwAAAAAAAAAAAAAAgAEcAQAAZXhwb3J0L2ltYWdlcy9waG90by5wbmdQSwECFAMUAAAAAAAAACEAOZz7BgQAAAAEAAAAJAAAAAAAAAAAAAAAgAGBAQAAX19NQUNPU1gvZXhwb3J0Ly5fY29udmVyc2F0aW9ucy5qc29uUEsFBgAAAAAFAAUAUQEAAMcBAAAAAA=="

    func write(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hv-zip-\(UUID().uuidString).zip")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func destination() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hv-out-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Records what it was handed and writes a fixed answer.
    struct RecordingInflater: ImportZipInflating {
        let seen: Locked<[Data]>
        let output: Data
        func inflate(_ compressed: Data, to destination: URL) throws {
            seen.mutate { $0.append(compressed) }
            try output.write(to: destination)
        }
    }

    func testReadsTheDirectoryOfARealExport() throws {
        let archive = try ImportZipArchive(fileURL: write(try XCTUnwrap(Data(base64Encoded: Self.exportZip))))
        XCTAssertEqual(archive.entries.count, 5)
        XCTAssertEqual(
            archive.entries.map(\.name),
            ["export/", "export/conversations.json", "export/user.json", "export/images/photo.png", "__MACOSX/export/._conversations.json"]
        )
        let conversations = try XCTUnwrap(archive.entries.first { $0.name == "export/conversations.json" })
        XCTAssertEqual(conversations.compressedSize, 117)
        XCTAssertEqual(conversations.uncompressedSize, 203)
        XCTAssertEqual(archive.jsonEntries.map(\.name), ["export/conversations.json", "export/user.json"], "no folders, no resource forks, no images")
    }

    func testHandsTheCompressedBytesToTheInflater() throws {
        let archive = try ImportZipArchive(fileURL: write(try XCTUnwrap(Data(base64Encoded: Self.exportZip))))
        let entry = try XCTUnwrap(archive.entries.first { $0.name == "export/conversations.json" })
        let seen = Locked<[Data]>([])
        let out = destination()
        try archive.extract(entry, to: out, inflater: RecordingInflater(seen: seen, output: Data("{}".utf8)))
        let compressed = try XCTUnwrap(seen.value.first)
        XCTAssertEqual(compressed.count, 117)
        XCTAssertEqual(compressed.prefix(6).map { String(format: "%02x", $0) }.joined(), "8bae56ca4c51", "the raw deflate stream, without a zlib header")
        XCTAssertEqual(try Data(contentsOf: out), Data("{}".utf8))
    }

    func testStoredEntriesNeedNoInflater() throws {
        let archive = try ImportZipArchive(fileURL: write(try XCTUnwrap(Data(base64Encoded: Self.exportZip))))
        let photo = try XCTUnwrap(archive.entries.first { $0.name == "export/images/photo.png" })
        let out = destination()
        try archive.extract(photo, to: out, inflater: nil)
        let bytes = try Data(contentsOf: out)
        XCTAssertEqual(bytes.count, 48)
        XCTAssertEqual(Array(bytes.prefix(4)), [0x89, 0x50, 0x4E, 0x47])

        let compressed = try XCTUnwrap(archive.entries.first { $0.name == "export/user.json" })
        XCTAssertThrowsError(try archive.extract(compressed, to: destination(), inflater: nil)) { error in
            XCTAssertEqual(error as? ImportZipError, .unsupported("compressed files"))
        }
    }

    func testNotAZipAndDamagedZips() throws {
        XCTAssertThrowsError(try ImportZipArchive(fileURL: write(Data("hello, this is not a zip".utf8)))) { error in
            XCTAssertEqual(error as? ImportZipError, .notAZip)
        }
        XCTAssertThrowsError(try ImportZipArchive(fileURL: write(Data()))) { error in
            XCTAssertEqual(error as? ImportZipError, .notAZip)
        }
        // Cut off in the middle: the directory at the end is gone.
        var cut = try XCTUnwrap(Data(base64Encoded: Self.exportZip))
        cut.removeLast(120)
        XCTAssertThrowsError(try ImportZipArchive(fileURL: write(cut)))
    }

    // MARK: A zip written here, for shapes the fixture does not have

    struct Member {
        var name: String
        var bytes: Data
        var method: UInt16 = 0
        var flags: UInt16 = 0
    }

    func le(_ value: UInt64, bytes: Int) -> Data {
        Data((0..<bytes).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) })
    }

    /// A stored zip; with `zip64`, sizes and offsets travel in the extra field.
    func makeZip(_ members: [Member], zip64: Bool = false, comment: String = "") -> Data {
        var file = Data()
        var directory = Data()
        for member in members {
            let name = Data(member.name.utf8)
            let offset = UInt64(file.count)
            file += le(0x0403_4B50, bytes: 4) + le(20, bytes: 2) + le(UInt64(member.flags), bytes: 2) + le(UInt64(member.method), bytes: 2)
            file += le(0, bytes: 4) + le(0, bytes: 4) + le(UInt64(member.bytes.count), bytes: 4) + le(UInt64(member.bytes.count), bytes: 4)
            file += le(UInt64(name.count), bytes: 2) + le(0, bytes: 2) + name + member.bytes

            var extra = Data()
            var size: UInt64 = UInt64(member.bytes.count)
            var local = offset
            if zip64 {
                extra = le(1, bytes: 2) + le(24, bytes: 2) + le(size, bytes: 8) + le(size, bytes: 8) + le(local, bytes: 8)
                size = 0xFFFF_FFFF
                local = 0xFFFF_FFFF
            }
            directory += le(0x0201_4B50, bytes: 4) + le(20, bytes: 2) + le(20, bytes: 2) + le(UInt64(member.flags), bytes: 2) + le(UInt64(member.method), bytes: 2)
            directory += le(0, bytes: 4) + le(0, bytes: 4) + le(size, bytes: 4) + le(size, bytes: 4)
            directory += le(UInt64(name.count), bytes: 2) + le(UInt64(extra.count), bytes: 2) + le(0, bytes: 2)
            directory += le(0, bytes: 2) + le(0, bytes: 2) + le(0, bytes: 4) + le(local, bytes: 4) + name + extra
        }
        let directoryOffset = UInt64(file.count)
        var out = file + directory
        let note = Data(comment.utf8)
        if zip64 {
            let recordOffset = UInt64(out.count)
            out += le(0x0606_4B50, bytes: 4) + le(44, bytes: 8) + le(45, bytes: 2) + le(45, bytes: 2) + le(0, bytes: 4) + le(0, bytes: 4)
            out += le(UInt64(members.count), bytes: 8) + le(UInt64(members.count), bytes: 8) + le(UInt64(directory.count), bytes: 8) + le(directoryOffset, bytes: 8)
            out += le(0x0706_4B50, bytes: 4) + le(0, bytes: 4) + le(recordOffset, bytes: 8) + le(1, bytes: 4)
            out += le(0x0605_4B50, bytes: 4) + le(0, bytes: 2) + le(0, bytes: 2) + le(0xFFFF, bytes: 2) + le(0xFFFF, bytes: 2)
            out += le(0xFFFF_FFFF, bytes: 4) + le(0xFFFF_FFFF, bytes: 4) + le(UInt64(note.count), bytes: 2) + note
        } else {
            out += le(0x0605_4B50, bytes: 4) + le(0, bytes: 2) + le(0, bytes: 2) + le(UInt64(members.count), bytes: 2) + le(UInt64(members.count), bytes: 2)
            out += le(UInt64(directory.count), bytes: 4) + le(directoryOffset, bytes: 4) + le(UInt64(note.count), bytes: 2) + note
        }
        return out
    }

    func testReadsAStoredZipWithAComment() throws {
        let history = Data(#"[{"conversation_id":"g","responses":[{"sender":"human","message":"hi"}]}]"#.utf8)
        let zip = makeZip([Member(name: "prodmcbilling.json", bytes: Data(#"{"balance_map":{}}"#.utf8)), Member(name: "chat/conversations.json", bytes: history)], comment: "made by a test")
        let archive = try ImportZipArchive(fileURL: write(zip))
        XCTAssertEqual(archive.entries.map(\.name), ["prodmcbilling.json", "chat/conversations.json"])
        let entry = try XCTUnwrap(archive.entries.last)
        let out = destination()
        try archive.extract(entry, to: out, inflater: nil)
        let document = ImportInspector.inspect(try Data(contentsOf: out), name: entry.lastComponent)
        XCTAssertEqual(document.detected, .grok)
        XCTAssertEqual(document.conversationCount, 1)
    }

    func testReadsZip64Records() throws {
        let body = Data(#"[{"title":"t","chat_messages":[]}]"#.utf8)
        let zip = makeZip([Member(name: "a/conversations.json", bytes: body), Member(name: "b.json", bytes: Data("{}".utf8))], zip64: true)
        let archive = try ImportZipArchive(fileURL: write(zip))
        XCTAssertEqual(archive.entries.count, 2)
        let entry = try XCTUnwrap(archive.entries.first)
        XCTAssertEqual(entry.uncompressedSize, UInt64(body.count))
        XCTAssertEqual(entry.localOffset, 0)
        let out = destination()
        try archive.extract(entry, to: out, inflater: nil)
        XCTAssertEqual(try Data(contentsOf: out), body)
        XCTAssertEqual(archive.entries[1].localOffset, UInt64(30 + entry.name.utf8.count + body.count))
    }

    func testRefusesWhatItCannotOpen() throws {
        let zip = makeZip([
            Member(name: "secret.json", bytes: Data("xxxx".utf8), method: 0, flags: 1),
            Member(name: "odd.json", bytes: Data("xxxx".utf8), method: 12),
        ])
        let archive = try ImportZipArchive(fileURL: write(zip))
        XCTAssertThrowsError(try archive.extract(archive.entries[0], to: destination(), inflater: nil)) { error in
            XCTAssertEqual(error as? ImportZipError, .unsupported("a password"))
        }
        XCTAssertThrowsError(try archive.extract(archive.entries[1], to: destination(), inflater: nil)) { error in
            XCTAssertEqual(error as? ImportZipError, .unsupported("compression method 12"))
        }
        XCTAssertFalse((ImportZipError.unsupported("a password").errorDescription ?? "").isEmpty)
    }
}
