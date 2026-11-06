import Foundation
import os

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
        /// The walk stopped getting answers and was given up on, so `bytes`
        /// is not the size of the location (see `watched`).
        var stalled = false
    }

    /// Counts the entries a walk has read, so a walk that has stopped reading
    /// can be told apart from one that is merely long.
    final class WalkProgress: Sendable {
        private let entries = OSAllocatedUnfairLock(initialState: 0)

        func advance() { entries.withLock { $0 += 1 } }
        var count: Int { entries.withLock { $0 } }
    }

    /// How many walks read the disk at once. The concurrency pool used to
    /// set this by having one thread per core; dispatch has no such limit,
    /// and forty walks at once made the scan slower, not faster.
    private static let walkSlots = WalkSlots(count: ProcessInfo.processInfo.activeProcessorCount)

    /// A counting gate for walks. A slot is given back when its walk ends or
    /// is given up on, whichever comes first, so walks stuck in the kernel
    /// never hold slots the rest of the scan needs.
    private actor WalkSlots {
        private var free: Int
        private var waiting: [CheckedContinuation<Void, Never>] = []

        init(count: Int) { free = max(count, 1) }

        func acquire() async {
            if free > 0 {
                free -= 1
                return
            }
            await withCheckedContinuation { waiting.append($0) }
        }

        func release() {
            if waiting.isEmpty {
                free += 1
            } else {
                waiting.removeFirst().resume()
            }
        }
    }

    /// How long a walk may go without reading a single entry before the scan
    /// stops waiting for it. A large folder keeps reading; this only ever
    /// catches one whose file system has stopped answering.
    static let stallLimit: Duration = .seconds(30)

    /// Runs a walk off the concurrency pool and returns its result, or nil if
    /// it read nothing for `stallLimit`.
    ///
    /// A directory read on a file system that has stopped answering — a
    /// network share that went away, a cloud-synced folder waiting on its
    /// provider, a stuck FUSE mount — blocks in the kernel and never returns,
    /// and nothing can cancel it. The scan used to wait with it and sit at
    /// "22 of 23" for good (#27). The walk still blocks, on a dispatch thread
    /// that is left to it; the scan goes on without that location.
    static func watched<T: Sendable>(
        stallLimit: Duration = DiskSize.stallLimit, checkEvery: Duration = .seconds(2),
        _ walk: @escaping @Sendable (WalkProgress) -> T
    ) async -> T? {
        let progress = WalkProgress()
        let slots = walkSlots
        await slots.acquire()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (T?) -> Void = { value in
                let first = resumed.withLock { done in
                    defer { done = true }
                    return !done
                }
                guard first else { return }
                continuation.resume(returning: value)
                Task { await slots.release() }
            }
            // Not a detached task: a walk blocked in the kernel would hold one
            // of the concurrency pool's few threads for good, and enough of
            // them would stall every other probe. Dispatch adds threads.
            // User-initiated, not utility: on a dispatch queue utility walks
            // had their disk reads throttled, and the scan took 30% longer
            // than the same walks run as utility tasks had.
            DispatchQueue.global(qos: .userInitiated).async { finish(walk(progress)) }
            Task.detached(priority: .utility) {
                var lastCount = -1
                var quietFor: Duration = .zero
                while !resumed.withLock({ $0 }) {
                    try? await Task.sleep(for: checkEvery)
                    let count = progress.count
                    if count == lastCount { quietFor += checkEvery } else { lastCount = count; quietFor = .zero }
                    if quietFor >= stallLimit {
                        finish(nil)
                        return
                    }
                }
            }
        }
    }

    /// Allocated bytes under `url`, following the same rules Finder uses for
    /// System Data: on-disk blocks, no symlink traversal.
    static func allocated(at url: URL, olderThan cutoff: Date? = nil) async -> Int64 {
        await measure(at: url, olderThan: cutoff).bytes
    }

    static func measure(at url: URL, olderThan cutoff: Date? = nil) async -> Measurement {
        await watched { progress in measureSync(at: url, olderThan: cutoff, progress: progress) }
            ?? Measurement(bytes: 0, lastModified: nil, stalled: true)
    }

    static func allocatedSync(at url: URL, olderThan cutoff: Date? = nil) -> Int64 {
        measureSync(at: url, olderThan: cutoff).bytes
    }

    static func measureSync(at url: URL, olderThan cutoff: Date? = nil, progress: WalkProgress? = nil) -> Measurement {
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
            progress?.advance()
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
    static func directorySizes(
        under root: URL, maxDepth: Int, skipping: Set<String> = [], progress: WalkProgress? = nil
    ) -> [String: Int64] {
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
            progress?.advance()
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

    /// Size of the startup volume, the whole the overview bar is drawn against.
    static func capacity() -> Int64 {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey])
        return Int64(values?.volumeTotalCapacity ?? 0)
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
