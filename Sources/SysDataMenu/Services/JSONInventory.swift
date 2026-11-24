import Foundation

/// Every probe the app runs, in display order. Shared by the UI and `--json`.
enum ProbeRegistry {
    static let all: [any StorageProbe] = [
        SnapshotProbe(), SimulatorProbe(), RuntimeProbe(), XcodeProbe(), PackageProbe(),
        DeveloperToolProbe(), AIModelProbe(), LogProbe(), TempProbe(), DockerProbe(), VirtualMachineProbe(),
        TrashProbe(), BackupProbe(), SharedProbe(), AndroidProbe(), AppCacheProbe(), AppDataProbe(),
        ProjectProbe(), SystemProbe(), JetBrainsProbe(), UnityProbe(), SoundLibraryProbe(), ChatAppProbe(),
    ]

    /// Runs every probe concurrently, then the catch-all with what they claimed.
    static func inventory() async -> [StorageItem] {
        let results = await withTaskGroup(of: [StorageItem].self) { group in
            for probe in all {
                group.addTask { await probe.probe() }
            }
            var collected: [StorageItem] = []
            for await batch in group { collected += batch }
            return withoutOverlaps(collected)
        }
        return results + (await LargeFolderProbe(claimed: results.flatMap(\.claimedURLs)).probe())
    }

    /// Rows built by walking whatever is in a folder rather than by knowing
    /// what it is. The probes run at once and cannot see each other's
    /// claims, so one of these can contain a location another probe names.
    private static let genericPrefixes = [
        "tool-hidden-", "tool-cache-", "app-support-", "app-cache-", "app-container-", "app-group-",
        // A container engine's whole folder, measured as one row, while the
        // Docker rows report what is inside its VM disk.
        "tool-.colima", "tool-.orbstack",
    ]

    /// Drops every generic row that contains another row's location: its
    /// size counts those bytes a second time, in the header, the plan and
    /// the weekly clean. The catch-all then walks the dropped folder, sees
    /// the claimed part inside it and reports only what is left over.
    static func withoutOverlaps(_ items: [StorageItem]) -> [StorageItem] {
        let claims = items.map { item in
            (id: item.id, paths: item.claimedURLs.map { DiskSize.realPath($0.standardizedFileURL.path) })
        }
        return items.filter { item in
            guard genericPrefixes.contains(where: item.id.hasPrefix), let root = item.revealURL else { return true }
            let prefix = DiskSize.realPath(root.standardizedFileURL.path) + "/"
            return !claims.contains { other in
                other.id != item.id && other.paths.contains { $0.hasPrefix(prefix) }
            }
        }
    }
}

/// `SysDataMenu --json` output: one record per item, largest first.
struct InventoryRecord: Codable {
    let id: String
    let category: String
    let name: String
    let detail: String
    let sizeBytes: Int64?
    let safety: String
    let manual: Bool
    let path: String?
    /// When anything inside last changed, ISO-8601. Absent when this app did
    /// not measure a folder for the item.
    let lastModified: String?
    let idleDays: Int?

    init(_ item: StorageItem) {
        id = item.id
        category = item.category.rawValue
        name = item.name
        detail = item.detail
        sizeBytes = item.sizeBytes
        safety = switch item.safety {
        case .safe: "safe"
        case .review: "review"
        case .manual: "manual"
        }
        manual = item.action.isManual
        path = item.revealURL?.path
        lastModified = item.lastModified.map(ISO8601DateFormatter().string(from:))
        idleDays = item.idleDays
    }
}

enum JSONInventory {
    static func write(to output: FileHandle) async {
        let items = await ProbeRegistry.inventory()
            .sorted { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let payload: [String: Any] = [
            "generatedAt": ISO8601DateFormatter().string(from: .now),
            "freeBytes": DiskSize.freeSpace(),
            "purgeableBytes": DiskSize.purgeableSpace(),
            "totalBytes": items.reduce(0) { $0 + ($1.sizeBytes ?? 0) },
            "items": (try? JSONSerialization.jsonObject(with: encoder.encode(items.map(InventoryRecord.init)))) ?? [],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            output.write(data)
            output.write(Data("\n".utf8))
        }
    }
}
