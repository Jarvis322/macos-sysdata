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

    /// Exactly what this action does, one line per operation.
    ///
    /// The README says the source is published so anyone can see what the app
    /// does to their machine. This is that promise inside the app: the person
    /// about to type an administrator password can read the command first,
    /// which is the one moment reading it matters.
    var plan: [String] {
        switch self {
        case .removePaths(let urls):
            urls.map { L("Delete %@", $0.path) }
        case .emptyDirectories(let urls):
            urls.map { L("Delete everything inside %@", $0.path) }
        case .pruneOlderThan(let url, let days):
            [L("Delete files older than %lld days in %@", days, url.path)]
        case .command(let executable, let arguments):
            [([executable] + arguments).joined(separator: " ")]
        case .privilegedScript(let script):
            [L("As administrator: %@", script)]
        case .shutdownSimulators:
            [L("Shut every simulator down first")]
        case .steps(let actions):
            actions.flatMap(\.plan)
        case .manual:
            []
        }
    }

    /// Whether running this asks for an administrator password.
    ///
    /// A privileged script always does. So does a plain delete of something
    /// this user cannot unlink: `Reclaimer` falls back to `rm -rf` as root
    /// rather than failing, which is the right behaviour and an invisible one
    /// — the confirmation used to count only the scripts and promise a single
    /// prompt above a batch that would ask several times.
    var needsAdministrator: Bool {
        switch self {
        case .privilegedScript: true
        case .steps(let actions): actions.contains(where: \.needsAdministrator)
        default: !pathsNeedingRoot.isEmpty
        }
    }

    /// Paths this action would have to delete as root, using the same test the
    /// reclaimer uses before it decides.
    var pathsNeedingRoot: [URL] {
        paths.filter { $0.exists && !FileManager.default.isDeletableFile(atPath: $0.path) }
    }

    /// Whether one password prompt covers this action. Privileged scripts in a
    /// batch are folded into a single script; a root-owned path is deleted by
    /// its own `rm`, so each one asks again.
    var asksForThePasswordSeparately: Bool {
        switch self {
        case .privilegedScript: false
        case .steps(let actions): actions.contains(where: \.asksForThePasswordSeparately)
        default: !pathsNeedingRoot.isEmpty
        }
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
    /// When anything inside this item last changed. `nil` when the item is not
    /// a place on disk this app measured — a `docker system prune` estimate,
    /// an APFS snapshot — rather than "never used".
    let lastModified: Date?
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
        lastModified: Date? = nil,
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
        self.lastModified = lastModified
        self.alsoClaims = alsoClaims
    }

    /// Whole days since anything inside changed.
    var idleDays: Int? {
        guard let lastModified else { return nil }
        return Calendar.current.dateComponents([.day], from: lastModified, to: .now).day.map { max($0, 0) }
    }

    /// Short "untouched for" phrase, or nil when the item is too recent to be
    /// worth a badge. Below a fortnight the age says nothing useful: a cache
    /// touched yesterday and one touched last week are both simply in use.
    var idleLabel: String? {
        guard let days = idleDays, days >= 14 else { return nil }
        let months = days / 30
        let years = days / 365
        if years >= 1 { return years == 1 ? L("1 year idle") : L("%lld years idle", years) }
        if months >= 1 { return months == 1 ? L("1 month idle") : L("%lld months idle", months) }
        return L("%lld days idle", days)
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

/// How rows are ordered inside a category.
enum SortOrder: String, CaseIterable, Identifiable, Sendable {
    case size, age

    var id: String { rawValue }

    var title: String {
        switch self {
        case .size: L("Size")
        case .age: L("Idle longest")
        }
    }
}

/// What the menu bar shows at rest. The size of System Data is the default
/// because it is the number the app exists to make visible; some people would
/// rather watch free space, and some want neither taking up the bar.
enum MenuBarContent: String, CaseIterable, Identifiable, Sendable {
    case systemData, freeSpace, iconOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .systemData: L("System Data size")
        case .freeSpace: L("Free space")
        case .iconOnly: L("Icon only")
        }
    }
}
