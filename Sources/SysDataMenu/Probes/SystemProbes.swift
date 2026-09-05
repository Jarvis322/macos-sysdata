import Foundation

// MARK: - Logs

struct LogProbe: StorageProbe {
    func probe() async -> [StorageItem] {
        var items: [StorageItem] = []

        // The unified log store must be cleared with `log erase`; deleting the
        // files by hand corrupts it.
        let diagnostics = URL(fileURLWithPath: "/private/var/db/diagnostics")
        let uuidtext = URL(fileURLWithPath: "/private/var/db/uuidtext")
        let logStore = await DiskSize.allocated(at: diagnostics) + DiskSize.allocated(at: uuidtext)
        if logStore > 0 {
            items.append(StorageItem(
                id: "log-unified", category: .logs, name: "Unified log store",
                detail: "Persisted system log (/private/var/db/diagnostics). Cleared with `log erase --all`.",
                sizeBytes: logStore, safety: .safe,
                action: .privilegedScript("log erase --all"), revealURL: diagnostics,
                alsoClaims: [uuidtext]
            ))
        }

        let systemReports = URL(fileURLWithPath: "/Library/Logs/DiagnosticReports")
        if let item = await ProbeSupport.directoryItem(
            id: "log-system-reports", category: .logs, name: "System crash reports",
            detail: "Crash and hang reports for system processes.", url: systemReports, safety: .safe,
            action: .privilegedScript("rm -rf /Library/Logs/DiagnosticReports/*")
        ) {
            items.append(item)
        }

        let asl = URL(fileURLWithPath: "/private/var/log/asl")
        if let item = await ProbeSupport.directoryItem(
            id: "log-asl", category: .logs, name: "Legacy ASL logs",
            detail: "Old-style system logs in /private/var/log/asl.", url: asl, safety: .safe,
            action: .privilegedScript("rm -f /private/var/log/asl/*.asl")
        ) {
            items.append(item)
        }

        let userLogs = URL.home("Library/Logs")
        if let item = await ProbeSupport.directoryItem(
            id: "log-user", category: .logs, name: "User app logs",
            detail: "~/Library/Logs, including your own crash reports and CoreSimulator logs.",
            url: userLogs, safety: .safe, action: .emptyDirectories([userLogs])
        ) {
            items.append(item)
        }

        return items
    }
}

// MARK: - Temporary files

/// macOS only sweeps the per-user cache and temp folders on reboot or under
/// disk pressure. Files touched in the last few days are kept.
struct TempProbe: StorageProbe {
    static let keepDays = 3

    func probe() async -> [StorageItem] {
        let cutoff = Date().addingTimeInterval(-Double(Self.keepDays) * 86_400)
        var items: [StorageItem] = []

        let folders: [(String, String, Int32)] = [
            ("temp-cache", "User cache folder", _CS_DARWIN_USER_CACHE_DIR),
            ("temp-tmp", "User temp folder", _CS_DARWIN_USER_TEMP_DIR),
        ]
        for (id, name, key) in folders {
            guard let url = confstrDirectory(key) else { continue }
            let size = await DiskSize.allocated(at: url, olderThan: cutoff)
            guard size >= ProbeSupport.megabyte else { continue }
            items.append(StorageItem(
                id: id, category: .temp, name: name,
                detail: "\(url.path). Only files older than \(Self.keepDays) days are removed.",
                sizeBytes: size, safety: .safe,
                action: .pruneOlderThan(url, days: Self.keepDays), revealURL: url
            ))
        }
        return items
    }

    private func confstrDirectory(_ name: Int32) -> URL? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(name, &buffer, buffer.count) > 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self))
    }
}

// MARK: - Docker

