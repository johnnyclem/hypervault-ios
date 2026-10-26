import XCTest
@testable import HyperVault

final class PrivateTemporaryFilesTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("hv-sweep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func make(_ name: String, hoursAgo: Double, isFolder: Bool = false) throws {
        let url = folder.appendingPathComponent(name)
        if isFolder {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try Data("private".utf8).write(to: url)
        }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-hoursAgo * 3_600)], ofItemAtPath: url.path)
    }

    private func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    func testOldItemsWithThePrefixGoAndNothingElseDoes() throws {
        try make("hv-import-old.json", hoursAgo: 5)
        try make("hv-import-old-folder", hoursAgo: 5, isFolder: true)
        try make("hv-import-new.json", hoursAgo: 0.1)
        try make("hv-share-old.json", hoursAgo: 5)
        try make("somebody-elses.json", hoursAgo: 5)
        PrivateTemporaryFiles.removeStale(prefix: "hv-import-", in: folder)
        XCTAssertEqual(try names(), ["hv-import-new.json", "hv-share-old.json", "somebody-elses.json"])
    }

    func testTheAgeIsTheCallersToSet() throws {
        try make("hv-share-a", hoursAgo: 2, isFolder: true)
        PrivateTemporaryFiles.removeStale(prefix: "hv-share-", olderThan: 3 * 3_600, in: folder)
        XCTAssertEqual(try names(), ["hv-share-a"])
        PrivateTemporaryFiles.removeStale(prefix: "hv-share-", olderThan: 3_600, in: folder)
        XCTAssertEqual(try names(), [])
    }

    func testAMissingFolderIsNotAnError() {
        PrivateTemporaryFiles.removeStale(prefix: "hv-", in: folder.appendingPathComponent("nope"))
    }
}
