import Foundation

public struct CacheEntry<Value: Codable & Sendable>: Codable, Sendable {
    public let value: Value
    public let savedAt: Date

    public func age(now: Date = Date()) -> TimeInterval { now.timeIntervalSince(savedAt) }
}

/// A small on-disk cache of decoded responses, one folder per signed-in user so
/// nothing leaks between accounts and sign-out can wipe it. It is a read cache
/// for fast first paint and offline reading, never a second source of truth.
///
/// What it holds is a person's own: the names of what they kept, saved logins and cards among them. On iOS every
/// file is written readable only once the phone has been unlocked since it started, and
/// `protectExistingFiles()` gives that to what an earlier build wrote.
public actor DiskCache {
    private let directory: URL
    private let fileManager = FileManager.default

    public init(directory: URL) {
        self.directory = directory
    }

    /// How a file is written. The file protection options are iOS's; the Kit also builds on macOS and Linux.
    private static var writeOptions: Data.WritingOptions {
        #if os(iOS)
        return [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        return [.atomic]
        #endif
    }

    public func entry<Value: Codable & Sendable>(
        _ type: Value.Type, key: String, namespace: String
    ) -> CacheEntry<Value>? {
        guard let data = try? Data(contentsOf: file(key: key, namespace: namespace)) else { return nil }
        return try? HVCoding.decoder(.verbatim).decode(CacheEntry<Value>.self, from: data)
    }

    public func store<Value: Codable & Sendable>(_ value: Value, key: String, namespace: String) {
        let entry = CacheEntry(value: value, savedAt: Date())
        guard let data = try? HVCoding.encoder(.verbatim).encode(entry) else { return }
        let url = file(key: key, namespace: namespace)
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: Self.writeOptions)
    }

    /// Puts the protection new files get on the files and folders already here. Files written before the rule was
    /// set have the system's default, and a cache is not rewritten until its screen next loads. Cheap enough to run at
    /// every launch, and a no-op where the system has no such protection.
    public func protectExistingFiles() {
        #if os(iOS)
        let protection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        guard let walker = fileManager.enumerator(atPath: directory.path) else { return }
        for case let name as String in walker {
            try? fileManager.setAttributes(protection, ofItemAtPath: directory.appendingPathComponent(name).path)
        }
        try? fileManager.setAttributes(protection, ofItemAtPath: directory.path)
        #endif
    }

    public func remove(key: String, namespace: String) {
        try? fileManager.removeItem(at: file(key: key, namespace: namespace))
    }

    /// Everything cached for one user.
    public func clear(namespace: String) {
        try? fileManager.removeItem(at: folder(namespace: namespace))
    }

    public func clearAll() {
        try? fileManager.removeItem(at: directory)
    }

    private func folder(namespace: String) -> URL {
        directory.appendingPathComponent(SHA256.hex(Data(namespace.utf8)).prefix(24).description, isDirectory: true)
    }

    private func file(key: String, namespace: String) -> URL {
        folder(namespace: namespace).appendingPathComponent(SHA256.hex(Data(key.utf8)).prefix(32) + ".json")
    }
}

/// A value read for a screen, and whether it is the cached copy or fresh.
public struct Loaded<Value: Sendable>: Sendable {
    public enum Source: Sendable { case cache, network }

    public let value: Value
    public let source: Source
    public let savedAt: Date?
    /// Set when the refresh failed and `value` is the cached copy being shown instead.
    public let refreshError: HVError?

    public var isStale: Bool { source == .cache }
}

/// Stale-while-revalidate: the cached copy first (when there is one), then the
/// fresh one. If the refresh fails and a cached copy was shown, the last
/// element repeats it with `refreshError` set; with nothing cached it throws.
public func cachedLoad<Value: Codable & Sendable>(
    cache: DiskCache,
    namespace: String,
    key: String,
    fetch: @escaping @Sendable () async throws -> Value
) -> AsyncThrowingStream<Loaded<Value>, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            let cached = await cache.entry(Value.self, key: key, namespace: namespace)
            if let cached {
                continuation.yield(Loaded(value: cached.value, source: .cache, savedAt: cached.savedAt, refreshError: nil))
            }
            do {
                let fresh = try await fetch()
                await cache.store(fresh, key: key, namespace: namespace)
                continuation.yield(Loaded(value: fresh, source: .network, savedAt: Date(), refreshError: nil))
                continuation.finish()
            } catch {
                let failure = (error as? HVError) ?? HVError.transport(error.localizedDescription)
                if let cached {
                    continuation.yield(Loaded(value: cached.value, source: .cache, savedAt: cached.savedAt, refreshError: failure))
                    continuation.finish()
                } else {
                    continuation.finish(throwing: failure)
                }
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}