struct DockerProbe: StorageProbe {
    func probe() async -> [StorageItem] {
        let vms = URL.home("Library/Containers/com.docker.docker/Data/vms")

        guard let docker = Shell.which("docker"),
              let info = try? await Shell.run(docker, ["info"], mergeStderr: false), info.succeeded,
              let df = try? await Shell.run(docker, ["system", "df", "--format", "{{json .}}"], mergeStderr: false),
              df.succeeded
        else {
            guard vms.exists else { return [] }
            return [await ProbeSupport.directoryItem(
                id: "docker-vm", category: .docker, name: "Docker disk image",
                detail: "Docker is not running, so it cannot be pruned right now.",
                url: vms, safety: .manual,
                action: .manual("Start Docker Desktop, then:\ndocker system prune -f\ndocker builder prune -f"),
                minimumBytes: 100 * ProbeSupport.megabyte
            )].compactMap { $0 }
        }

        var reclaimable: Int64 = 0
        for line in df.output.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = row["Reclaimable"] as? String else { continue }
            reclaimable += parseDockerSize(text)
        }
        guard reclaimable > 0 else { return [] }

        return [StorageItem(
            id: "docker-prune", category: .docker, name: "Unused images, containers and build cache",
            detail: "docker system prune. Volumes are kept.", sizeBytes: reclaimable, safety: .review,
            action: .command(executable: docker, arguments: ["system", "prune", "-f"]), revealURL: vms
        )]
    }

    /// Parses Docker's "1.23GB (45%)" strings.
    private func parseDockerSize(_ text: String) -> Int64 {
        let scanner = Scanner(string: text)
        guard let value = scanner.scanDouble() else { return 0 }
        let unit = scanner.scanCharacters(from: .letters)?.uppercased() ?? "B"
        let multiplier: Double = switch unit {
        case "KB": 1e3
        case "MB": 1e6
        case "GB": 1e9
        case "TB": 1e12
        default: 1
        }
        return Int64(value * multiplier)
    }
}

// MARK: - Trash

struct TrashProbe: StorageProbe {
    func probe() async -> [StorageItem] {
        let trash = URL.home(".Trash")
        return [await ProbeSupport.directoryItem(
            id: "trash", category: .trash, name: "Trash",
            detail: "Items waiting in the Trash.", url: trash, safety: .safe,
            action: .emptyDirectories([trash])
        )].compactMap { $0 }
    }
}

// MARK: - Miscellaneous system locations

