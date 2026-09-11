import Foundation

// MARK: - Developer tool data in hidden home folders

/// Version managers, model caches and language toolchains that hide in
/// dot-folders. Known ones get a name and a safety level; anything else over
/// the threshold is listed generically so nothing large stays invisible.
struct DeveloperToolProbe: StorageProbe {
    private struct Known {
        let path: String
        let name: String
        let detail: String
        let safety: Safety
        /// Tool whose own clean command should be used, if installed.
        let tool: (name: String, arguments: [String])?

        init(_ path: String, _ name: String, _ detail: String, _ safety: Safety,
             tool: (name: String, arguments: [String])? = nil) {
            self.path = path
            self.name = name
            self.detail = detail
            self.safety = safety
            self.tool = tool
        }
    }

    private static let known: [Known] = [
        Known(".ollama/models", "Ollama models", "Downloaded LLM weights. `ollama pull` fetches them again.", .review),
        Known(".cache/huggingface", "Hugging Face cache", "Downloaded models and datasets.", .review),
        Known(".cache/torch", "PyTorch cache", "Downloaded model weights.", .review),
        Known(".lmstudio", "LM Studio models", "Downloaded LLM weights.", .review),
        Known(".nvm/versions", "nvm Node versions", "Every Node.js installed with nvm. `nvm install` again.", .review),
        Known(".rustup/toolchains", "Rust toolchains", "`rustup toolchain install` again.", .review),
        Known(".pyenv/versions", "pyenv Python versions", "`pyenv install` again.", .review),
        Known(".rbenv/versions", "rbenv Ruby versions", "`rbenv install` again.", .review),
        Known(".sdkman/candidates", "SDKMAN toolchains", "`sdk install` again.", .review),
        Known("miniconda3", "Miniconda", "Conda environments and packages.", .review),
        Known("anaconda3", "Anaconda", "Conda environments and packages.", .review),
        Known(".conda/pkgs", "Conda package cache", "Downloaded packages.", .safe, tool: ("conda", ["clean", "--all", "-y"])),
        Known(".m2/repository", "Maven repository", "Downloaded jars. Re-fetched on the next build.", .safe),
        Known(".ivy2", "Ivy cache", "Downloaded jars for sbt.", .safe),
        Known(".cocoapods/repos", "CocoaPods specs repos", "`pod setup` rebuilds them.", .safe),
        Known(".gradle/wrapper/dists", "Gradle distributions", "Downloaded Gradle versions.", .safe),
        Known(".android/cache", "Android SDK download cache", "Re-downloaded on demand.", .safe),
        Known("go/pkg/mod", "Go module cache", "Downloaded modules.", .safe, tool: ("go", ["clean", "-modcache"])),
        Known(".bun/install/cache", "Bun cache", "Package tarballs.", .safe),
        Known(".deno", "Deno cache", "Cached modules.", .safe),
        Known(".vscode/extensions", "VS Code extensions", "Installed extensions. Reinstall from the marketplace.", .review),
        Known(".cursor/extensions", "Cursor extensions", "Installed extensions.", .review),
        Known(".docker", "Docker CLI data", "Contexts and build history, not images.", .review),
        Known(".orbstack", "OrbStack data", "Virtual machines and containers.", .review),
        Known(".lima", "Lima virtual machines", "VM disks.", .review),
        Known(".colima", "Colima virtual machine", "VM disk.", .review),
        Known(".claude", "Claude Code data", "Session transcripts, memory, plugins and caches. Deleting loses history.", .review),
        Known(".codex", "Codex CLI data", "Sessions and caches.", .review),
        // Reported as unrecognised in issue #1. Named so the list says what
        // made the folder, but left at Review: these hold sessions and signed-in
        // state as often as they hold cache, and none of them is safe to delete
        // unseen.
        Known(".grok", "Grok CLI data", "Sessions, settings and caches. Deleting loses history.", .review),
        Known(".copilot", "GitHub Copilot CLI data", "Sessions, settings and caches. Deleting signs you out.", .review),
        Known(".kilo", "Kilo Code data", "Sessions, settings and caches. Deleting loses history.", .review),
        Known(".gemini", "Gemini CLI data", "Settings and IDE support files.", .review),
        // Same shape as the VS Code and Cursor entries above: almost all of it
        // is installed extensions, which reinstall from the marketplace.
        Known(".antigravity-ide/extensions", "Antigravity extensions", "Installed extensions. Reinstall from the marketplace.", .review),
    ]

