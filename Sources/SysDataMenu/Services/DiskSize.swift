import Foundation

enum DiskSize {
    /// What one walk of a location reports: how much it takes up, and when
    /// anything inside it last changed.
    ///
    /// The date is the interesting half. Size alone cannot tell a 2 GB build
    /// folder for today's work apart from a 2 GB one for a project abandoned
    /// two years ago, and those are opposite decisions. The walk already reads
    /// every file's modification date to honour `cutoff`, so carrying the
    /// newest one out costs nothing.
    struct Measurement: Sendable {
        var bytes: Int64
        /// Newest modification date under the location, or nil when it holds
        /// no regular files.
        var lastModified: Date?
    }

    /// Allocated bytes under `url`, following the same rules Finder uses for
    /// System Data: on-disk blocks, no symlink traversal.
    static func allocated(at url: URL, olderThan cutoff: Date? = nil) async -> Int64 {
        await measure(at: url, olderThan: cutoff).bytes
    }

    static func measure(at url: URL, olderThan cutoff: Date? = nil) async -> Measurement {
        await Task.detached(priority: .utility) {
            measureSync(at: url, olderThan: cutoff)
        }.value
    }

    static func allocatedSync(at url: URL, olderThan cutoff: Date? = nil) -> Int64 {
        measureSync(at: url, olderThan: cutoff).bytes
    }

    static func measureSync(at url: URL, olderThan cutoff: Date? = nil) -> Measurement {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return Measurement(bytes: 0, lastModified: nil)
        }

        let keys: Set<URLResourceKey> = [
            .totalFileAllocatedSizeKey, .isRegularFileKey, .contentModificationDateKey,
        ]

        if !isDirectory.boolValue {
            return measure(of: url, keys: keys, cutoff: cutoff)
        }

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else { return Measurement(bytes: 0, lastModified: nil) }

