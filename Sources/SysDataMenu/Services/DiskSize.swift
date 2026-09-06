import Foundation

enum DiskSize {
    /// Allocated bytes under `url`, following the same rules Finder uses for
    /// System Data: on-disk blocks, no symlink traversal.
    static func allocated(at url: URL, olderThan cutoff: Date? = nil) async -> Int64 {
        await Task.detached(priority: .utility) {
            allocatedSync(at: url, olderThan: cutoff)
        }.value
    }

    static func allocatedSync(at url: URL, olderThan cutoff: Date? = nil) -> Int64 {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }

        let keys: Set<URLResourceKey> = [
            .totalFileAllocatedSizeKey, .isRegularFileKey, .contentModificationDateKey,
        ]

        if !isDirectory.boolValue {
            return size(of: url, keys: keys, cutoff: cutoff)
        }

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        for case let child as URL in enumerator {
            total += size(of: child, keys: keys, cutoff: cutoff)
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
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: rootPath),
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else { return [:] }

        var sizes: [String: Int64] = [:]
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: keys) else { continue }
            guard values.isRegularFile == true else {
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

    private static func size(of url: URL, keys: Set<URLResourceKey>, cutoff: Date?) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isRegularFile == true else { return 0 }
        if let cutoff, let modified = values.contentModificationDate, modified > cutoff {
            return 0
        }
        return Int64(values.totalFileAllocatedSize ?? 0)
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
