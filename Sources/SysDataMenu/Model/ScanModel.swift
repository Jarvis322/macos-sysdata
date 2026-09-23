import Foundation
import WidgetKit
import WidgetSnapshot
import Observation
import ServiceManagement

@MainActor
@Observable
final class ScanModel {
    private(set) var items: [StorageItem] = []
    private(set) var isScanning = false
    private(set) var hasScanned = false
    private(set) var freeBytes: Int64 = DiskSize.freeSpace()
    private(set) var capacityBytes: Int64 = DiskSize.capacity()
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
    /// Narrows the list to matching items. The selection survives it: ticking
    /// "Select safe" and then typing a filter to untick two of them is the
    /// obvious way to use the two together, and dropping the selection on the
    /// first keystroke made that impossible.
    ///
    /// What the selection must never do is act on rows nobody can see, so the
    /// footer says how many of them the filter is hiding instead
    /// (`selectedHiddenByFilterCount`). The shift-click anchor is dropped,
    /// because the row it measures from may no longer be listed.
    var filterText = "" {
        didSet {
            guard filterText != oldValue else { return }
            selectionAnchorID = nil
        }
    }
    /// Categories folded shut. It lives here rather than in the view because
    /// it decides the same thing the filter does — what is on screen — and the
    /// selection rules are written in terms of that.
    var collapsedCategories: Set<StorageCategory> = [] {
        didSet {
            guard collapsedCategories != oldValue else { return }
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
    /// Whether the app puts an icon in the menu bar at all. With it off the
    /// app lives in its window, and the Dock is what reopens it.
    var showsMenuBarIcon: Bool = UserDefaults.standard.object(forKey: ScanModel.menuBarIconKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(showsMenuBarIcon, forKey: Self.menuBarIconKey) }
    }
    /// What the menu bar shows at rest.
    var menuBarContent: MenuBarContent = MenuBarContent(rawValue: UserDefaults.standard.string(forKey: ScanModel.menuBarKey) ?? "") ?? .systemData {
        didSet { UserDefaults.standard.set(menuBarContent.rawValue, forKey: Self.menuBarKey) }
    }
    /// Send Safe items to the Trash instead of deleting them outright, so a
    /// delete can be undone until the Trash is emptied. Off by default: Safe
    /// items regenerate, and trashing them frees no space until the Trash goes.
    var movesSafeToTrash: Bool = UserDefaults.standard.bool(forKey: ScanModel.safeToTrashKey) {
        didSet { UserDefaults.standard.set(movesSafeToTrash, forKey: Self.safeToTrashKey) }
    }
    var errorMessage: String?
    /// Set when a delete gave back less than it removed and local snapshots
    /// are why. The notice explains it; this puts the way out next to it
    /// instead of leaving the person to find the row.
    var offersSnapshotCleanup = false
    /// Failures collected during one batch, shown together when it ends.
    @ObservationIgnored private var failures: [String] = []
    /// Whether anything in this batch was trashed rather than deleted. The
    /// Trash frees nothing until it is emptied, which the notice already says.
    @ObservationIgnored private var anythingWentToTheTrash = false
    /// Non-error feedback, such as "moved to the Trash".
    var notice: String?

    /// False for the headless modes and the Shortcuts actions, which run a
    /// model of their own and must not overwrite what the widget shows.
    @ObservationIgnored private let scansAutomatically: Bool

    private static let hiddenKey = "hiddenItemIDs"
    private static let sortKey = "sortOrder"
    private static let historyKey = "keepsHistory"
    private static let menuBarKey = "menuBarContent"
    /// Read by the app scene too, which needs `@AppStorage` to notice the
    /// change: an app scene does not track this model the way a view does.
    static let menuBarIconKey = "showsMenuBarIcon"
    private static let safeToTrashKey = "movesSafeToTrash"
    private static let rescanInterval: Duration = .seconds(24 * 60 * 60)

    /// `scansAutomatically` is off for the headless modes, which drive the
    /// scan themselves. `items` starts the model on a known list instead of
    /// whichever machine the tests happen to run on.
    init(scansAutomatically: Bool = true, items: [StorageItem] = []) {
        self.scansAutomatically = scansAutomatically
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
            // These run only on the unattended scans, never on a Rescan the
            // person is watching: the weekly note, then the optional automatic
            // clean of the safe subset. Both are no-ops unless switched on.
            await WeeklyDigest.check(log: history)
            await GrowthAlert.check(log: history)
            await autoCleanIfDue()
            try? await Task.sleep(for: Self.rescanInterval)
        }
    }

