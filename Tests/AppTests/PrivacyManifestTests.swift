import XCTest

/// The privacy manifests: the app, the share extension and the widgets each carry one, none tracks, and each declares
/// the required-reason APIs its own code uses and no others. Apple turns an upload away (ITMS-91053) when a bundle uses
/// one of those APIs without saying why.
final class PrivacyManifestTests: XCTestCase {
    private typealias Manifest = [String: Any]

    private let userDefaults = "NSPrivacyAccessedAPICategoryUserDefaults"
    private let fileTimestamp = "NSPrivacyAccessedAPICategoryFileTimestamp"

    private func readManifest(in bundle: Bundle, file: StaticString = #filePath, line: UInt = #line) throws -> Manifest {
        let url = try XCTUnwrap(bundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"), "\(bundle.bundleURL.lastPathComponent) has no manifest", file: file, line: line)
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        return try XCTUnwrap(plist as? Manifest, "the manifest is not a dictionary", file: file, line: line)
    }

    private func embedded(_ name: String) throws -> Bundle {
        let plugIns = try XCTUnwrap(Bundle.main.builtInPlugInsURL, "the app embeds its extensions")
        return try XCTUnwrap(Bundle(url: plugIns.appendingPathComponent(name)), "\(name) is not in the app")
    }

    /// The bundles, by the folders whose code is compiled into each: the folders of its own, `Shared`, and the Kit.
    private var bundles: [(name: String, bundle: () throws -> Bundle, folders: [String])] {
        let kit = "Packages/HyperVaultKit/Sources"
        return [
            ("the app", { Bundle.main }, ["App", "Shared", kit]),
            ("the share extension", { try self.embedded("HyperVaultShare.appex") }, ["ShareExtension", "Shared", kit]),
            ("the widgets", { try self.embedded("HyperVaultWidgets.appex") }, ["WidgetExtension", "Shared", kit]),
        ]
    }

    /// The categories a manifest declares, each with its reason codes.
    private func declared(_ manifest: Manifest) -> [String: Set<String>] {
        let entries = manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? []
        var result: [String: Set<String>] = [:]
        for entry in entries {
            guard let category = entry["NSPrivacyAccessedAPIType"] as? String else { continue }
            result[category] = Set(entry["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? [])
        }
        return result
    }

    // MARK: What each manifest says

    func testEveryBundleCarriesAManifestThatSaysItDoesNotTrack() throws {
        for item in bundles {
            let manifest = try readManifest(in: item.bundle())
            XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false, "\(item.name) does not track")
            XCTAssertEqual((manifest["NSPrivacyTrackingDomains"] as? [Any])?.count, 0, "\(item.name) names no tracking domain")
        }
    }

    func testTheReasonsAreTheOnesTheCodeGivesTheAPIsForOnly() throws {
        let appGroupAndOwn: Set<String> = ["CA92.1", "1C8F.1"]
        let app = declared(try readManifest(in: Bundle.main))
        XCTAssertEqual(app[userDefaults], appGroupAndOwn, "its own preferences, and the app group's that the extensions share")
        XCTAssertEqual(app[fileTimestamp], ["C617.1"], "the age of a file in its own temporary folder")
        XCTAssertEqual(Set(app.keys), [userDefaults, fileTimestamp])

        for name in ["HyperVaultShare.appex", "HyperVaultWidgets.appex"] {
            let extensionAPIs = declared(try readManifest(in: embedded(name)))
            XCTAssertEqual(extensionAPIs, [userDefaults: appGroupAndOwn], name)
        }
    }

    func testWhatIsCollectedIsLinkedToThePersonNeverTrackedAndForTheAppToWork() throws {
        let expected: [String: Set<String>] = [
            "the app": [
                "EmailAddress", "Name", "UserID", "PhoneNumber", "PhysicalAddress", "PaymentInfo",
                "PhotosorVideos", "EmailsOrTextMessages", "OtherUserContent",
            ],
            "the share extension": ["OtherUserContent"],
            "the widgets": [],
        ]
        for item in bundles {
            let entries = try readManifest(in: item.bundle())["NSPrivacyCollectedDataTypes"] as? [[String: Any]] ?? []
            var kinds: Set<String> = []
            for entry in entries {
                let kind = (entry["NSPrivacyCollectedDataType"] as? String ?? "").replacingOccurrences(of: "NSPrivacyCollectedDataType", with: "")
                kinds.insert(kind)
                XCTAssertEqual(entry["NSPrivacyCollectedDataTypeLinked"] as? Bool, true, "\(item.name): \(kind)")
                XCTAssertEqual(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool, false, "\(item.name): \(kind)")
                XCTAssertEqual(entry["NSPrivacyCollectedDataTypePurposes"] as? [String], ["NSPrivacyCollectedDataTypePurposeAppFunctionality"], "\(item.name): \(kind)")
            }
            XCTAssertEqual(kinds, expected[item.name], item.name)
        }
    }

    // MARK: What each bundle's code does

    /// What to look for in the source, per category. The names are Apple's list of required-reason APIs; a hit in a
    /// comment does not count. (`stat` and its kin are left out: a local function of that name would be taken for them.)
    private let signatures: [String: [String]] = [
        "NSPrivacyAccessedAPICategoryUserDefaults": ["UserDefaults"],
        "NSPrivacyAccessedAPICategoryFileTimestamp": [
            ".modificationDate", ".creationDate", "fileModificationDate", "contentModificationDateKey", "creationDateKey", "getattrlist",
        ],
        "NSPrivacyAccessedAPICategorySystemBootTime": ["systemUptime", "mach_absolute_time"],
        "NSPrivacyAccessedAPICategoryDiskSpace": [
            "volumeAvailableCapacity", "volumeTotalCapacity", "systemFreeSize", "systemSize", "statfs(", "statvfs(", "attributesOfFileSystem",
        ],
        "NSPrivacyAccessedAPICategoryActiveKeyboards": ["activeInputModes"],
    ]

    private func repositoryRoot() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: root.appendingPathComponent("project.yml").path), "the sources are not where this was built")
        return root
    }

    private func categoriesUsed(in folders: [String], under root: URL) -> Set<String> {
        var used: Set<String> = []
        for folder in folders {
            guard let files = FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in files where url.pathExtension == "swift" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                for (category, names) in signatures where !used.contains(category) {
                    if code.contains(where: { line in names.contains { line.contains($0) } }) { used.insert(category) }
                }
            }
        }
        return used
    }

    func testEachManifestDeclaresWhatItsBundlesCodeUsesAndNothingElse() throws {
        let root = try repositoryRoot()
        for item in bundles {
            let said = Set(declared(try readManifest(in: item.bundle())).keys)
            let used = categoriesUsed(in: item.folders, under: root)
            XCTAssertEqual(said, used, "\(item.name): the manifest and the required-reason APIs its code uses differ")
        }
    }
}
