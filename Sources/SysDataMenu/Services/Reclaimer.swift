import Foundation

/// Thrown instead of asking for a password in a run nobody is watching.
struct NeedsAdministrator: LocalizedError {
    var errorDescription: String? {
        L("It needs an administrator password, so it was left for you to delete from the list.")
    }
}

/// Executes a `ReclaimAction`. Every filesystem mutation in the app goes
/// through here.
enum Reclaimer {
    /// `preferTrash` moves user-owned paths to the Trash instead of deleting
    /// them, so a Review item can be recovered for 30 days.
    ///
    /// Returns true when anything was moved to the Trash rather than deleted,
    /// because that frees no disk space until the Trash is emptied.
    ///
    /// `allowsAdministrator` is false for the runs nobody is watching — the
    /// weekly clean, the low-space button, the Shortcut. A path the user
    /// cannot delete is then reported instead of handed to `rm` as root,
    /// because a password dialog out of nowhere is not something those runs
    /// may cause.
    @discardableResult
    static func perform(
        _ action: ReclaimAction, preferTrash: Bool = false, allowsAdministrator: Bool = true
    ) async throws -> Bool {
        switch action {
        case .removePaths(let urls):
            return try await remove(urls, toTrash: preferTrash, allowsAdministrator: allowsAdministrator)

        case .emptyDirectories(let directories):
            // The Trash preference applies here too: a Review item emptied in
            // place — Xcode archives, a game library — was deleted for good
            // while its badge promised the Trash.
            var trashed = false
            for directory in directories where directory.exists {
                trashed = try await remove(
                    directory.children(includeHidden: true), toTrash: preferTrash,
                    allowsAdministrator: allowsAdministrator
                ) || trashed
            }
            return trashed

        case .pruneOlderThan(let directory, let days):
            await Task.detached(priority: .utility) {
                prune(directory, olderThanDays: days)
            }.value
            return false

        case .command(let executable, let arguments):
            let result = try await Shell.run(executable, arguments)
            guard result.succeeded else {
                throw CommandError(command: ([executable] + arguments).joined(separator: " "), result: result)
            }
            return false

        case .privilegedScript(let script):
            guard allowsAdministrator else { throw NeedsAdministrator() }
            let result = try await Shell.runPrivileged(script)
            guard result.succeeded else {
                throw CommandError(command: script, result: result)
            }
            return false

        case .shutdownSimulators:
            _ = try? await Shell.run("/usr/bin/xcrun", ["simctl", "shutdown", "all"])
            return false

        case .eraseSimulator(let udid):
            // A booted simulator refuses to erase. Shutting it down is allowed
            // to fail — an already shut-down one refuses that too — and a
            // refusal is retried once after shutting everything down, for when
            // something booted it again in between.
            let xcrun = "/usr/bin/xcrun"
            _ = try? await Shell.run(xcrun, ["simctl", "shutdown", udid])
            var result = try await Shell.run(xcrun, ["simctl", "erase", udid])
            if !result.succeeded {
                _ = try? await Shell.run(xcrun, ["simctl", "shutdown", "all"])
                result = try await Shell.run(xcrun, ["simctl", "erase", udid])
            }
            guard result.succeeded else {
                throw CommandError(command: "\(xcrun) simctl erase \(udid)", result: result)
            }
            return false

        case .steps(let actions):
            var trashed = false
            for action in actions {
                trashed = try await perform(
                    action, preferTrash: preferTrash, allowsAdministrator: allowsAdministrator
                ) || trashed
            }
            return trashed

        case .manual:
            return false
        }
    }

    /// Removes each path directly when the current user owns it and falls
    /// back to a single privileged `rm` for the rest. Returns true when at
    /// least one path was trashed instead of deleted.
    private static func remove(_ urls: [URL], toTrash: Bool, allowsAdministrator: Bool) async throws -> Bool {
        var needsRoot: [URL] = []
        var trashed = false
        let fileManager = FileManager.default

        for url in urls where url.exists {
            guard fileManager.isDeletableFile(atPath: url.path) else {
                needsRoot.append(url)
                continue
            }
            // Trashing is a rename on the same volume; it fails for system
            // volumes and some containers, in which case a real delete follows.
            if toTrash, (try? fileManager.trashItem(at: url, resultingItemURL: nil)) != nil {
                trashed = true
                continue
            }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                needsRoot.append(url)
            }
        }

        guard !needsRoot.isEmpty else { return trashed }
        guard allowsAdministrator else { throw NeedsAdministrator() }
        let script = "rm -rf " + needsRoot.map { Shell.shellQuote($0.path) }.joined(separator: " ")
        let result = try await Shell.runPrivileged(script)
        guard result.succeeded else {
            throw CommandError(command: script, result: result)
        }
        return trashed
    }

    /// Deletes regular files not modified in the last `days` days, then the
    /// directories that doing so left empty. Nothing else.
    ///
    /// This runs on the user's temporary and cache folders, where running
    /// apps keep their live sockets, pipes, links and lock directories. It
    /// used to treat anything that was not a regular file as a directory and
    /// delete it once empty — which a socket always is — so a pass here took
    /// every open socket in $TMPDIR with it, VS Code's git sockets among them,
    /// whatever its age, along with every empty directory an app had just
    /// made. Now a directory goes only when this pass emptied it, and links,
    /// sockets and pipes are never touched: they hold no data to free.
    /// Individual failures (files in use) are skipped.
    private static func prune(_ directory: URL, olderThanDays days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = fileManager.enumerator(
            at: directory, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }
        ) else { return }

        var emptied: Set<URL> = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified < cutoff
            else { continue }
            if (try? fileManager.removeItem(at: url)) != nil {
                emptied.insert(url.deletingLastPathComponent().standardizedFileURL)
            }
        }

        // Deepest first, so a parent that held nothing but an emptied folder
        // goes too. The folder being pruned is never removed itself.
        let root = directory.standardizedFileURL.path
        var candidates = emptied
        while let deepest = candidates.max(by: { $0.path.count < $1.path.count }) {
            candidates.remove(deepest)
            guard deepest.path.hasPrefix(root + "/"),
                  (try? fileManager.contentsOfDirectory(atPath: deepest.path))?.isEmpty == true,
                  (try? fileManager.removeItem(at: deepest)) != nil
            else { continue }
            candidates.insert(deepest.deletingLastPathComponent().standardizedFileURL)
        }
    }
}
