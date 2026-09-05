import Foundation

/// Executes a `ReclaimAction`. Every filesystem mutation in the app goes
/// through here.
enum Reclaimer {
    static func perform(_ action: ReclaimAction) async throws {
        switch action {
        case .removePaths(let urls):
            try await remove(urls)

        case .emptyDirectories(let directories):
            for directory in directories where directory.exists {
                try await remove(directory.children(includeHidden: true))
            }

        case .pruneOlderThan(let directory, let days):
            await Task.detached(priority: .utility) {
                prune(directory, olderThanDays: days)
            }.value

        case .command(let executable, let arguments):
            let result = try await Shell.run(executable, arguments)
            guard result.succeeded else {
                throw CommandError(command: ([executable] + arguments).joined(separator: " "), result: result)
            }

        case .privilegedScript(let script):
            let result = try await Shell.runPrivileged(script)
            guard result.succeeded else {
                throw CommandError(command: script, result: result)
            }

        case .manual:
            return
        }
    }

    /// Removes each path directly when the current user owns it and falls
    /// back to a single privileged `rm` for the rest.
    private static func remove(_ urls: [URL]) async throws {
        var needsRoot: [URL] = []
        let fileManager = FileManager.default

        for url in urls where url.exists {
            if fileManager.isDeletableFile(atPath: url.path) {
                do {
                    try fileManager.removeItem(at: url)
                } catch {
                    needsRoot.append(url)
                }
            } else {
                needsRoot.append(url)
            }
        }

        guard !needsRoot.isEmpty else { return }
        let script = "rm -rf " + needsRoot.map { Shell.shellQuote($0.path) }.joined(separator: " ")
        let result = try await Shell.runPrivileged(script)
        guard result.succeeded else {
            throw CommandError(command: script, result: result)
        }
    }

    /// Deletes files not modified in the last `days` days, then any directories
    /// left empty. Individual failures (files in use) are skipped.
    private static func prune(_ directory: URL, olderThanDays days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = fileManager.enumerator(
            at: directory, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }
        ) else { return }

        var directories: [URL] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            if values.isRegularFile == true {
                if let modified = values.contentModificationDate, modified < cutoff {
                    try? fileManager.removeItem(at: url)
                }
            } else {
                directories.append(url)
            }
        }
        // Deepest directories first so empty parents can go too.
        for url in directories.sorted(by: { $0.path.count > $1.path.count })
        where url.children(includeHidden: true).isEmpty {
            try? fileManager.removeItem(at: url)
        }
    }
}