    /// Top-level dot-folders another probe already reports.
    private static let coveredTopLevel: Set<String> = [
        ".npm", ".cargo", ".Trash", ".android", ".gradle", ".cache",
    ]
    private static let threshold = 100 * ProbeSupport.megabyte

    func probe() async -> [StorageItem] {
        var items: [StorageItem] = []
        var claimedTopLevel: Set<String> = Self.coveredTopLevel
        var claimedCache: Set<String> = ["uv", "huggingface", "torch"]

        for entry in Self.known {
            let url = URL.home(entry.path)
            let action: ReclaimAction
            if let tool = entry.tool, let executable = Shell.which(tool.name) {
                action = .command(executable: executable, arguments: tool.arguments)
            } else {
                action = .removePaths([url])
            }
            if let item = await ProbeSupport.directoryItem(
                id: "tool-\(entry.path)", category: .tools, name: entry.name, detail: entry.detail,
                url: url, safety: entry.safety, action: action, minimumBytes: 10 * ProbeSupport.megabyte
            ) {
                items.append(item)
            }
            let top = entry.path.split(separator: "/").first.map(String.init) ?? entry.path
            claimedTopLevel.insert(top)
            if top == ".cache", let sub = entry.path.split(separator: "/").dropFirst().first {
                claimedCache.insert(String(sub))
            }
        }

        for folder in URL.home.children(includeHidden: true)
        where folder.isDirectory && folder.lastPathComponent.hasPrefix(".") && !claimedTopLevel.contains(folder.lastPathComponent) {
            if let item = await ProbeSupport.directoryItem(
                id: "tool-hidden-\(folder.lastPathComponent)", category: .tools,
                name: "Hidden folder \(folder.lastPathComponent)",
                detail: "Not recognised by this app. Usually a tool's data or cache; check what created it.",
                url: folder, safety: .review, action: .removePaths([folder]), minimumBytes: Self.threshold
            ) {
                items.append(item)
            }
        }

        for folder in URL.home(".cache").children(includeHidden: true)
        where folder.isDirectory && !claimedCache.contains(folder.lastPathComponent) {
            if let item = await ProbeSupport.directoryItem(
                id: "tool-cache-\(folder.lastPathComponent)", category: .tools,
                name: "Cache: \(folder.lastPathComponent)",
                detail: "~/.cache entry. Tools rebuild their caches on demand.",
                url: folder, safety: .safe, action: .removePaths([folder]), minimumBytes: Self.threshold
            ) {
                items.append(item)
            }
        }

        return items.sorted { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
    }
}

// MARK: - Anything large that no other probe explained

/// Walks the locations Finder folds into System Data and reports every folder
/// over the threshold that no other item accounts for. This is the safety net
/// that keeps the inventory complete on machines with software this app has
/// never heard of.
struct LargeFolderProbe: StorageProbe {
    let claimed: [URL]

    private static let roots: [URL] = [
        .home,
        URL(fileURLWithPath: "/Library"),
        URL(fileURLWithPath: "/private/var"),
        URL(fileURLWithPath: "/opt"),
        URL(fileURLWithPath: "/usr/local"),
        URL(fileURLWithPath: "/Users/Shared"),
    ]