    /// Runs the opt-in weekly clean of the safe subset and says what it freed.
    /// Only Safe, password-free items — the same set the one-tap button uses —
    /// so nothing that needs review or a password is ever touched unattended.
    private func autoCleanIfDue() async {
        guard AutoClean.isDue() else { return }
        let items = safeAutoItems
        let before = DiskSize.freeSpace()
        AutoClean.markRun()
        guard !items.isEmpty else { return }
        await reclaim(items)
        let freed = max(DiskSize.freeSpace() - before, 0)
        await AutoClean.announce(freed: freed, count: items.count)
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

    /// What the person can actually see: listed, and not inside a category
    /// they have folded shut. Every selection rule is written against this,
    /// because a fold and a filter do the same thing to a row.
    var onScreenItems: [StorageItem] {
        listedItems.filter { !collapsedCategories.contains($0.category) }
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
        bytes(.safe)
    }

    /// The listed items' total for one safety level, for the overview bar.
    func bytes(_ safety: Safety) -> Int64 {
        visibleItems.filter { $0.safety == safety }.reduce(0) { $0 + ($1.sizeBytes ?? 0) }
    }

    var selectedItems: [StorageItem] {
        visibleItems.filter { selectedIDs.contains($0.id) }
    }

    var selectedBytes: Int64 {
        selectedItems.reduce(0) { $0 + ($1.sizeBytes ?? 0) }
    }

    /// The items that are safe to free without a question: regenerated
    /// automatically, and deletable without an administrator password. This is
    /// the only set the app ever acts on for the person — the one-tap "free
    /// safe items" button and the optional weekly auto-clean — because it is
    /// the set where a mistake costs nothing but a rebuild.
    var safeAutoItems: [StorageItem] {
        visibleItems.filter { $0.safety == .safe && !$0.action.isManual && !$0.action.needsAdministrator }
    }

    var safeAutoBytes: Int64 {
        safeAutoItems.reduce(0) { $0 + ($1.sizeBytes ?? 0) }
    }

    /// Whether free space is under the warning threshold, so the window can
    /// offer to act rather than leaving the person to hunt for what to delete.
    var isLowOnSpace: Bool {
        LowSpaceAlert.isEnabled && freeBytes < LowSpaceAlert.threshold
    }

    /// This item's size across the recent scans that knew it, oldest to newest,
    /// for the row's sparkline. Fewer than two points is not a trend.
    func series(for item: StorageItem) -> [Int64] {
        ScanHistory.series(forItem: item.id, in: history)
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

    private func selectableItems(in category: StorageCategory) -> [StorageItem] {
        listedItems.filter { $0.category == category && !$0.action.isManual }
    }

    /// Ticks every listed Safe row, revealing the categories that contain
    /// them. A person should never have to hunt through folded sections for a
    /// selection the app just made. A second press undoes that selection.
    ///
    /// It only ever adds to or removes from what is listed: rows the filter is
    /// hiding are neither ticked behind the person's back nor dropped from a
    /// selection they made before they started typing.
    /// How long a project has to sit untouched before its build folders are
    /// offered as a group.
    static let idleProjectDays = 60

    /// Build folders of projects nobody has changed in two months. Dated by
    /// the project's own files, so a codebase edited daily whose
    /// node_modules is old does not qualify.
    var idleProjectItems: [StorageItem] {
        listedItems.filter { $0.category == .projects && ($0.idleDays ?? 0) >= Self.idleProjectDays }
    }

    /// Ticks the idle projects' build folders, or unticks them when they
    /// already all are — the same toggle Select safe is.
    func selectIdleProjects() {
        let ids = Set(idleProjectItems.map(\.id))
        guard !ids.isEmpty else { return }
        if ids.isSubset(of: selectedIDs) {
            selectedIDs.subtract(ids)
        } else {
            selectedIDs.formUnion(ids)
            collapsedCategories.remove(.projects)
        }
        selectionAnchorID = nil
    }

    func selectAllSafe() {
        let listedSafeItems = listedItems.filter { $0.safety == .safe && !$0.action.isManual }
        let listedSafeIDs = Set(listedSafeItems.map(\.id))
        guard !listedSafeIDs.isEmpty else { return }
        if listedSafeIDs.isSubset(of: selectedIDs) {
            selectedIDs.subtract(listedSafeIDs)
        } else {
            selectedIDs.formUnion(listedSafeIDs)
            collapsedCategories.subtract(Set(listedSafeItems.map(\.category)))
        }
        selectionAnchorID = nil
    }

    /// True when another press of "Select safe" would untick rather than tick.
    var everyListedSafeItemIsSelected: Bool {
        let listedSafeIDs = Set(listedItems.filter { $0.safety == .safe && !$0.action.isManual }.map(\.id))
        return !listedSafeIDs.isEmpty && listedSafeIDs.isSubset(of: selectedIDs)
    }

    /// Folds every category, including categories that a scan has not yielded
    /// yet. That keeps the default folded state intact while results stream in.
    func collapseAllCategories() {
        collapsedCategories = Set(StorageCategory.allCases)
    }

    func expandAllCategories() {
        collapsedCategories = []
    }

    var areAllListedCategoriesCollapsed: Bool {
        !categories.isEmpty && categories.allSatisfy { collapsedCategories.contains($0.category) }
    }

    /// Selected rows that are not on screen, whether a filter or a folded
    /// category took them off it. They are still in the batch, so the footer
    /// has to say so: a delete that reaches further than the window is the one
    /// thing neither control may make possible quietly.
    var selectedOffScreenCount: Int {
        let onScreenIDs = Set(onScreenItems.map(\.id))
        return selectedItems.filter { !onScreenIDs.contains($0.id) }.count
    }

    func clearSelection() {
        selectedIDs = []
        selectionAnchorID = nil
    }

    /// Categories, largest first once the scan has finished. While results are
    /// still arriving they keep their fixed order, so headers do not jump
    /// around under the pointer as totals change.
    var categories: [(category: StorageCategory, items: [StorageItem], total: Int64)] {
        let visible = listedItems
        let groups = StorageCategory.allCases.compactMap { category -> (category: StorageCategory, items: [StorageItem], total: Int64)? in
            let members = visible.filter { $0.category == category }
            guard !members.isEmpty else { return nil }
            return (category, sorted(members), members.reduce(0) { $0 + ($1.sizeBytes ?? 0) })
        }
        guard !isScanning else { return groups }
        // Ties keep the fixed order, so equal totals do not swap on redraw.
        return groups.enumerated()
            .sorted { $0.element.total != $1.element.total ? $0.element.total > $1.element.total : $0.offset < $1.offset }
            .map(\.element)
    }

    /// Categories that have grown well past their recent size, and by how much.
    /// The same test the growth notification uses, so the list and the
    /// notification never disagree about what is unusual.
    var unusualGrowth: [StorageCategory: Int64] {
        Dictionary(uniqueKeysWithValues: ScanHistory.unusualCategoryGrowth(in: history).map {
            ($0.category, $0.growthBytes)
        })
    }

    /// How much System Data changed since a scan about a week old, or nil when
    /// the history does not reach back that far.
    var weeklyChange: Int64? {
        ScanHistory.totalChange(overPastDays: 7, in: history)?.delta
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
        // Folded on the first scan only. Folding on every scan would close
        // whatever the person had opened each time the daily background scan
        // ran with the window up.
        if !hasScanned { collapseAllCategories() }
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
        capacityBytes = DiskSize.capacity()
            history = ScanHistory.load()
        }
        await LowSpaceAlert.check(freeBytes: freeBytes, reclaimable: safeBytes)
        publishToWidget()
    }

    /// Hands the widget the latest figures. It runs sandboxed in its own
    /// process and cannot scan, so this file is all it knows. Skipped by the
    /// headless modes, which do not own the user's widget.
    func publishToWidget() {
        guard scansAutomatically else { return }
        let snapshot = WidgetSnapshot(
            systemDataBytes: measuredBytes, freeBytes: freeBytes, safeBytes: safeBytes,
            capacityBytes: capacityBytes, scannedAt: lastScan ?? .now
        )
        try? snapshot.save()
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshot.widgetKind)
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

    /// Frees the safe subset in one press, for the low-space banner. No
    /// confirmation because there is nothing to weigh: every item is
    /// regenerated on demand and none needs a password.
    func reclaimSafeNow() async {
        await reclaim(safeAutoItems)
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
        failures = []
        // What the disk says before any of it runs, to compare with what the
        // batch removed. They are not the same number as often as one would
        // hope, and the difference is the thing worth saying out loud.
        let freeBeforeBatch = DiskSize.freeSpace()
        let askedToFree = runnable.reduce(0) { $0 + ($1.sizeBytes ?? 0) }
        anythingWentToTheTrash = false
        offersSnapshotCleanup = false
        // Every failure in the batch, one per line, once it is over.
        defer { if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") } }

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
            guard await performPrivilegedBatch(privileged) else {
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

        await explainAnyShortfall(freeBefore: freeBeforeBatch, askedToFree: askedToFree)
    }

    /// Says so when the disk did not give back what was deleted.
    ///
    /// Deleting a file does not always free its space: while a local Time
    /// Machine snapshot still refers to it, it moves from the file to the
    /// snapshot, and macOS books it as purgeable — space it will hand back
    /// when something needs it, not space that is free now. Caches the system
    /// rebuilds immediately take their share too. Without this, the app
    /// reported having freed gigabytes while the disk showed less room than
    /// before, which is the one thing a tool like this must never do.
    private func explainAnyShortfall(freeBefore: Int64, askedToFree: Int64) async {
        guard askedToFree > 0, errorMessage == nil, !anythingWentToTheTrash else { return }
        // Half of it, and at least half a gigabyte short: normal background
        // writing is not worth a notice.
        let gained = DiskSize.freeSpace() - freeBefore
        guard gained < askedToFree / 2, askedToFree - gained > 512 * ProbeSupport.megabyte else { return }

        let snapshotsHoldIt = await hasLocalSnapshots()
        notice = Self.shortfallNotice(
            askedToFree: askedToFree, gained: gained, hasLocalSnapshots: snapshotsHoldIt
        )
        offersSnapshotCleanup = snapshotsHoldIt && notice != nil && snapshotItem != nil
    }

    /// The local snapshots row, when the last scan found any.
    var snapshotItem: StorageItem? { items.first { $0.id == "snapshots" } }

    /// The wording, kept apart from the disk and the clock so it can be read
    /// back in a test.
    nonisolated static func shortfallNotice(askedToFree: Int64, gained: Int64, hasLocalSnapshots: Bool) -> String? {
        guard askedToFree > 0,
              gained < askedToFree / 2,
              askedToFree - gained > 512 * ProbeSupport.megabyte else { return nil }
        let deleted = askedToFree.byteString
        let free = max(gained, 0).byteString
        return hasLocalSnapshots
            ? L("Deleted %@, but the disk has only %@ more free: local snapshots still hold the rest. Delete the Time Machine local snapshots to get it back now.", deleted, free)
            : L("Deleted %@, but the disk has only %@ more free. macOS is holding the rest as purgeable space and gives it back when something needs the room.", deleted, free)
    }

    private func hasLocalSnapshots() async -> Bool {
        guard let result = try? await Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: Shell.probeTimeout) else { return false }
        return result.output.contains("com.apple.TimeMachine")
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
        // items regenerate anyway and are deleted outright — unless the person
        // has asked for the extra safety net, in which case they go to the
        // Trash too and free nothing until it is emptied.
        let toTrash = affected.allSatisfy { $0.safety == .review }
            || (movesSafeToTrash && affected.allSatisfy { $0.safety == .safe })
        let before = DiskSize.freeSpace()
        do {
            let movedToTrash = try await Reclaimer.perform(action, preferTrash: toTrash)
            recordReclaimed(affected, freeBefore: before, movedToTrash: movedToTrash)
        } catch {
            if let command = error as? CommandError, command.wasCancelled { return false }
            let names = affected.map(\.name).joined(separator: ", ")
            // Collected rather than assigned: a batch used to show only its
            // last failure, so an erase that failed early looked like it worked.
            if let command = error as? CommandError,
               command.command.contains("simctl erase"), command.result.output.contains("Booted") {
                failures.append(L("%@: the simulator is still running. Quit Simulator and Xcode, then try again.", names))
            } else {
                failures.append("\(names): \(error.localizedDescription)")
            }
        }
        return true
    }

    /// Everything a successful delete changes: the history, the list, the
    /// running total and the free-space figures.
    private func recordReclaimed(_ affected: [StorageItem], freeBefore before: Int64, movedToTrash: Bool) {
        guard !affected.isEmpty else { return }
        let ids = Set(affected.map(\.id))
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
        publishToWidget()
        if movedToTrash {
            anythingWentToTheTrash = true
            notice = L("Moved to the Trash. Empty the Trash to free the space.")
        }
    }

    /// Runs every script that needs root under one password prompt, and
    /// works out afterwards which of them failed.
    ///
    /// They used to be joined with ` ; `, and a shell reports only the last
    /// command's status. A failure anywhere but at the end went unreported —
    /// its item left the list and entered the history as deleted — and a
    /// failure at the end was blamed on every item in the batch, which is how
    /// a cache folder macOS protects came to be reported against the log
    /// store, the crash reports and the ASL logs as well.
    ///
    /// Returns false when the person dismissed the password dialog.
    private func performPrivilegedBatch(_ privileged: [(item: StorageItem, script: String)]) async -> Bool {
        let affected = privileged.map(\.item)
        let ids = Set(affected.map(\.id))
        busyItemIDs.formUnion(ids)
        defer { busyItemIDs.subtract(ids) }

        let before = DiskSize.freeSpace()
        let script = Self.combinedPrivilegedScript(privileged.map(\.script))
        do {
            try await Reclaimer.perform(.privilegedScript(script))
            recordReclaimed(affected, freeBefore: before, movedToTrash: false)
        } catch {
            if let command = error as? CommandError, command.wasCancelled { return false }
            let output = (error as? CommandError)?.result.output ?? ""
            // No marker means the batch never reached the end, so nothing in
            // it can be counted as done.
            let failedIndices = Self.failedIndices(in: output) ?? Set(affected.indices)
            let succeeded = affected.enumerated().filter { !failedIndices.contains($0.offset) }.map(\.element)
            let failed = affected.enumerated().filter { failedIndices.contains($0.offset) }.map(\.element)
            recordReclaimed(succeeded, freeBefore: before, movedToTrash: false)
            let names = failed.map(\.name).joined(separator: ", ")
            // A step that failed without a word on stderr leaves nothing but
            // the marker; its command is then the most useful thing to show.
            let reason = Self.withoutFailureMarker(error.localizedDescription)
            let shown = reason.isEmpty
                ? privileged.enumerated().filter { failedIndices.contains($0.offset) }.map(\.element.script).joined(separator: "; ")
                : reason
            failures.append("\(names): \(shown)")
        }
        return true
    }

    nonisolated private static let failureMarker = "SYSDATA_FAILED:"

    /// Each script in its own subshell, its failure noted by position, and one
    /// line at the end naming the positions that failed.
    nonisolated static func combinedPrivilegedScript(_ scripts: [String]) -> String {
        let steps = scripts.enumerated().map { index, script in
            "( \(script) ) || failed=\"$failed \(index)\""
        }
        return (["failed=''"] + steps + [
            "[ -z \"$failed\" ] || { echo \"\(failureMarker)$failed\" >&2; exit 1; }",
        ]).joined(separator: " ; ")
    }

    /// The positions the combined script reported as failed, or nil when it
    /// never got as far as reporting.
    nonisolated static func failedIndices(in output: String) -> Set<Int>? {
        guard let range = output.range(of: failureMarker) else { return nil }
        // osascript separates lines with \r and appends " (1)", the exit
        // status; neither is a position.
        let line = output[range.upperBound...].prefix { !$0.isNewline && $0 != "\"" }
        return Set(line.split(separator: " ").compactMap { Int($0) })
    }

    nonisolated static func withoutFailureMarker(_ text: String) -> String {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .filter { !$0.contains(failureMarker) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

}
