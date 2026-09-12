import AppKit
import SwiftUI

struct MenuView: View {
    /// Where this panel is drawn. The menu bar popover has to be told its
    /// size; the window is resizable and keeps whatever size it is given.
    enum Presentation {
        case menuBar
        case window
    }

    var presentation: Presentation = .menuBar

    @Environment(ScanModel.self) private var model
    @State private var updates = UpdateCheck()
    @FocusState private var filterIsFocused: Bool
    @State private var pendingDeletion: StorageItem?
    @State private var confirmsBatch = false
    @State private var showsHistory = false
    @State private var warnsAboutLowSpace = LowSpaceAlert.isEnabled
    @State private var lowSpaceThreshold = LowSpaceAlert.threshold
    @State private var showsWeeklySummary = WeeklyDigest.isEnabled
    @State private var warnsAboutUnusualGrowth = GrowthAlert.isEnabled
    @State private var autoCleansSafeItems = AutoClean.isEnabled
    @State private var notificationsRefused = false
    @State private var showsPlan = false
    @State private var copiedPlan = false

    /// What the pending delete will actually do, whether it is one row or a
    /// whole selection.
    private var pendingItems: [StorageItem] {
        pendingDeletion.map { [$0] } ?? model.selectedItems
    }

    private var plannedOperations: [String] {
        pendingItems.flatMap(\.action.plan)
    }

