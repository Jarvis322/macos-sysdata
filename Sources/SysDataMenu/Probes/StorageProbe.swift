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
        guard url.exists else { return nil }
        let measured = await DiskSize.measure(at: url)
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

    /// Runs a JSON-producing command and decodes its top-level object.
    static func json(_ executable: String, _ arguments: [String]) async -> [String: Any]? {
        guard let result = try? await Shell.run(executable, arguments, mergeStderr: false),
              result.succeeded,
              let data = result.output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    static let megabyte: Int64 = 1_048_576

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
