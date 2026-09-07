import Foundation

/// What the app remembers between scans.
///
/// Everything else here answers "what is on this disk now". That is the
/// smaller half of the question people actually have, which is "why is it
/// full again". Answering it needs the one thing the app threw away on every
/// run: the previous scan. So each scan and each deletion is appended to a
/// file, and the difference between them is what the list can then show —
/// what grew, and whether what you deleted came back.
///
/// It is a plain JSON file in this app's own Application Support folder. It
/// never leaves the machine, it holds no more than the list on screen already
/// shows, and `ScanHistory.forget()` deletes it.
enum ScanHistory {
    /// One scan: the totals, and every item's size at that moment.
    struct Scan: Codable, Sendable {
        var date: Date
        var totalBytes: Int64
        var freeBytes: Int64
        var sizes: [String: Int64]
        /// Names are kept so a row deleted long ago can still be described
        /// without the item existing any more.
        var names: [String: String]
    }

    /// One reclaim. `rm -rf` cannot be undone; this is the record that it
    /// happened, which is the least an app owes someone whose disk it edits.
    struct Deletion: Codable, Sendable {
        var date: Date
        var itemID: String
        var name: String
        var category: String
        var paths: [String]
        var bytes: Int64
    }

    struct Log: Codable, Sendable {
        var scans: [Scan] = []
        var deletions: [Deletion] = []
    }

    /// Kept long enough to see a month-over-month trend, capped so the file
    /// cannot grow without bound on a machine that scans daily for years.
    static let keepFor: TimeInterval = 180 * 24 * 60 * 60
    static let maximumScans = 400
    static let maximumDeletions = 1000

    static var fileURL: URL {
        let directory = URL.home("Library/Application Support/SysDataMenu")
        return directory.appending(path: "history.json")
    }

    // MARK: Reading

    static func load() -> Log {
        guard let data = try? Data(contentsOf: fileURL),
              let log = try? decoder.decode(Log.self, from: data) else { return Log() }
        return log
    }

    // MARK: Writing

    static func record(_ items: [StorageItem], freeBytes: Int64, at date: Date = .now) {
        var log = load()
        var sizes: [String: Int64] = [:]
        var names: [String: String] = [:]
        for item in items {
            guard let bytes = item.sizeBytes else { continue }
            sizes[item.id] = bytes
            names[item.id] = item.name
        }
        log.scans.append(Scan(
            date: date,
            totalBytes: sizes.values.reduce(0, +),
            freeBytes: freeBytes,
            sizes: sizes,
            names: names
        ))
        save(prune(log, now: date))
    }

    static func record(deleted item: StorageItem, bytes: Int64, at date: Date = .now) {
        var log = load()
        log.deletions.append(Deletion(
            date: date,
            itemID: item.id,
            name: item.name,
            category: item.category.rawValue,
            paths: item.action.paths.map(\.path),
            bytes: bytes
        ))
        save(prune(log, now: date))
    }

    static func forget() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: Questions the log can answer

    /// Change in an item's size since the most recent scan before this one.
    /// `nil` when there is nothing to compare against, which is not the same
    /// as no change and must not be drawn as "+0".
    static func change(forItem id: String, in log: Log) -> Int64? {
        guard log.scans.count >= 2 else { return nil }
        let current = log.scans[log.scans.count - 1]
        let previous = log.scans[log.scans.count - 2]
        guard let now = current.sizes[id], let before = previous.sizes[id] else { return nil }
        return now - before
    }

    /// Items that have grown most since the earliest scan still on file that
    /// also knew them, largest growth first.
    static func fastestGrowing(in log: Log, limit: Int = 5) -> [(name: String, bytes: Int64, since: Date)] {
        guard let current = log.scans.last else { return [] }
        var growth: [(name: String, bytes: Int64, since: Date)] = []
        for (id, now) in current.sizes {
            guard let first = log.scans.first(where: { $0.sizes[id] != nil }),
                  first.date < current.date,
                  let before = first.sizes[id],
                  now > before else { continue }
            growth.append((current.names[id] ?? id, now - before, first.date))
        }
        return growth.sorted { $0.bytes > $1.bytes }.prefix(limit).map { $0 }
    }

    /// Things deleted that a later scan found again, and how much of them.
    ///
    /// This is the log's most useful answer. A cache you cleared on Monday
    /// and that is 12 GB again by Friday is not a failure of the delete — it
    /// is the tool that made it telling you it will keep doing so.
    static func returned(in log: Log) -> [(name: String, bytes: Int64, deleted: Date, seen: Date)] {
        var byItem: [String: Deletion] = [:]
        for deletion in log.deletions {
            // The most recent deletion of each item is the one to measure from.
            if let existing = byItem[deletion.itemID], existing.date > deletion.date { continue }
            byItem[deletion.itemID] = deletion
        }

        var results: [(name: String, bytes: Int64, deleted: Date, seen: Date)] = []
        for (id, deletion) in byItem {
            guard let scan = log.scans.last(where: { $0.date > deletion.date }),
                  let bytes = scan.sizes[id], bytes > 0 else { continue }
            results.append((deletion.name, bytes, deletion.date, scan.date))
        }
        return results.sorted { $0.bytes > $1.bytes }
    }

    // MARK: Storage

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func prune(_ log: Log, now: Date) -> Log {
        var log = log
        let cutoff = now.addingTimeInterval(-keepFor)
        log.scans = log.scans.filter { $0.date >= cutoff }.suffix(maximumScans).map { $0 }
        log.deletions = log.deletions.filter { $0.date >= cutoff }.suffix(maximumDeletions).map { $0 }
        return log
    }

    private static func save(_ log: Log) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(log) else { return }
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Atomic: a crash mid-write must not leave a file that parses as an
        // empty history and silently loses months of it.
        try? data.write(to: fileURL, options: .atomic)
    }
}
