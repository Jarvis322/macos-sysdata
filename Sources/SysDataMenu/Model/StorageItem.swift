import Foundation

/// Groups in the menu, in display order.
enum StorageCategory: String, CaseIterable, Identifiable, Sendable {
    case snapshots, simulators, runtimes, xcode, packages, tools, logs, temp, docker
    case trash, backups, shared, android, apps, projects, system, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .snapshots: "Time Machine snapshots"
        case .simulators: "Simulator devices"
        case .runtimes: "Simulator runtimes"
        case .xcode: "Xcode"
        case .packages: "Package managers"
        case .tools: "Developer tool data"
        case .logs: "Logs & diagnostics"
        case .temp: "Temporary files"
        case .docker: "Docker"
        case .trash: "Trash"
        case .backups: "iOS device backups"
        case .shared: "Shared & other users"
        case .android: "Android"
        case .apps: "Large app data"
        case .projects: "Project build folders"
        case .system: "System"
        case .other: "Other large folders"
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
        case .safe: "Safe"
        case .review: "Review"
        case .manual: "Manual"
        }
    }
}

enum ReclaimAction: Sendable {
    case removePaths([URL])
    case emptyDirectories([URL])
    case pruneOlderThan(URL, days: Int)
    case command(executable: String, arguments: [String])
    case privilegedScript(String)
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
        case .command, .privilegedScript, .manual: []
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
}

extension Int64 {
    var byteString: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