struct SystemProbe: StorageProbe {
    func probe() async -> [StorageItem] {
        var items: [StorageItem] = []

        for installer in URL(fileURLWithPath: "/Applications").children()
        where installer.lastPathComponent.hasPrefix("Install macOS") && installer.pathExtension == "app" {
            if let item = await ProbeSupport.directoryItem(
                id: "sys-installer-\(installer.lastPathComponent)", category: .system,
                name: installer.deletingPathExtension().lastPathComponent,
                detail: "A downloaded macOS installer. Re-downloadable from Software Update.",
                url: installer, safety: .review, action: .removePaths([installer])
            ) {
                items.append(item)
            }
        }

        let updates = URL.home("Library/iTunes")
        for folder in updates.children() where folder.lastPathComponent.hasSuffix("Software Updates") {
            if let item = await ProbeSupport.directoryItem(
                id: "sys-ipsw-\(folder.lastPathComponent)", category: .system,
                name: folder.lastPathComponent, detail: "Downloaded device firmware (.ipsw).",
                url: folder, safety: .safe, action: .emptyDirectories([folder])
            ) {
                items.append(item)
            }
        }

        let mailDownloads = URL.home("Library/Containers/com.apple.mail/Data/Library/Mail Downloads")
        if let item = await ProbeSupport.directoryItem(
            id: "sys-mail-downloads", category: .system, name: "Mail attachment downloads",
            detail: "Attachments opened from Mail. The originals stay in the messages.",
            url: mailDownloads, safety: .safe, action: .emptyDirectories([mailDownloads]),
            minimumBytes: ProbeSupport.megabyte
        ) {
            items.append(item)
        }

        let systemCaches = URL(fileURLWithPath: "/Library/Caches")
        if let item = await ProbeSupport.directoryItem(
            id: "sys-library-caches", category: .system, name: "System-wide caches",
            detail: "/Library/Caches. Regenerated by the daemons that own them.",
            url: systemCaches, safety: .safe,
            action: .privilegedScript("rm -rf /Library/Caches/*"), minimumBytes: 10 * ProbeSupport.megabyte
        ) {
            items.append(item)
        }

        for entry in URL(fileURLWithPath: "/Library/Application Support").children() where entry.isDirectory {
            if let item = await ProbeSupport.directoryItem(
                id: "sys-app-support-\(entry.lastPathComponent)", category: .system,
                name: "System app data: \(entry.lastPathComponent)",
                detail: "/Library/Application Support. Installed for all users; uninstall the app instead when it has an uninstaller.",
                url: entry, safety: .review, action: .removePaths([entry]), minimumBytes: 200 * ProbeSupport.megabyte
            ) {
                items.append(item)
            }
        }

        let commandLineTools = URL(fileURLWithPath: "/Library/Developer/CommandLineTools")
        let hasXcode = URL(fileURLWithPath: "/Applications").children()
            .contains { $0.lastPathComponent.hasPrefix("Xcode") && $0.pathExtension == "app" }
        if let item = await ProbeSupport.directoryItem(
            id: "sys-clt", category: .system, name: "Command Line Tools",
            detail: hasXcode
                ? "Xcode is installed and already provides these tools. Reinstall with `xcode-select --install`."
                : "Compilers and SDK for the terminal. Needed when Xcode is not installed.",
            url: commandLineTools, safety: hasXcode ? .review : .manual,
            action: hasXcode
                ? .privilegedScript("rm -rf /Library/Developer/CommandLineTools")
                : .manual("Keep it, or remove with:\nsudo rm -rf /Library/Developer/CommandLineTools")
        ) {
            items.append(item)
        }

        if let item = await ProbeSupport.directoryItem(
            id: "sys-cryptex", category: .system, name: "macOS cryptexes",
            detail: "Sealed system components (Safari, dyld caches) under /private/var/run. Part of macOS.",
            url: URL(fileURLWithPath: "/private/var/run/com.apple.security.cryptexd"), safety: .manual,
            action: .manual("Managed by macOS. Cannot be removed."),
            minimumBytes: 100 * ProbeSupport.megabyte
        ) {
            items.append(item)
        }

        items.append(StorageItem(
            id: "sys-spotlight", category: .system, name: "Spotlight index",
            detail: "/.Spotlight-V100 is readable only by root, so its size is unknown. Rebuilding it drops stale entries.",
            sizeBytes: nil, safety: .manual,
            action: .manual("sudo mdutil -E /"),
            revealURL: nil
        ))

        if let item = await ProbeSupport.directoryItem(
            id: "sys-vm", category: .system, name: "Swap and sleep image",
            detail: "Managed by the kernel. Shrinks after a restart.",
            url: URL(fileURLWithPath: "/private/var/vm"), safety: .manual,
            action: .manual("Restart the Mac. To drop the sleep image permanently:\nsudo pmset -a hibernatemode 0\nsudo rm /private/var/vm/sleepimage"),
            minimumBytes: 100 * ProbeSupport.megabyte
        ) {
            items.append(item)
        }

        if let item = await ProbeSupport.directoryItem(
            id: "sys-icloud", category: .system, name: "iCloud Drive local copies",
            detail: "Files kept on disk for offline access.",
            url: URL.home("Library/Mobile Documents"), safety: .manual,
            action: .manual("System Settings > Apple Account > iCloud > Drive > turn on Optimize Mac Storage,\nor right-click a folder in Finder > Remove Download."),
            minimumBytes: 500 * ProbeSupport.megabyte
        ) {
            items.append(item)
        }

        return items
    }
}
