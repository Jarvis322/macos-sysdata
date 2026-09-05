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
        let size = await DiskSize.allocated(at: url)
        guard size >= minimumBytes else { return nil }
        return StorageItem(
            id: id,
            category: category,
            name: name,
            detail: detail,
            sizeBytes: size,
            safety: safety,
            action: action,
            revealURL: url
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
}
