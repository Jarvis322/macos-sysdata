import Foundation

/// Every probe the app runs, in display order. Shared by the UI and `--json`.
enum ProbeRegistry {
    static let all: [any StorageProbe] = [
        SnapshotProbe(), SimulatorProbe(), RuntimeProbe(), XcodeProbe(), PackageProbe(),
        DeveloperToolProbe(), LogProbe(), TempProbe(), DockerProbe(), VirtualMachineProbe(),
        TrashProbe(), BackupProbe(), SharedProbe(), AndroidProbe(), AppCacheProbe(), AppDataProbe(),
        ProjectProbe(), SystemProbe(),
    ]

    /// Runs every probe concurrently, then the catch-all with what they claimed.
    static func inventory() async -> [StorageItem] {
        let results = await withTaskGroup(of: [StorageItem].self) { group in
            for probe in all {
                group.addTask { await probe.probe() }
            }
            var collected: [StorageItem] = []
            for await batch in group { collected += batch }
            return collected
        }
        return results + (await LargeFolderProbe(claimed: results.flatMap(\.claimedURLs)).probe())
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
