import Foundation

/// Groups in the menu, in display order.
enum StorageCategory: String, CaseIterable, Identifiable, Sendable {
    case snapshots, simulators, runtimes, xcode, packages, tools, logs, temp, docker
    case vms, trash, backups, shared, android, apps, projects, system, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .snapshots: L("Time Machine snapshots")
        case .simulators: L("Simulator devices")
        case .runtimes: L("Simulator runtimes")
        case .xcode: L("Xcode")
        case .packages: L("Package managers")
        case .tools: L("Developer tool data")
        case .logs: L("Logs & diagnostics")
        case .temp: L("Temporary files")
        case .docker: L("Docker")
        case .vms: L("Virtual machines")
        case .trash: L("Trash")
        case .backups: L("iOS device backups")
        case .shared: L("Shared & other users")
        case .android: L("Android")
        case .apps: L("App data & caches")
        case .projects: L("Project build folders")
        case .system: L("System")
        case .other: L("Other large folders")
        }
    }
}

/// How much thought a deletion needs. Drives the badge and the confirmation copy.
enum Safety: Sendable {
    /// Regenerated automatically by macOS or the owning tool.
    case safe
    /// Deletable, but the user loses something they may want (a device, a login, a download).
    case review
    /// Cannot be removed by this app; instructions are shown instead.
    case manual

    var label: String {
        switch self {
        case .safe: L("Safe")
        case .review: L("Review")
        case .manual: L("Manual")
        }
    }
}

enum ReclaimAction: Sendable {
    case removePaths([URL])
    case emptyDirectories([URL])
    case pruneOlderThan(URL, days: Int)
    case command(executable: String, arguments: [String])
    case privilegedScript(String)
    /// Shuts every simulator down, ignoring the result. Files a booted
    /// simulator has mapped cannot be deleted, not even by root.
    case shutdownSimulators
    /// Runs several actions in order, stopping at the first failure.
    indirect case steps([ReclaimAction])
    case manual(String)

    var isManual: Bool {
        if case .manual = self { return true }
        return false
    }

    var manualInstructions: String? {
        if case .manual(let text) = self { return text }
        return nil
    }

    /// Filesystem locations this action touches.
    var paths: [URL] {
        switch self {
        case .removePaths(let urls), .emptyDirectories(let urls): urls
        case .pruneOlderThan(let url, _): [url]
        case .steps(let actions): actions.flatMap(\.paths)
        case .command, .privilegedScript, .shutdownSimulators, .manual: []
        }
    }
}

struct StorageItem: Identifiable, Sendable {
    let id: String
    let category: StorageCategory
    let name: String
    let detail: String
    /// `nil` when the size cannot be measured (APFS snapshots).
    let sizeBytes: Int64?
    let safety: Safety
    let action: ReclaimAction
    let revealURL: URL?
    /// Locations this item accounts for beyond its action and reveal paths
    /// (for example the second half of the unified log store).
    let alsoClaims: [URL]

    init(
        id: String,
        category: StorageCategory,
        name: String,
        detail: String,
        sizeBytes: Int64?,
        safety: Safety,
        action: ReclaimAction,
        revealURL: URL? = nil,
        alsoClaims: [URL] = []
    ) {
        self.id = id
        self.category = category
        self.name = name
        self.detail = detail
        self.sizeBytes = sizeBytes
        self.safety = safety
        self.action = action
        self.revealURL = revealURL
        self.alsoClaims = alsoClaims
    }

    /// Every location this item accounts for, so the catch-all scan can skip it.
    var claimedURLs: [URL] {
        action.paths + (revealURL.map { [$0] } ?? []) + alsoClaims
    }

    /// Whether the filter keeps this item. The category title is matched too,
    /// so typing "simulator" brings back the whole group rather than only the
    /// rows that happen to repeat the word.
    func matches(filter needle: String) -> Bool {
        let needle = needle.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return true }
        return name.lowercased().contains(needle)
            || detail.lowercased().contains(needle)
            || category.title.lowercased().contains(needle)
    }
}

extension Int64 {
    /// File-style byte count; "0 bytes" rather than "Zero KB".
    var byteString: String {
        formatted(.byteCount(style: .file, spellsOutZero: false))
    }
}
