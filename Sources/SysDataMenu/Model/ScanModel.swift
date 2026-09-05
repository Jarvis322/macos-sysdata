import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class ScanModel {
    private(set) var items: [StorageItem] = []
    private(set) var isScanning = false
    private(set) var hasScanned = false
    private(set) var freeBytes: Int64 = DiskSize.freeSpace()
    private(set) var reclaimedBytes: Int64 = 0
    private(set) var busyItemIDs: Set<String> = []
    /// Short description of what the scan is doing right now.
    private(set) var phase = ""
    private(set) var hasFullDiskAccess = ScanModel.checkFullDiskAccess()
    private(set) var launchesAtLogin = SMAppService.mainApp.status == .enabled
    var selectedIDs: Set<String> = []
    var errorMessage: String?

    /// Registers or removes the app as a login item. macOS quits the app when
    /// Full Disk Access is granted, so coming back on login is worth having.
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = "Launch at login: \(error.localizedDescription)"
        }
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }

    private let probes: [any StorageProbe] = [
        SnapshotProbe(), SimulatorProbe(), RuntimeProbe(), XcodeProbe(), PackageProbe(),
        DeveloperToolProbe(), LogProbe(), TempProbe(), DockerProbe(), TrashProbe(), BackupProbe(),
        SharedProbe(), AndroidProbe(), AppDataProbe(), ProjectProbe(), SystemProbe(),
    ]

    var measuredBytes: Int64 {
        items.reduce(0) { $0 + ($1.sizeBytes ?? 0) }
    }

    var selectedItems: [StorageItem] {
        items.filter { selectedIDs.contains($0.id) }
    }

    var selectedBytes: Int64 {
        selectedItems.reduce(0) { $0 + ($1.sizeBytes ?? 0) }
    }

    /// Full Disk Access is the one grant that covers every folder the scan
    /// touches. ~/Library/Safari is TCC-protected, so listing it only works
    /// once the grant exists.
    static func checkFullDiskAccess() -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: URL.home("Library/Safari").path)) != nil
    }

    func refreshAccess() {
        hasFullDiskAccess = Self.checkFullDiskAccess()
    }

    func toggleSelection(_ item: StorageItem) {
        guard !item.action.isManual else { return }
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
    }

    func selectAllSafe() {
        selectedIDs = Set(items.filter { $0.safety == .safe && !$0.action.isManual }.map(\.id))
    }

    func clearSelection() {
        selectedIDs = []
    }

    var categories: [(category: StorageCategory, items: [StorageItem], total: Int64)] {
        StorageCategory.allCases.compactMap { category in
            let members = items.filter { $0.category == category }
            guard !members.isEmpty else { return nil }
            return (category, members, members.reduce(0) { $0 + ($1.sizeBytes ?? 0) })
        }
    }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        errorMessage = nil
        selectedIDs = []
        refreshAccess()
        phase = "Measuring known locations…"
        defer {
            isScanning = false
            hasScanned = true
            phase = ""
        }

        let probes = self.probes
        let results = await withTaskGroup(of: [StorageItem].self) { group in
            for probe in probes {
                group.addTask { await probe.probe() }
            }
            var collected: [StorageItem] = []
            for await batch in group { collected += batch }
            return collected
        }

        items = results
        freeBytes = DiskSize.freeSpace()

        // The catch-all pass needs to know what is already explained, so it
        // runs after everything else and streams in as a second update.
        phase = "Looking for anything else over 500 MB…"
        let claimed = results.flatMap(\.claimedURLs)
        items += await LargeFolderProbe(claimed: claimed).probe()
    }

    func reclaim(_ item: StorageItem) async {
        await reclaim([item])
    }

    /// Deletes the selection. Everything that needs root is folded into one
    /// script so the administrator password is asked for once per batch.
    func reclaimSelected() async {
        let chosen = selectedItems
        selectedIDs = []
        await reclaim(chosen)
    }

    func reclaim(_ batch: [StorageItem]) async {
        let runnable = batch.filter { !busyItemIDs.contains($0.id) && !$0.action.isManual }
        errorMessage = nil

        var privileged: [(item: StorageItem, script: String)] = []
        var direct: [StorageItem] = []
        for item in runnable {
            if case .privilegedScript(let script) = item.action {
                privileged.append((item, script))
            } else {
                direct.append(item)
            }
        }

        if privileged.count == 1 {
            direct.insert(privileged[0].item, at: 0)
        } else if privileged.count > 1 {
            let combined = privileged.map(\.script).joined(separator: " ; ")
            await perform(.privilegedScript(combined), for: privileged.map(\.item))
        }

        for item in direct {
            await perform(item.action, for: [item])
        }
    }

    private func perform(_ action: ReclaimAction, for affected: [StorageItem]) async {
        let ids = Set(affected.map(\.id))
        busyItemIDs.formUnion(ids)
        defer { busyItemIDs.subtract(ids) }

        let before = DiskSize.freeSpace()
        do {
            try await Reclaimer.perform(action)
            items.removeAll { ids.contains($0.id) }
            let after = DiskSize.freeSpace()
            let expected = affected.reduce(0) { $0 + ($1.sizeBytes ?? 0) }
            reclaimedBytes += max(after - before, expected)
            freeBytes = after
        } catch {
            let names = affected.map(\.name).joined(separator: ", ")
            errorMessage = "\(names): \(error.localizedDescription)"
        }
    }
}
