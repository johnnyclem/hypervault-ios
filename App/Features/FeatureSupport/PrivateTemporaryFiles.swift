import Foundation

/// An import's copy of an export, a mailbox or a ledger made for the share sheet: the app writes private things
/// to its temporary folder. Whoever makes one removes it when it is done with it; this clears what an owner never
/// got to (the app was closed or killed part way) when that owner next starts one of its own.
enum PrivateTemporaryFiles {
    /// Removes the items in `directory` whose names start with `prefix` and that were last changed more than `age`
    /// ago. What is newer may still be in use.
    static func removeStale(
        prefix: String,
        olderThan age: TimeInterval = 3_600,
        in directory: URL = FileManager.default.temporaryDirectory,
        now: Date = Date()
    ) {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix(prefix) {
            let url = directory.appendingPathComponent(name)
            let attributes = try? manager.attributesOfItem(atPath: url.path)
            guard let changed = attributes?[.modificationDate] as? Date, now.timeIntervalSince(changed) > age else { continue }
            try? manager.removeItem(at: url)
        }
    }
}
