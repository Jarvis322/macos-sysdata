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
    /// How far through the probes the scan is. The window shows the count
    /// because the first scan on a full disk takes long enough that silence
    /// reads as a hang.
    private(set) var probesFinished = 0
    private(set) var probesTotal = 0
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
    /// Narrows the list to matching items. Clearing the selection on every
    /// change is deliberate: a selection made before a filter would otherwise
    /// still be deleted by "Delete N selected" while the user can no longer
    /// see what is in it.
    var filterText = "" {
        didSet {
            guard filterText != oldValue else { return }
            selectedIDs = []
            selectionAnchorID = nil
        }
    }
    /// Where a shift-click measures its range from.
    private var selectionAnchorID: String?
    /// What previous scans and deletions recorded. Read once per scan rather
    /// than per row, because the list redraws far more often than it changes.
    private(set) var history = ScanHistory.load()
    /// Whether scans and deletions are written down at all. On by default:
    /// the app already knows everything the log holds, and without it the
    /// list cannot say anything about change. Turning it off deletes the file.
    var keepsHistory: Bool = UserDefaults.standard.object(forKey: ScanModel.historyKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(keepsHistory, forKey: Self.historyKey)
            if !keepsHistory {
                ScanHistory.forget()
                history = ScanHistory.Log()
            }
        }
    }
    /// What the rows inside a category are ordered by. Size answers "what is
    /// big"; age answers "what is dead". Sorting by age and shift-clicking a
    /// range is how the untouched things get selected, which is safer than a
    /// button that ticks them all on the person's behalf.
    var sortOrder: SortOrder = SortOrder(rawValue: UserDefaults.standard.string(forKey: ScanModel.sortKey) ?? "") ?? .size {
        didSet { UserDefaults.standard.set(sortOrder.rawValue, forKey: Self.sortKey) }
    }
    var errorMessage: String?
    /// Non-error feedback, such as "moved to the Trash".
    var notice: String?

    private static let hiddenKey = "hiddenItemIDs"
    private static let sortKey = "sortOrder"
    private static let historyKey = "keepsHistory"
    private static let rescanInterval: Duration = .seconds(24 * 60 * 60)

    /// `scansAutomatically` is off for the headless modes, which drive the
    /// scan themselves. `items` starts the model on a known list instead of
    /// whichever machine the tests happen to run on.
    init(scansAutomatically: Bool = true, items: [StorageItem] = []) {
        self.items = items
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

    /// What the list shows: visible items narrowed by the filter. The totals
    /// in the header and the menu bar stay on `visibleItems`, because they
    /// answer "how much System Data is there", not "what am I looking at".
    var listedItems: [StorageItem] {
        visibleItems.filter { $0.matches(filter: filterText) }
    }

    func hide(_ item: StorageItem) {
        hiddenIDs.insert(item.id)
        selectedIDs.remove(item.id)
        if selectionAnchorID == item.id { selectionAnchorID = nil }
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

    func setSelection(
        _ item: StorageItem,
        selected: Bool,
        extendingRange: Bool,
        selectableItems: [StorageItem]
    ) {
        guard !item.action.isManual else { return }

        if extendingRange,
           let anchorID = selectionAnchorID,
           let anchorIndex = selectableItems.firstIndex(where: { $0.id == anchorID }),
           let itemIndex = selectableItems.firstIndex(where: { $0.id == item.id }) {
            let bounds = min(anchorIndex, itemIndex)...max(anchorIndex, itemIndex)
            let rangeIDs = Set(selectableItems[bounds].map(\.id))
            if selected {
                selectedIDs.formUnion(rangeIDs)
            } else {
                selectedIDs.subtract(rangeIDs)
            }
            return
        }

        if selected { selectedIDs.insert(item.id) }
        else { selectedIDs.remove(item.id) }
        selectionAnchorID = item.id
    }

    /// The header checkbox reads and writes the rows under that header, which
    /// is `listedItems` and not `visibleItems`: a filtered-out row is not
    /// under the header, and ticking it would put it in the next batch delete
    /// unseen.
    func isCategorySelected(_ category: StorageCategory) -> Bool {
        let selectableIDs = selectableItems(in: category).map(\.id)
        return !selectableIDs.isEmpty && selectableIDs.allSatisfy(selectedIDs.contains)
    }

    func categoryHasSelectableItems(_ category: StorageCategory) -> Bool {
        !selectableItems(in: category).isEmpty
    }

    func setSelection(_ category: StorageCategory, selected: Bool) {
        let ids = Set(selectableItems(in: category).map(\.id))
        if selected { selectedIDs.formUnion(ids) }
        else { selectedIDs.subtract(ids) }
        selectionAnchorID = nil
    }

    /// Drops the whole category from the selection. Collapsing a category
    /// calls this, so a fold never leaves ticked rows behind the chevron for
    /// "Delete N selected" to pick up.
    func deselect(_ category: StorageCategory) {
        selectedIDs.subtract(visibleItems.filter { $0.category == category }.map(\.id))
        selectionAnchorID = nil
    }

    private func selectableItems(in category: StorageCategory) -> [StorageItem] {
        listedItems.filter { $0.category == category && !$0.action.isManual }
    }

    /// Only what is on screen: ticking rows the filter is hiding would put
    /// them in the next batch delete unseen.
    func selectAllSafe() {
        selectedIDs = Set(listedItems.filter { $0.safety == .safe && !$0.action.isManual }.map(\.id))
        selectionAnchorID = nil
    }

    func clearSelection() {
        selectedIDs = []
        selectionAnchorID = nil
    }

    var categories: [(category: StorageCategory, items: [StorageItem], total: Int64)] {
        let visible = listedItems
        return StorageCategory.allCases.compactMap { category in
            let members = visible.filter { $0.category == category }
            guard !members.isEmpty else { return nil }
            return (category, sorted(members), members.reduce(0) { $0 + ($1.sizeBytes ?? 0) })
        }
    }

    private func sorted(_ items: [StorageItem]) -> [StorageItem] {
        switch sortOrder {
        case .size:
            items.sorted { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
        case .age:
            // Items with no date are not "new": they are things this app did
            // not measure a folder for, such as a Docker estimate. They sort
            // last rather than claiming an age they do not have.
            items.sorted {
                switch ($0.lastModified, $1.lastModified) {
                case let (left?, right?): left < right
                case (nil, _?): false
                case (_?, nil): true
                case (nil, nil): ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0)
                }
            }
        }
    }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        errorMessage = nil
        selectedIDs = []
        filterText = ""
        selectionAnchorID = nil
        refreshAccess()
        phase = L("Measuring known locations…")
        defer {
            isScanning = false
            hasScanned = true
            phase = ""
        }

        let probes = ProbeRegistry.all
        probesFinished = 0
        probesTotal = probes.count
        items = []

        // Each probe's findings land as they arrive rather than all at the
        // end. The scan takes a while on a full disk, and a window that stays
        // empty until every probe has finished cannot be told apart from one
        // that has hung.
        var results: [StorageItem] = []
        await withTaskGroup(of: [StorageItem].self) { group in
            for probe in probes {
                group.addTask { await probe.probe() }
            }
            for await batch in group {
                results += batch
                items = results
                probesFinished += 1
                phase = L("Measuring… %lld of %lld places", probesFinished, probesTotal)
            }
        }

        freeBytes = DiskSize.freeSpace()
        purgeableBytes = DiskSize.purgeableSpace()

        // The catch-all pass needs to know what is already explained, so it
        // runs after everything else and streams in as a second update.
        phase = L("Looking for anything else over 500 MB…")
        let claimed = results.flatMap(\.claimedURLs)
        items += await LargeFolderProbe(claimed: claimed).probe()
        lastScan = .now

        if keepsHistory {
            // Written after the catch-all so the record is the whole picture,
            // not the two thirds that finished first.
            let measured = items
            let free = freeBytes
            await Task.detached(priority: .utility) {
                ScanHistory.record(measured, freeBytes: free)
            }.value
            history = ScanHistory.load()
        }
        await LowSpaceAlert.check(freeBytes: freeBytes, reclaimable: safeBytes)
    }

    /// How much this item grew or shrank since the previous scan, or nil when
    /// there is nothing to compare it against. Nil is not zero and must not be
    /// drawn as "no change".
    func change(since previousScan: StorageItem) -> Int64? {
        ScanHistory.change(forItem: previousScan.id, in: history)
    }

    func reclaim(_ item: StorageItem) async {
        await reclaim([item])
    }

    /// Deletes the selection. Everything that needs root is folded into one
    /// script so the administrator password is asked for once per batch.
    func reclaimSelected() async {
        let chosen = selectedItems
        selectedIDs = []
        selectionAnchorID = nil
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
            let movedToTrash = try await Reclaimer.perform(action, preferTrash: toTrash)
            if keepsHistory {
                // Written before the size is forgotten, and before the free
                // space is re-read, so it records what was asked for even if
                // the disk disagrees about what it got.
                for item in affected {
                    ScanHistory.record(deleted: item, bytes: item.sizeBytes ?? 0)
                }
                history = ScanHistory.load()
            }
            items.removeAll { ids.contains($0.id) }
            let after = DiskSize.freeSpace()
            let expected = affected.reduce(0) { $0 + ($1.sizeBytes ?? 0) }
            // A trashed item is renamed onto the same volume, so the drive has
            // no more room than before. Falling back to the item's size there
            // would credit the header with space the disk does not have, right
            // next to a notice saying the Trash still has to be emptied.
            reclaimedBytes += movedToTrash ? max(after - before, 0) : max(after - before, expected)
            freeBytes = after
            purgeableBytes = DiskSize.purgeableSpace()
            if movedToTrash {
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
