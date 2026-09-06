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
    var shutsDownSimulatorsAtPowerOff = PowerOffGuard.isEnabled {
        didSet { PowerOffGuard.isEnabled = shutsDownSimulatorsAtPowerOff }
    }
    private(set) var purgeableBytes: Int64 = DiskSize.purgeableSpace()
    private(set) var lastScan: Date?
    /// Items the user chose not to see again. Persisted; ids are path-based.
    private(set) var hiddenIDs: Set<String>
    var selectedIDs: Set<String> = []
    var errorMessage: String?
    /// Non-error feedback, such as "moved to the Trash".
    var notice: String?

    private static let hiddenKey = "hiddenItemIDs"
    private static let rescanInterval: Duration = .seconds(24 * 60 * 60)

    /// `scansAutomatically` is off for the headless modes, which drive the
    /// scan themselves.
    init(scansAutomatically: Bool = true) {
        hiddenIDs = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenKey) ?? [])
        if scansAutomatically {
            Task { await runBackgroundScans() }
        }
    }

    /// Scans on launch and once a day after that, so the menu bar total is
    /// meaningful without opening the window.
    private func runBackgroundScans() async {
        while !Task.isCancelled {
            await scan()
            try? await Task.sleep(for: Self.rescanInterval)
        }
    }

    var visibleItems: [StorageItem] {
        items.filter { !hiddenIDs.contains($0.id) }
    }

    var hiddenCount: Int {
        items.count - visibleItems.count
    }

    func hide(_ item: StorageItem) {
        hiddenIDs.insert(item.id)
        selectedIDs.remove(item.id)
        UserDefaults.standard.set(Array(hiddenIDs).sorted(), forKey: Self.hiddenKey)
    }

    func unhideAll() {
        hiddenIDs = []
        UserDefaults.standard.removeObject(forKey: Self.hiddenKey)
    }

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
            errorMessage = L("Launch at login: %@", error.localizedDescription)
        }
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }

    var measuredBytes: Int64 {
        visibleItems.reduce(0) { $0 + ($1.sizeBytes ?? 0) }
    }

    /// What can be freed right now without losing anything.
    var safeBytes: Int64 {
        visibleItems.filter { $0.safety == .safe }.reduce(0) { $0 + ($1.sizeBytes ?? 0) }
    }

    var selectedItems: [StorageItem] {
        visibleItems.filter { selectedIDs.contains($0.id) }
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
        selectedIDs = Set(visibleItems.filter { $0.safety == .safe && !$0.action.isManual }.map(\.id))
    }

    func clearSelection() {
        selectedIDs = []
    }

    var categories: [(category: StorageCategory, items: [StorageItem], total: Int64)] {
        let visible = visibleItems
        return StorageCategory.allCases.compactMap { category in
            let members = visible.filter { $0.category == category }
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
        phase = L("Measuring known locations…")
        defer {
            isScanning = false
            hasScanned = true
            phase = ""
        }

        let probes = ProbeRegistry.all
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
        purgeableBytes = DiskSize.purgeableSpace()

        // The catch-all pass needs to know what is already explained, so it
        // runs after everything else and streams in as a second update.
        phase = L("Looking for anything else over 500 MB…")
        let claimed = results.flatMap(\.claimedURLs)
        items += await LargeFolderProbe(claimed: claimed).probe()
        lastScan = .now
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
        notice = nil

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
            let items = privileged.map(\.item)
            let combined = privileged.map(\.script).joined(separator: " ; ")
            guard await perform(.privilegedScript(combined), for: items) else {
                // Dismissing the password dialog is the last chance anyone has
                // to stop a batch. It stops the whole batch, not just the part
                // that needed the password.
                stopped(after: 0, remaining: items + direct)
                return
            }
        }

        var deleted = 0
        for (index, item) in direct.enumerated() {
            guard await perform(item.action, for: [item]) else {
                stopped(after: deleted, remaining: Array(direct[index...]))
                return
            }
            deleted += 1
        }
    }

    /// Puts the untouched items back in the selection and says plainly how far
    /// the batch got, because "cancelled" next to a rising reclaimed total is
    /// what makes people think the app ignored them.
    private func stopped(after deleted: Int, remaining: [StorageItem]) {
        selectedIDs = Set(remaining.map(\.id))
        errorMessage = nil
        notice = deleted == 0
            ? L("Cancelled. Nothing was deleted.")
            : L("Cancelled. %d already deleted, the rest left alone.", deleted)
    }

    /// Returns false when the person dismissed the authorization dialog, so
    /// the caller can stop instead of carrying on down the list.
    @discardableResult
    private func perform(_ action: ReclaimAction, for affected: [StorageItem]) async -> Bool {
        let ids = Set(affected.map(\.id))
        busyItemIDs.formUnion(ids)
        defer { busyItemIDs.subtract(ids) }

        // Review items go to the Trash so a wrong click can be undone; Safe
        // items regenerate anyway and are deleted outright.
        let toTrash = affected.allSatisfy { $0.safety == .review }
        let before = DiskSize.freeSpace()
        do {
            try await Reclaimer.perform(action, preferTrash: toTrash)
            items.removeAll { ids.contains($0.id) }
            let after = DiskSize.freeSpace()
            let expected = affected.reduce(0) { $0 + ($1.sizeBytes ?? 0) }
            reclaimedBytes += max(after - before, expected)
            freeBytes = after
            purgeableBytes = DiskSize.purgeableSpace()
            if toTrash, case .removePaths = action {
                notice = L("Moved to the Trash. Empty the Trash to free the space.")
            }
        } catch {
            if let command = error as? CommandError, command.wasCancelled { return false }
            let names = affected.map(\.name).joined(separator: ", ")
            errorMessage = "\(names): \(error.localizedDescription)"
        }
        return true
    }
}
