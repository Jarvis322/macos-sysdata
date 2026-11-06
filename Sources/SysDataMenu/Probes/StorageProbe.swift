import Foundation

/// One category scanner. Probes run concurrently and must not mutate anything.
protocol StorageProbe: Sendable {
    func probe() async -> [StorageItem]
}

enum ProbeSupport {
    /// Builds an item for a directory, or `nil` when it is missing or smaller
    /// than `minimumBytes`.
    static func directoryItem(
        id: String,
        category: StorageCategory,
        name: String,
        detail: String,
        url: URL,
        safety: Safety,
        action: ReclaimAction,
        minimumBytes: Int64 = 1
    ) async -> StorageItem? {
        // Checked before the walk rather than inside it: most locations a
        // probe asks about do not exist on a given Mac, and each would
        // otherwise wait for a walk slot behind the real walks. What hangs
        // on a file system that has stopped answering is reading a folder's
        // entries, which the walk does and is watched for (#27).
        guard url.exists else { return nil }
        let measured = await DiskSize.measure(at: url)
        if measured.stalled {
            return unansweredItem(id: id, category: category, name: name, url: url)
        }
        guard measured.bytes >= minimumBytes else { return nil }
        return StorageItem(
            id: id,
            category: category,
            name: name,
            detail: detail,
            sizeBytes: measured.bytes,
            safety: safety,
            action: action,
            revealURL: url,
            lastModified: measured.lastModified
        )
    }

    /// Builds one item per input concurrently. The walks behind each item
    /// wait on the disk, and a probe that measured fifty folders one after
    /// another was the longest part of the scan. Order is not kept; every
    /// caller sorts by size afterwards.
    static func items<Input: Sendable>(
        for inputs: [Input], _ build: @escaping @Sendable (Input) async -> StorageItem?
    ) async -> [StorageItem] {
        await withTaskGroup(of: StorageItem?.self) { group in
            for input in inputs {
                group.addTask { await build(input) }
            }
            var items: [StorageItem] = []
            for await item in group {
                if let item { items.append(item) }
            }
            return items
        }
    }

    /// A location whose file system stopped answering while it was measured.
    ///
    /// Listed rather than dropped, so the scan says where it gave up instead
    /// of quietly showing less, and claimed, so the catch-all does not walk
    /// into the same place. It has no size, so nothing offers to delete it.
    static func unansweredItem(id: String, category: StorageCategory, name: String, url: URL) -> StorageItem {
        StorageItem(
            id: id, category: category, name: name,
            detail: "Could not be measured: reading this folder stopped getting answers. It may be on a network drive, a disconnected disk, or in a cloud-synced folder.",
            sizeBytes: nil, safety: .manual,
            action: .manual("Open it in Finder to see what it is. If it is on a network or cloud drive, check that the drive is connected or the files are downloaded, then scan again."),
            revealURL: url
        )
    }

    /// Runs a JSON-producing command and decodes its top-level object.
    static func json(_ executable: String, _ arguments: [String]) async -> [String: Any]? {
        guard let result = try? await Shell.run(executable, arguments, mergeStderr: false, timeout: Shell.probeTimeout),
              result.succeeded,
              let data = result.output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    static let megabyte: Int64 = 1_048_576

    /// `xcode-select -p`, or nil when it failed. Its error text used to be
    /// taken for a path, which made every Xcode read as inactive.
    static func activeDeveloperDirectory() async -> String? {
        guard let result = try? await Shell.run(
            "/usr/bin/xcode-select", ["-p"], mergeStderr: false, timeout: Shell.probeTimeout
        ), result.succeeded else { return nil }
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// Whether macOS will let this app read the places it keeps behind TCC.
    ///
    /// Reading `~/Library/Safari` is denied outright rather than prompting, so
    /// asking costs nothing and warns nobody. Every other protected location
    /// does prompt, one dialog per app whose container is touched — which is
    /// why nothing here may look at one before this is true. Full Disk Access
    /// covers all of them at once; a scan that walks them first turns a single
    /// grant into a queue of dialogs at launch.
    static var hasFullDiskAccess: Bool {
        // SYSDATA_NO_FULL_DISK_ACCESS makes the answer no on a machine where
        // it is yes, which is the only way to exercise the skipping on a
        // developer's Mac. It can only ever make the scan more conservative;
        // there is no variable that claims access the app does not have.
        if ProcessInfo.processInfo.environment["SYSDATA_NO_FULL_DISK_ACCESS"] != nil { return false }
        return (try? FileManager.default.contentsOfDirectory(atPath: URL.home("Library/Safari").path)) != nil
    }

    /// The locations that prompt. Skipped entirely until Full Disk Access is
    /// granted, which is also when they can actually be read.
    static let protectedLocations: [URL] = [
        .home("Library/Containers"), .home("Library/Group Containers"),
        .home("Desktop"), .home("Documents"), .home("Downloads"),
        .home("Music"), .home("Pictures"), .home("Movies"),
    ]
}