        var total = Measurement(bytes: 0, lastModified: nil)
        for case let child as URL in enumerator {
            let child = measure(of: child, keys: keys, cutoff: cutoff)
            total.bytes += child.bytes
            if let modified = child.lastModified,
               modified > (total.lastModified ?? .distantPast) {
                total.lastModified = modified
            }
        }
        return total
    }

    /// Allocated size of every directory under `root` up to `maxDepth` levels,
    /// keyed by path, from a single enumeration. Used by the catch-all scan so
    /// it does not re-walk the same tree once per level.
    ///
    /// Directories in `skipping` are not descended into. The catch-all passes
    /// the locations it will refuse to report anyway — the ones another probe
    /// already explains, and the ones Finder counts as Photos or Mail rather
    /// than System Data — which is most of the files on a developer Mac.
    static func directorySizes(under root: URL, maxDepth: Int, skipping: Set<String> = []) -> [String: Int64] {
        // The enumerator hands back the paths realpath(3) would produce, and
        // those are what the arithmetic below and the skip test are compared
        // against. `resolvingSymlinksInPath` is not the same thing: it strips a
        // leading /private, so a root under /var or /tmp would come back eight
        // characters shorter than every path the enumerator yields and the
        // relative path would be cut inside a directory name.
        let rootPath = realPath(root.path)
        let skipped = Set(skipping.map(realPath))
        let keys: Set<URLResourceKey> = [
            .totalFileAllocatedSizeKey, .isRegularFileKey, .volumeIdentifierKey,
        ]
        let rootURL = URL(fileURLWithPath: rootPath)
        // The walk stays on the volume it started on. A directory on another
        // volume — an external drive, a network share, a Time Machine backup —
        // is not System Data, and a backup volume alone holds enough
        // hard-linked files to turn one walk into a multi-day crawl. Nil means
        // the volume could not be read; measure rather than silently skip.
        let rootVolume = (try? rootURL.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else { return [:] }

        var sizes: [String: Int64] = [:]
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: keys) else { continue }
            guard values.isRegularFile == true else {
                if let rootVolume, let volume = values.volumeIdentifier, !volume.isEqual(rootVolume) {
                    enumerator.skipDescendants()
                    continue
                }
                if !skipped.isEmpty, skipped.contains(file.path) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard let size = values.totalFileAllocatedSize, size > 0 else { continue }

            let relative = file.path.dropFirst(rootPath.count + 1)
            let components = relative.split(separator: "/", omittingEmptySubsequences: true).dropLast()
            var directory = rootPath
            sizes[directory, default: 0] += Int64(size)
            for component in components.prefix(maxDepth) {
                directory += "/" + component
                sizes[directory, default: 0] += Int64(size)
            }
        }
        return sizes
    }

    /// The newest modification date at the top of a directory, from a shallow
    /// listing. Used where a full walk has already happened for the size and
    /// walking again for the date alone would double the scan.
    static func shallowLastModified(at url: URL) -> Date? {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        var newest = (try? url.resourceValues(forKeys: keys))?.contentModificationDate
        for child in url.children(includeHidden: true) {
            guard let modified = (try? child.resourceValues(forKeys: keys))?.contentModificationDate
            else { continue }
            if modified > (newest ?? .distantPast) { newest = modified }
        }
        return newest
    }

    /// Whether `url` lives on the same volume as the startup disk. A home
    /// folder relocated onto an external drive — common on a Mac mini with a
    /// small internal SSD — is the case the catch-all must not start walking:
    /// the disk can be tens of terabytes, and none of it is System Data.
    /// Returns true when a volume cannot be read, so an unreadable case is
    /// measured rather than silently dropped.
    static func isOnBootVolume(_ url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.volumeIdentifierKey]
        guard let boot = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys))?.volumeIdentifier,
              let volume = (try? url.resourceValues(forKeys: keys))?.volumeIdentifier
        else { return true }
        return volume.isEqual(boot)
    }

    /// The path with every symlink resolved, as realpath(3) reports it and as
    /// `FileManager`'s enumerator yields it.
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func freeSpace() -> Int64 {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return Int64(values?.volumeAvailableCapacity ?? 0)
    }

    /// Space macOS would free on demand (snapshots, purgeable caches). Finder
    /// shows it as the hatched part of the storage bar.
    static func purgeableSpace() -> Int64 {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
            .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ])
        let free = Int64(values?.volumeAvailableCapacity ?? 0)
        let important = values?.volumeAvailableCapacityForImportantUsage ?? 0
        return max(important - free, 0)
    }

    /// The `limit` biggest direct children of a directory, measured on disk.
    static func largestChildren(of url: URL, limit: Int = 5) async -> [(url: URL, bytes: Int64)] {
        await Task.detached(priority: .utility) {
            url.children(includeHidden: true)
                .map { ($0, allocatedSync(at: $0)) }
                .filter { $0.1 > 0 }
                .sorted { $0.1 > $1.1 }
                .prefix(limit)
                .map { (url: $0.0, bytes: $0.1) }
        }.value
    }

    /// One file's contribution. A file excluded by `cutoff` contributes
    /// neither its bytes nor its date, so a pruning item's age describes what
    /// it would actually delete.
    private static func measure(of url: URL, keys: Set<URLResourceKey>, cutoff: Date?) -> Measurement {
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isRegularFile == true else { return Measurement(bytes: 0, lastModified: nil) }
        if let cutoff, let modified = values.contentModificationDate, modified > cutoff {
            return Measurement(bytes: 0, lastModified: nil)
        }
        return Measurement(
            bytes: Int64(values.totalFileAllocatedSize ?? 0),
            lastModified: values.contentModificationDate
        )
    }
}

extension URL {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static func home(_ path: String) -> URL {
        home.appending(path: path)
    }

    var exists: Bool { FileManager.default.fileExists(atPath: path) }

    /// Non-hidden, direct children sorted by name.
    func children(includeHidden: Bool = false) -> [URL] {
        let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: self, includingPropertiesForKeys: [.isDirectoryKey], options: options
        )) ?? []
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    var abbreviatedPath: String {
        let home = URL.home.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