    /// Locations Finder attributes to their own category (Photos, Music,
    /// Messages, Mail, Applications), so they are not System Data.
    ///
    /// Desktop, Documents and Downloads are on the list for a second reason:
    /// Storage settings counts them as Documents, and what is in them is the
    /// user's own work, which no delete regenerates. Listing "~/Desktop" at
    /// 102 GB beside a Delete button is one wrong click away from a very bad
    /// afternoon. The probes that have business there still run — build
    /// folders, virtual machines and Final Cut render files each have their
    /// own item, with a name that says what it is.
    private static let excluded: [URL] = [
        .home("Pictures"), .home("Music"), .home("Movies"),
        .home("Desktop"), .home("Documents"), .home("Downloads"),
        .home("Library/Messages"), .home("Library/Mail"), .home("Library/Containers/com.apple.mail"),
        .home("Library/Mobile Documents"), .home("Applications"),
        // Dropbox, OneDrive, Google Drive and every other File Provider sync
        // root. What is in them lives in someone's cloud account too, and a
        // delete here is a delete there.
        .home("Library/CloudStorage"),
    ]

    private static let threshold = 500 * ProbeSupport.megabyte
    private static let maxDepth = 4

    func probe() async -> [StorageItem] {
        let claimedPaths = claimed.map(\.standardizedFileURL.path)
        // Without Full Disk Access the containers are added to the exclusions:
        // descending into one asks macOS for permission by the owning app's
        // name, and a walk of ~/Library/Containers asks about all of them.
        let excludedPaths = (Self.excluded + (ProbeSupport.hasFullDiskAccess ? [] : [
            .home("Library/Containers"), .home("Library/Group Containers"),
        ])).map(\.path)

        return await withTaskGroup(of: [StorageItem].self) { group in
            // Boot volume only. A root that resolves onto an external drive —
            // a home folder relocated to a 10 TB disk, say — is not System
            // Data, and walking it is what left one machine's scan running for
            // over a day. The targeted probes still measure known caches there
            // by their own paths; this safety net does not walk the disk.
            for root in Self.roots where root.exists && DiskSize.isOnBootVolume(root) {
                group.addTask {
                    await Task.detached(priority: .utility) {
                        // Nothing under a claimed or excluded directory can ever
                        // be reported: `visit` returns on both before it looks at
                        // a size. Their bytes only ever fed the totals of parents,
                        // and a parent holding a claimed child is recursed into
                        // rather than listed, so leaving those bytes out cannot
                        // hide an item — a child that survives the filters is
                        // smaller than the reduced parent total by definition.
                        let sizes = DiskSize.directorySizes(
                            under: root, maxDepth: Self.maxDepth,
                            skipping: Set(claimedPaths + excludedPaths)
                        )
                        var items: [StorageItem] = []
                        for child in root.children(includeHidden: true) where child.isDirectory {
                            Self.visit(child, depth: 1, sizes: sizes, claimed: claimedPaths, excluded: excludedPaths, into: &items)
                        }
                        return items
                    }.value
                }
            }
            var all: [StorageItem] = []
            for await batch in group { all += batch }
            return all.sorted { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
        }
    }

    private static func visit(
        _ url: URL, depth: Int, sizes: [String: Int64], claimed: [String], excluded: [String],
        into items: inout [StorageItem]
    ) {
        let path = url.standardizedFileURL.path
        let prefix = path + "/"

        if excluded.contains(where: { $0 == path || prefix.hasPrefix($0 + "/") }) { return }
        // Inside something already listed.
        if claimed.contains(where: { $0 == path || prefix.hasPrefix($0 + "/") }) { return }

        guard let size = sizes[path], size >= threshold else { return }

        let containsClaimed = claimed.contains { $0.hasPrefix(prefix) }
        if containsClaimed || url.lastPathComponent == "Library" || url.lastPathComponent == "Application Support" {
            // Part of it is explained elsewhere; look one level deeper.
            guard depth < maxDepth else { return }
            for child in url.children(includeHidden: true) where child.isDirectory {
                visit(child, depth: depth + 1, sizes: sizes, claimed: claimed, excluded: excluded, into: &items)
            }
            return
        }

        items.append(StorageItem(
            id: "other-\(path)",
            category: .other,
            name: url.abbreviatedPath,
            detail: "Not recognised by this app. Open it in Finder and decide.",
            sizeBytes: size,
            safety: .review,
            action: .removePaths([url]),
            revealURL: url,
            // These are the rows the person has to judge with the least help,
            // so how long the folder has sat untouched is worth the extra
            // stat of its top level.
            lastModified: DiskSize.shallowLastModified(at: url)
        ))
    }
}