    /// Puts the whole plan on the pasteboard, one operation per line, and says
    /// so for a moment: a copy that looks like nothing happened gets pressed
    /// twice.
    private func copyPlan() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(plannedOperations.joined(separator: "\n"), forType: .string)
        copiedPlan = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copiedPlan = false
        }
    }

    private var needsAdministrator: Bool {
        pendingItems.contains { $0.action.needsAdministrator }
    }

    private static let fullDiskAccessPane = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )!

    var body: some View {
        VStack(spacing: 0) {
            header
            // The filter narrows the list; there is no list to narrow while
            // the history is showing.
            if !showsHistory {
                filterField
            }
            Divider()
            if !model.hasFullDiskAccess {
                accessBanner
                Divider()
            }
            if let version = updates.newVersion {
                updateBanner(version)
                Divider()
            }
            if model.isLowOnSpace, model.safeAutoBytes > 0, !model.isScanning {
                lowSpaceBanner
                Divider()
            }
            if notificationsRefused {
                feedbackRow(
                    L("macOS is not allowing notifications from this app. Turn them on in System Settings > Notifications."),
                    symbol: "bell.slash", tint: .orange
                ) { notificationsRefused = false }
                Divider()
            }
            if let failure = updates.installError {
                feedbackRow(failure, symbol: "exclamationmark.triangle.fill", tint: .orange) {
                    updates.installError = nil
                }
                Divider()
            }
            if showsHistory {
                HistoryPanel(log: model.history) { model.keepsHistory = false; showsHistory = false }
            } else {
                content
            }
            Divider()
            if pendingDeletion != nil || confirmsBatch {
                confirmationBar
                Divider()
            }
            footer
        }
        .modifier(PanelSize(presentation: presentation))
        .task {
            if !model.hasScanned, !model.isScanning { await model.scan() }
            await updates.checkIfDue()
        }
    }

    /// Shown where the Full Disk Access banner goes: the one place in this
    /// window that is already understood as "something needs your attention".
    private func updateBanner(_ version: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.tint)
            Text(L("Version %@ is available.", version))
                .font(.callout)
            Spacer()
            if updates.isInstalling {
                ProgressView().controlSize(.small)
            } else if updates.newVersionImage != nil {
                Button(L("Update")) { Task { await updates.install() } }
                    .controlSize(.small)
            } else {
                // No image on the release: nothing to install, so the release
                // page is the only honest offer.
                Button(L("Download")) { NSWorkspace.shared.open(updates.downloadURL) }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// Shown when free space is under the warning threshold. The one place the
    /// app offers to act without a confirmation, because the set it frees is
    /// the safe subset — caches that regenerate, nothing that needs a password
    /// or a second thought.
    private var lowSpaceBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Low on disk space"))
                    .font(.callout.weight(.semibold))
                Text(L("%@ free · %@ of safe items can go now",
                       model.freeBytes.byteString, model.safeAutoBytes.byteString))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            if model.busyItemIDs.isEmpty {
                Button(L("Free %@", model.safeAutoBytes.byteString)) {
                    Task { await model.reclaimSafeNow() }
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.08))
    }

    // MARK: Confirmation

    /// Inline rather than a sheet: the menu bar panel is not a regular window,
    /// so sheets and confirmation dialogs never appear on it.
    private var confirmationBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let item = pendingDeletion {
                Text(L("Delete %@?", item.name))
                    .font(.subheadline.weight(.semibold))
                Text(confirmationMessage(for: item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L("Delete %lld items?", model.selectedItems.count))
                    .font(.subheadline.weight(.semibold))
                Text(batchMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !plannedOperations.isEmpty {
                DisclosureGroup(isExpanded: $showsPlan) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(plannedOperations, id: \.self) { line in
                                Text(line)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .frame(maxHeight: 120)
                } label: {
                    HStack(spacing: 6) {
                        Text(needsAdministrator
                             ? L("Show the commands that run as administrator")
                             : L("Show exactly what runs"))
                            .font(.caption)
                        if showsPlan {
                            Spacer()
                            // The list scrolls inside 120pt and paths are long,
                            // so reading the whole plan often means taking it
                            // somewhere else. Selecting 58 lines by hand inside
                            // a scroll view is not that.
                            Button(action: copyPlan) {
                                Label(copiedPlan ? L("Copied") : L("Copy"),
                                      systemImage: copiedPlan ? "checkmark" : "doc.on.doc")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(copiedPlan ? Color.green : Color.accentColor)
                            .accessibilityLabel(L("Copy the plan"))
                        }
                    }
                }
                .font(.caption)
            }
            HStack {
                Spacer()
                Button(L("Cancel")) {
                    pendingDeletion = nil
                    confirmsBatch = false
                    showsPlan = false
                    copiedPlan = false
                }
                .keyboardShortcut(.cancelAction)
                Button(role: .destructive) {
                    if let item = pendingDeletion {
                        Task { await model.reclaim(item) }
                    } else {
                        Task { await model.reclaimSelected() }
                    }
                    pendingDeletion = nil
                    confirmsBatch = false
                    showsPlan = false
                    copiedPlan = false
                } label: {
                    Text(pendingDeletion != nil ? L("Delete") : L("Delete %lld items", model.selectedItems.count))
                }
                .keyboardShortcut(.defaultAction)
                .tint(.red)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.red.opacity(0.06))
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(L("System Data"))
                        .font(titleFont)
                    if !model.visibleItems.isEmpty {
                        Text(model.measuredBytes.byteString)
                            .font(titleFont)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    // The purgeable figure is the one number here nobody can
                    // act on, and the one people meet in Finder wondering why
                    // free space they can see will not open a file. Measured
                    // on this Mac: writing 6.44 GB cost 6.44 GB of real free
                    // space and took nothing from the pool, which then
                    // refilled itself. See docs/purgeable-measurement.md.
                    .help(model.purgeableBytes > 0
                          ? L("Purgeable is what macOS estimates it could give back if it had to: caches and local snapshots. It is an estimate, not space you can count on — it moves on its own, and writing a file does not spend it. The items below are the ones you can actually free.")
                          : L("Free space on the startup disk."))
            }
            Spacer()
            if model.isScanning {
                // Determinate while the probes run: the first scan on a full
                // disk is slow enough that a spinner alone cannot be told
                // apart from a hang.
                if model.probesTotal > 0, model.probesFinished < model.probesTotal {
                    ProgressView(value: Double(model.probesFinished), total: Double(model.probesTotal))
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .accessibilityLabel(L("Scanning"))
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(L("Scanning"))
                }
            } else {
                if !model.visibleItems.isEmpty {
                    // Icon-only: spelling out "Size"/"Idle longest" here cost
                    // enough width to push the title onto two lines.
                    Menu {
                        Picker(L("Sort by"), selection: Binding(
                            get: { model.sortOrder },
                            set: { model.sortOrder = $0 }
                        )) {
                            ForEach(SortOrder.allCases) { order in
                                Text(order.title).tag(order)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } label: {
                        Label(L("Sort by"), systemImage: "arrow.up.arrow.down")
                            .labelStyle(.iconOnly)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .controlSize(.small)
                    .fixedSize()
                    .help(L("Order rows by size, or by how long they have sat untouched"))

                    Button {
                        withAnimation {
                            if model.areAllListedCategoriesCollapsed {
                                model.expandAllCategories()
                            } else {
                                model.collapseAllCategories()
                            }
                        }
                    } label: {
                        Label(
                            model.areAllListedCategoriesCollapsed ? L("Expand all") : L("Collapse all"),
                            systemImage: model.areAllListedCategoriesCollapsed
                                ? "rectangle.expand.vertical"
                                : "rectangle.compress.vertical"
                        )
                        .labelStyle(.iconOnly)
                    }
                    // Borderless, like the sort control beside it: two icons in
                    // a row should not look like two different kinds of thing.
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .accessibilityLabel(
                        model.areAllListedCategoriesCollapsed ? L("Expand all") : L("Collapse all")
                    )
                    .help(model.areAllListedCategoriesCollapsed ? L("Expand all") : L("Collapse all"))

                    Button(model.everyListedSafeItemIsSelected
                           ? L("Deselect safe")
                           : L("Select safe")) {
                        model.selectAllSafe()
                    }
                    .controlSize(.small)
                    .help(L("Select every item that is regenerated automatically"))
                }
                Button {
                    Task { await model.scan() }
                } label: {
                    Label(L("Rescan"), systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                settingsMenu
            }
        }
        .padding(.horizontal, presentation == .window ? 18 : 14)
        .padding(.vertical, presentation == .window ? 14 : 10)
        // In the window the title bar is transparent and empty, so the header
        // is the title: it needs the traffic lights' row above it.
        .padding(.top, presentation == .window ? 20 : 0)
    }

    /// The window has room the popover does not, and a header that is also
    /// the title bar should read as one.
    private var titleFont: Font {
        presentation == .window ? .title3.weight(.semibold) : .headline
    }

    /// Shown once the list is long enough that finding a row by eye is work.
    @ViewBuilder
    private var filterField: some View {
        @Bindable var model = model
        if model.visibleItems.count >= 12 || !model.filterText.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(L("Filter"), text: $model.filterText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($filterIsFocused)
                    .onSubmit { filterIsFocused = false }
                if !model.filterText.isEmpty {
                    Button {
                        model.filterText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("Clear"))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, presentation == .window ? 18 : 14)
            .padding(.bottom, 8)
        }
    }

    private var subtitle: String {
        if model.isScanning, !model.phase.isEmpty {
            return model.phase
        }
        if model.visibleItems.isEmpty {
            return L("%@ free on disk", model.freeBytes.byteString)
        }
        return L("%@ safe to free now · %@ free on disk · %@ purgeable",
                 model.safeBytes.byteString, model.freeBytes.byteString, model.purgeableBytes.byteString)
    }

    // MARK: Full Disk Access

    private var accessBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Grant Full Disk Access once"))
                    .font(.caption.weight(.semibold))
                Text(L("One grant covers everything. Until then this scan leaves the protected places alone — app containers, Desktop, Documents, Music, Photos — rather than asking about them one app at a time, so what you see below is incomplete. Add System Data Unpacked in the settings pane, then reopen the app."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(L("Open Settings")) {
                NSWorkspace.shared.open(Self.fullDiskAccessPane)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.08))
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if model.listedItems.isEmpty, !model.filterText.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "magnifyingglass")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(L("No item matches"))
                    .foregroundStyle(.secondary)
                Button(L("Clear")) { model.filterText = "" }
                    .controlSize(.small)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if model.visibleItems.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                if model.isScanning {
                    ProgressView()
                    Text(L("Measuring…"))
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "checkmark.circle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(L("Nothing to reclaim"))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 6) {
                pulse
                    .padding(.horizontal, 16)
                    .padding(.top, 2)
                list
            }
        }
    }

    /// One line for "now": how big System Data is, how much room is left and,
    /// once the history reaches back a week, which way it went. A rise large
    /// enough to earn the weekly summary gets the amber arrow.
    private var pulse: some View {
        HStack(spacing: 4) {
            if let change = model.weeklyChange, change >= WeeklyDigest.floor {
                Image(systemName: "arrow.up.right")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
            }
            Text(pulseText)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .lineLimit(1)
    }

    private var pulseText: String {
        let size = model.measuredBytes.byteString
        let free = model.freeBytes.byteString
        guard let change = model.weeklyChange else { return L("%@ System Data · %@ free", size, free) }
        let signed = change < 0 ? "−" + abs(change).byteString : "+" + change.byteString
        return L("%@ System Data · %@ free · %@ this week", size, free, signed)
    }

    /// A scroll view of stacked rows, not a `List`.
    ///
    /// On macOS a `List` is an NSTableView whose rows size themselves, and a
    /// row here can change height inside the table's own constraint pass — its
    /// detail wraps to the panel's width, and during a scan rows keep arriving
    /// while the person scrolls. On macOS 26.5 that sent the window into
    /// constraint pass after constraint pass until AppKit threw
    /// NSGenericException and the app quit (the report and stack are in #18).
    /// A stack has no table to fall into that loop, and `LazyVStack` still
    /// builds rows only as they scroll into view.
    private var list: some View {
        // Read once per redraw rather than once per header: both walk the
        // history or every item.
        let growth = model.unusualGrowth
        let groups = model.categories
        let scale = groups.map(\.total).max() ?? 0
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groups, id: \.category) { group in
                    categoryHeader(group.category, total: group.total, items: group.items)
                        .padding(.top, 6)
                    atlasRow(group.category, items: group.items, scale: scale, growth: growth[group.category])
                        .padding(.top, 3)
                        .padding(.bottom, 6)
                    // The separators a List drew on its own.
                    Divider()
                    if !model.collapsedCategories.contains(group.category) {
                        ForEach(group.items) { item in
                            itemRow(item)
                                .padding(.vertical, 4)
                            Divider()
                        }
                    }
                }
            }
            // The insets the inset List style used to add.
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    /// The category's bar, and an amber mark when it has grown well past its
    /// recent size.
    private func atlasRow(_ category: StorageCategory, items: [StorageItem], scale: Int64, growth: Int64?) -> some View {
        func bytes(_ safety: Safety) -> Int64 {
            items.filter { $0.safety == safety }.reduce(0) { $0 + ($1.sizeBytes ?? 0) }
        }
        return HStack(spacing: 8) {
            AtlasBar(safe: bytes(.safe), review: bytes(.review), manual: bytes(.manual), scale: scale)
            if let growth {
                Text(verbatim: "+" + growth.byteString)
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.orange)
                    .help(L("%@ grew %@ beyond its recent size.", category.title, growth.byteString))
            }
        }
        // Starts under the category name, past the chevron and the checkbox.
        .padding(.leading, 38)
    }

    private func itemRow(_ item: StorageItem) -> some View {
        ItemRow(
            item: item,
            change: model.change(since: item),
            trend: model.series(for: item),
            isBusy: model.busyItemIDs.contains(item.id),
            isSelected: model.selectedIDs.contains(item.id),
            onToggle: { isSelected in
                model.setSelection(
                    item,
                    selected: isSelected,
                    extendingRange: NSEvent.modifierFlags.contains(.shift),
                    selectableItems: rangeSelectableItems
                )
            },
            onDelete: { pendingDeletion = item },
            onHide: { model.hide(item) }
        )
    }

    private func categoryHeader(_ category: StorageCategory, total: Int64, items: [StorageItem]) -> some View {
        HStack {
            Button {
                withAnimation {
                    // Folding keeps the selection. A fold and a filter do the
                    // same thing to a row, and the footer counts what either
                    // one has taken off screen rather than either of them
                    // quietly editing the batch.
                    if model.collapsedCategories.contains(category) {
                        model.collapsedCategories.remove(category)
                    } else {
                        model.collapsedCategories.insert(category)
                    }
                }
            } label: {
                Image(systemName: model.collapsedCategories.contains(category)
                      ? "chevron.right"
                      : "chevron.down")
                    .frame(width: 10)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(
                model.collapsedCategories.contains(category)
                    ? L("Expand %@", category.title)
                    : L("Collapse %@", category.title)
            )

            Toggle(isOn: Binding(
                get: { model.isCategorySelected(category) },
                set: { model.setSelection(category, selected: $0) }
            )) {
                Text(category.title)
                    .fontWeight(.semibold)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .disabled(!model.categoryHasSelectableItems(category))
            Spacer()
            // A category whose sizes are all unmeasurable — APFS never reports
            // a snapshot's size — summed to zero and displayed "0 bytes", which
            // reads as "nothing here" for the one group where the app does not
            // know. The rows already say "—"; the header now agrees with them.
            // A group where only some sizes are unknown keeps its total, which
            // is still the truth about what was measured.
            let isUnmeasurable = items.allSatisfy { $0.sizeBytes == nil }
            Text(isUnmeasurable ? "—" : total.byteString)
                .monospacedDigit()
                .foregroundStyle(isUnmeasurable ? .secondary : .primary)
        }
    }

    private var rangeSelectableItems: [StorageItem] {
        model.categories
            .filter { !model.collapsedCategories.contains($0.category) }
            .flatMap { $0.items }
            .filter { !$0.action.isManual }
    }

    /// Turns a notification-backed preference on only if macOS grants
    /// permission, so a switch never sits on above a notification that can
    /// never arrive. The switch reflects what was allowed, not what was asked.
    private func toggleWithNotification(_ wanted: Bool, enable: @escaping (Bool) -> Void) {
        guard wanted else { enable(false); return }
        Task {
            let granted = await LowSpaceAlert.requestPermission()
            enable(granted)
            if !granted { notificationsRefused = true }
        }
    }

    /// The preferences and history view.
    ///
    /// They used to be a row of switches along the bottom. A fourth did not
    /// fit: at this panel width the labels wrapped mid-word and pushed the
    /// title onto two lines. A menu holds them without competing with the
    /// list, which is what the panel is actually for.
    private var settingsMenu: some View {
        Menu {
            if model.keepsHistory {
                Button(showsHistory ? L("Back to the list") : L("History")) {
                    showsHistory.toggle()
                }
                .help(L("What grew, and what came back"))
            }
            if presentation == .menuBar {
                Button(L("Open in a window")) { MainWindow.shared.show() }
                    .help(L("The same panel, as a window you can resize and leave open"))
            }
            Divider()
            Toggle(L("Remember what changed"), isOn: Binding(
                get: { model.keepsHistory },
                set: { model.keepsHistory = $0; if !$0 { showsHistory = false } }
            ))
            .help(L("Keep a local record of each scan and deletion, so the list can show what changed"))
            Toggle(L("Move safe items to the Trash"), isOn: Binding(
                get: { model.movesSafeToTrash },
                set: { model.movesSafeToTrash = $0 }
            ))
            .help(L("Safe items are deleted outright because they regenerate. Turn this on to send them to the Trash instead, so a delete can be undone — until you empty it, it frees no space."))
            Toggle(L("Warn when free space runs low"), isOn: Binding(
                get: { warnsAboutLowSpace },
                set: { wanted in
                    guard wanted else { LowSpaceAlert.isEnabled = false; warnsAboutLowSpace = false; return }
                    Task {
                        // The switch reflects what macOS allowed, not what was
                        // asked for: left on after a refusal it would promise
                        // a notification that can never arrive.
                        let granted = await LowSpaceAlert.requestPermission()
                        LowSpaceAlert.isEnabled = granted
                        warnsAboutLowSpace = granted
                        if !granted { notificationsRefused = true }
                    }
                }
            ))
            if warnsAboutLowSpace {
                Picker(L("Warn below"), selection: Binding(
                    get: { lowSpaceThreshold },
                    set: { lowSpaceThreshold = $0; LowSpaceAlert.threshold = $0 }
                )) {
                    ForEach(LowSpaceAlert.choices, id: \.self) { bytes in
                        Text(bytes.byteString).tag(bytes)
                    }
                }
            }
            Toggle(L("Weekly summary"), isOn: Binding(
                get: { showsWeeklySummary },
                set: { wanted in
                    toggleWithNotification(wanted) { granted in
                        WeeklyDigest.isEnabled = granted
                        showsWeeklySummary = granted
                    }
                }
            ))
            .help(L("Once a week, if System Data has grown, a notification says by how much and what grew most. Nothing leaves your Mac."))
            Toggle(L("Notify about unusual growth"), isOn: Binding(
                get: { warnsAboutUnusualGrowth },
                set: { wanted in
                    toggleWithNotification(wanted) { granted in
                        GrowthAlert.isEnabled = granted
                        warnsAboutUnusualGrowth = granted
                    }
                }
            ))
            .help(L("Once a day, alert you when a storage category has grown far beyond its recent size. Nothing leaves your Mac."))
            Toggle(L("Automatically free safe items"), isOn: Binding(
                get: { autoCleansSafeItems },
                set: { wanted in
                    toggleWithNotification(wanted) { granted in
                        AutoClean.isEnabled = granted
                        autoCleansSafeItems = granted
                    }
                }
            ))
            .help(L("Once a week, delete the items marked Safe — the caches that regenerate — and notify you what was freed. Never anything that needs review or a password."))
            Toggle(L("Shut down simulators at power off"), isOn: Binding(
                get: { model.shutsDownSimulatorsAtPowerOff },
                set: { model.shutsDownSimulatorsAtPowerOff = $0 }
            ))
            .help(L("Booted simulators ignore the quit request and hold the shutdown for 33 seconds. This shuts them down first."))
            Toggle(L("Check for updates"), isOn: Binding(
                get: { updates.isEnabled },
                set: { wanted in
                    updates.isEnabled = wanted
                    if wanted { Task { await updates.check() } }
                }
            ))
            .help(L("Asks GitHub once a day whether a newer version exists. It is the only request this app makes; leave it off and nothing leaves your Mac."))
            Toggle(L("Launch at login"), isOn: Binding(
                get: { model.launchesAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            Divider()
            Toggle(L("Show in menu bar"), isOn: Binding(
                get: { model.showsMenuBarIcon },
                set: { wanted in
                    // Taking the icon away while it is the only way into the
                    // app would leave it with nowhere to appear, so the
                    // window opens before the icon goes.
                    if !wanted { MainWindow.shared.openWindowLeavingTheMenuBar() }
                    model.showsMenuBarIcon = wanted
                    MainWindow.shared.menuBarPreferenceChanged()
                }
            ))
            .help(L("With this off the app lives in its window, and opens from Applications or the Dock."))
            if model.showsMenuBarIcon {
                Picker(L("Menu bar shows"), selection: Binding(
                    get: { model.menuBarContent },
                    set: { model.menuBarContent = $0 }
                )) {
                    ForEach(MenuBarContent.allCases) { content in
                        Text(content.title).tag(content)
                    }
                }
            }
        } label: {
            Label(L("Settings"), systemImage: "gearshape")
                .labelStyle(.iconOnly)
        }
        // Bordered, like Rescan beside it. As a borderless ellipsis it was the
        // quietest thing in the header, and everything the app can be told to
        // do is behind it.
        .menuIndicator(.hidden)
        .controlSize(.small)
        .fixedSize()
        .help(L("History and settings"))
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 6) {
            if let message = model.errorMessage {
                feedbackRow(message, symbol: "exclamationmark.triangle.fill", tint: .yellow) {
                    model.errorMessage = nil
                }
            } else if let message = model.notice {
                feedbackRow(message, symbol: "checkmark.circle.fill", tint: .green) {
                    model.notice = nil
                }
            }
            HStack {
                if model.selectedItems.isEmpty {
                    Text(L("Reclaimed this session: %@", model.reclaimedBytes.byteString))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Button(role: .destructive) {
                        confirmsBatch = true
                    } label: {
                        Text(L("Delete %lld selected · %@", model.selectedItems.count, model.selectedBytes.byteString))
                            .monospacedDigit()
                    }
                    .controlSize(.small)
                    .disabled(!model.busyItemIDs.isEmpty)
                    if model.selectedOffScreenCount > 0 {
                        // The batch reaches further than the window does. Say
                        // so, rather than deleting rows nobody can see.
                        Text(L("%lld not on screen", model.selectedOffScreenCount))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    // "Deselect", not "Clear": in a cleaner the word "Clear"
                    // reads as the app's own verb — free space now — so people
                    // pressed it expecting a delete and reported that nothing
                    // happened. This only ever unticks the selection.
                    Button(L("Deselect")) {
                        model.clearSelection()
                    }
                    .controlSize(.small)
                    .help(L("Untick the selected items. It deletes nothing."))
                }
                if model.hiddenCount > 0 {
                    Button(L("%lld hidden", model.hiddenCount)) {
                        model.unhideAll()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help(L("Show all"))
                }
                Spacer()
                // The window has an app menu, and a Quit button under a list
                // of delete buttons is one more thing to press by accident.
                if presentation == .menuBar {
                    Button(L("Quit")) {
                        NSApplication.shared.terminate(nil)
                    }
                    .controlSize(.small)
                    .keyboardShortcut("q")
                }
            }
            HStack {
                authorBadge
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // The list above is greedy; the footer must keep its full height so
        // a long error never overlaps the status line.
        .layoutPriority(1)
    }

    private func feedbackRow(_ message: String, symbol: String, tint: Color, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            ScrollView {
                Text(message)
                    .font(.caption)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 96)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(L("Dismiss"))
        }
        .padding(.bottom, 4)
    }

    private var authorBadge: some View {
        Link(destination: URL(string: "https://x.com/yigitech")!) {
            HStack(spacing: 4) {
                Text("𝕏")
                    .font(.caption.weight(.bold))
                Text("yigitech")
                    .font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(L("Open x.com/yigitech"))
    }


    // MARK: Confirmation copy

    private func confirmationMessage(for item: StorageItem) -> String {
        let size = item.sizeBytes.map { L("Frees about %@. ", $0.byteString) } ?? ""
        switch item.safety {
        case .safe:
            return size + L("This is regenerated automatically when needed.")
        case .review:
            return size + item.detail + " " + L("It goes to the Trash first.")
        case .manual:
            return item.detail
        }
    }

    private var batchMessage: String {
        let selected = model.selectedItems
        let review = selected.filter { $0.safety == .review }
        // Everything that will ask, not only the items whose action is a
        // privileged script: a plain delete of a root-owned path asks too,
        // because the reclaimer falls back to `rm -rf` as root rather than
        // failing.
        let privileged = selected.filter(\.action.needsAdministrator)
        // The scripts are folded into one prompt. A root-owned path is not.
        let asksMoreThanOnce = selected.contains { $0.action.asksForThePasswordSeparately }
        var lines = [L("Frees about %@. ", model.selectedBytes.byteString)]
        if !review.isEmpty {
            let names = review.prefix(4).map(\.name).joined(separator: ", ") + (review.count > 4 ? ", …" : "")
            lines.append(L("%lld marked Review go to the Trash: %@", review.count, names))
        }
        if privileged.count > 1 {
            lines.append(asksMoreThanOnce
                ? L("%lld items need root; the password may be asked more than once.", privileged.count)
                : L("%lld items need root; the password is asked once.", privileged.count))
        } else if privileged.count == 1 {
            lines.append(L("1 item needs root."))
        }
        return lines.joined(separator: "\n")
    }
}

/// Fixed for the popover, floored for the window.
private struct PanelSize: ViewModifier {
    let presentation: MenuView.Presentation

    func body(content: Content) -> some View {
        switch presentation {
        case .menuBar: content.frame(width: 460, height: 640)
        case .window: content.frame(minWidth: 460, minHeight: 520)
        }
    }
}
