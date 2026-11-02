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
    @State private var isAuthenticating = false
    /// What the last delete gave back, kept on screen for a few seconds.
    @State private var freedFlash: Int64?
    @State private var hoveredCategory: StorageCategory?
    @State private var hoveredProject: String?
    @State private var showsHistory = false
    @State private var warnsAboutLowSpace = LowSpaceAlert.isEnabled
    @State private var lowSpaceThreshold = LowSpaceAlert.threshold
    @State private var showsWeeklySummary = WeeklyDigest.isEnabled
    @State private var warnsAboutUnusualGrowth = GrowthAlert.isEnabled
    @State private var autoCleansSafeItems = AutoClean.isEnabled
    @State private var notificationsRefused = false
    @State private var showsPlan = false
    @State private var copiedPlan = false
    /// Whether the list is grouped by project rather than by category.
    @AppStorage("listsByProject") private var listsByProject = false
    /// The project an archive is being confirmed for; nil for any other batch.
    @State private var archivingProject: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            // Cards rather than strips, inset like the overview under them,
            // so a notice reads as part of the window.
            if !model.hasFullDiskAccess {
                accessBanner
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
            if let version = updates.newVersion {
                updateBanner(version)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
            if model.isLowOnSpace, model.safeAutoBytes > 0, !model.isScanning {
                lowSpaceBanner
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
            if notificationsRefused {
                feedbackRow(
                    L("macOS is not allowing notifications from this app. Turn them on in System Settings > Notifications."),
                    symbol: "bell.slash", tint: .orange
                ) { notificationsRefused = false }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            if let failure = updates.installError {
                feedbackRow(failure, symbol: "exclamationmark.triangle.fill", tint: .orange) {
                    updates.installError = nil
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            if showsHistory {
                HistoryPanel(log: model.history, focus: model.growthFocus) {
                    model.keepsHistory = false
                    showsHistory = false
                }
            } else {
                content
            }
            Divider()
            footer
        }
        .overlay { confirmationOverlay }
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: isConfirming)
        .modifier(PanelSize(presentation: presentation))
        .onChange(of: model.reclaimedBytes) { old, new in
            if new > old { freedFlash = new - old }
        }
        .task(id: freedFlash) {
            guard freedFlash != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            freedFlash = nil
        }
        .onChange(of: model.growthFocus) { _, focus in
            if focus != nil { showsHistory = true }
        }
        // However History is left — the menu, Forget everything, turning the
        // record off — the notification's question is answered. Left set, it
        // would head the next ordinary visit, and a second notification for
        // the same category would not change anything to open it again.
        .onChange(of: showsHistory) { _, shown in
            if !shown { model.growthFocus = nil }
        }
        .task {
            if !model.hasScanned, !model.isScanning { await model.scan() }
            await updates.checkIfDue()
        }
    }

    /// Shown where the Full Disk Access banner goes: the one place in this
    /// window that is already understood as "something needs your attention".
    private func updateBanner(_ version: String) -> some View {
        NoticeCard(symbol: "arrow.down", tint: .accentColor, title: L("Version %@ is available.", version)) {
            if updates.isInstalling {
                ProgressView().controlSize(.small)
            } else if updates.newVersionImage != nil {
                Button(L("Update")) { Task { await updates.install() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            } else {
                // No image on the release: nothing to install, so the release
                // page is the only honest offer.
                Button(L("Download")) { NSWorkspace.shared.open(updates.downloadURL) }
                    .controlSize(.small)
            }
        }
    }

    /// Shown when free space is under the warning threshold. The one place the
    /// app offers to act without a confirmation, because the set it frees is
    /// the safe subset — caches that regenerate, nothing that needs a password
    /// or a second thought.
    private var lowSpaceBanner: some View {
        NoticeCard(
            symbol: "externaldrive.fill.badge.exclamationmark", tint: .orange,
            title: L("Low on disk space"),
            message: L("%@ free · %@ of safe items can go now",
                       model.freeBytes.byteString, model.safeAutoBytes.byteString)
        ) {
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
    }

    // MARK: Confirmation

    private var isConfirming: Bool {
        pendingDeletion != nil || confirmsBatch
    }

    private var hasReviewItems: Bool {
        pendingItems.contains { $0.safety == .review && !$0.action.isManual }
    }

    private var confirmationTitle: String {
        if let item = pendingDeletion { return L("Delete %@?", item.name) }
        if let project = archivingProject { return L("Archive %@?", project) }
        return L("Delete %lld items?", model.selectedItems.count)
    }

    /// Runs what the card is asking about, after the Mac's own check when the
    /// person has asked for one. A cancelled check leaves the card open, so
    /// nothing is lost by trying again or pressing Cancel.
    private func confirmDeletion() {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        Task {
            defer { isAuthenticating = false }
            guard await DeleteAuthentication.authorize(
                isRequired: model.requiresAuthenticationToDelete
                    && !ScanModel.passwordGuardsWholeBatch(pendingItems),
                reason: L("Confirm the delete.")
            ) else { return }
            let item = pendingDeletion
            dismissConfirmation()
            if let item {
                await model.reclaim(item)
            } else {
                await model.reclaimSelected()
            }
        }
    }

    private func dismissConfirmation() {
        pendingDeletion = nil
        confirmsBatch = false
        archivingProject = nil
        showsPlan = false
        copiedPlan = false
    }

    /// The list behind the card is dimmed and inert while the question is
    /// open; clicking it is the same as Cancel.
    @ViewBuilder
    private var confirmationOverlay: some View {
        if isConfirming {
            ZStack(alignment: .bottom) {
                Rectangle()
                    .fill(.black.opacity(0.4))
                    .ignoresSafeArea()
                    .onTapGesture { if !isAuthenticating { dismissConfirmation() } }
                    .accessibilityHidden(true)
                    .transition(.opacity)
                DeleteConfirmation(
                    title: confirmationTitle,
                    items: pendingItems,
                    message: pendingDeletion.flatMap { $0.safety == .review ? nil : confirmationMessage(for: $0) },
                    confirmTitle: pendingDeletion != nil ? L("Delete")
                        : archivingProject != nil ? L("Archive")
                        : L("Delete %lld items", model.selectedItems.count),
                    needsAdministrator: needsAdministrator,
                    offersDestination: hasReviewItems,
                    deletesImmediately: Binding(
                        get: { model.deletesReviewItemsImmediately },
                        set: { model.deletesReviewItemsImmediately = $0 }
                    ),
                    showsPlan: $showsPlan,
                    plan: plannedOperations,
                    copiedPlan: copiedPlan,
                    isAuthenticating: isAuthenticating,
                    onCopyPlan: copyPlan,
                    onCancel: dismissConfirmation,
                    onConfirm: confirmDeletion
                )
                .padding(12)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: Header

    /// The title and controls on one row, and the figures on a full-width
    /// line under them. The figures used to share the row with the controls;
    /// with the taller, wider buttons of the current macOS design they were
    /// squeezed onto three lines.
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            headerTitleRow
            // Once there is a list, the overview under the filter carries
            // these figures; repeating them here was the noise that made the
            // header read as a spreadsheet row.
            if model.isScanning || model.visibleItems.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .help(L("Free space on the startup disk."))
            }
        }
        .padding(.horizontal, presentation == .window ? 18 : 14)
        .padding(.vertical, presentation == .window ? 14 : 10)
        // In the window the title bar is transparent and empty, so the header
        // is the title: it needs the traffic lights' row above it.
        .padding(.top, presentation == .window ? 20 : 0)
    }

    private var headerTitleRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 30, height: 30)
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(L("System Data"))
                    .font(titleFont)
                if !model.visibleItems.isEmpty {
                    Text(model.measuredBytes.byteString)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(model.measuredBytes)))
                }
            }
            Spacer()
            HStack(spacing: 2) {
                if !model.isScanning, !model.visibleItems.isEmpty {
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
                    .fixedSize()
                    .frame(width: 28, height: 28)
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
                    // Round, like every icon in the header: a row of icons
                    // should not look like different kinds of thing.
                    .buttonStyle(RoundIconButtonStyle())
                    .accessibilityLabel(
                        model.areAllListedCategoriesCollapsed ? L("Expand all") : L("Collapse all")
                    )
                    .help(model.areAllListedCategoriesCollapsed ? L("Expand all") : L("Collapse all"))
                }
                // Determinate while the probes run: the first scan on a full
                // disk is slow enough that a spinner alone cannot be told
                // apart from a hang. The ring around the button is that count.
                ScanButton(
                    isScanning: model.isScanning,
                    progress: model.probesTotal > 0 && model.probesFinished < model.probesTotal
                        ? Double(model.probesFinished) / Double(model.probesTotal) : nil
                ) {
                    Task { await model.scan() }
                }
                settingsMenu
            }
        }
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
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.4), in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color.accentColor.opacity(filterIsFocused ? 0.6 : 0), lineWidth: 1.5)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: filterIsFocused)
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
        NoticeCard(
            symbol: "lock.shield.fill", tint: .orange,
            title: L("Grant Full Disk Access once"),
            message: L("One grant covers everything. Until then this scan leaves the protected places alone — app containers, Desktop, Documents, Music, Photos — rather than asking about them one app at a time, so what you see below is incomplete. Add System Data Unpacked in the settings pane, then reopen the app.")
        ) {
            Button(L("Open Settings")) {
                NSWorkspace.shared.open(Self.fullDiskAccessPane)
            }
            .controlSize(.small)
        }
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
                overview
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                if let plan = model.activeSpacePlan {
                    spacePlanCard(plan)
                        .padding(.horizontal, 16)
                }
                ModeSwitch(byProject: $listsByProject)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                if listsByProject {
                    projectList
                } else {
                    list
                }
            }
        }
    }

    /// The number to act on, the disk it sits in, and the pulse line: how big
    /// System Data is, how much room is left and, once the history reaches
    /// back a week, which way it went. A rise large enough to earn the weekly
    /// summary gets the amber arrow.
    private var overview: some View {
        DiskOverview(
            safe: model.bytes(.safe),
            review: model.bytes(.review),
            manual: model.bytes(.manual),
            free: model.freeBytes,
            capacity: model.capacityBytes,
            purgeable: model.purgeableBytes,
            pulse: pulseText,
            showsGrowthArrow: (model.weeklyChange ?? 0) >= WeeklyDigest.floor,
            allSafeSelected: model.everyListedSafeItemIsSelected,
            canSelectSafe: !model.isScanning && model.safeBytes > 0,
            onSelectSafe: { model.selectAllSafe() },
            onPlan: { model.planSpace(freeing: $0) },
            justFreed: freedFlash,
            trend: model.keepsHistory ? model.history.scans.suffix(30).map(\.totalBytes) : []
        )
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: model.safeBytes)
    }

    /// What "Free up…" chose, in words: how much, how many, and how much of it
    /// needs a look. The batch itself is the selection in the list below.
    private func spacePlanCard(_ plan: SpacePlan) -> some View {
        let reaches = plan.reachesTarget
        let detail: String = if plan.items.isEmpty {
            L("Nothing here can be freed by this app.")
        } else if !reaches {
            L("That is %@ short of %@.", plan.shortfall.byteString, plan.target.byteString)
                + " " + L("Only the safe items are selected; the rest is yours to choose.")
        } else if plan.reviewCount == 0 {
            L("All of it is safe: it rebuilds on its own.")
        } else {
            L("%lld of them need a look first, longest untouched first.", plan.reviewCount)
        }
        return NoticeCard(
            symbol: "target", tint: reaches ? .green : .orange,
            title: reaches
                ? L("Plan to free %@", plan.target.byteString)
                : L("Everything this app can free is %@", plan.available.byteString),
            message: plan.items.isEmpty
                ? detail
                : L("%lld items · %@", plan.items.count, plan.totalBytes.byteString) + "\n" + detail
        ) {
            Button(L("Clear")) { model.clearSelection() }
                .controlSize(.small)
        }
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
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(groups, id: \.category) { group in
                    let isOpen = !model.collapsedCategories.contains(group.category)
                    // One card per group: the header, its bar and, when it is
                    // open, its rows, so a group reads as one thing.
                    VStack(alignment: .leading, spacing: 0) {
                        categoryHeader(group.category, total: group.total, items: group.items)
                        atlasRow(group.category, items: group.items, scale: scale, growth: growth[group.category])
                            .padding(.top, 5)
                            .padding(.bottom, isOpen ? 8 : 0)
                        if isOpen {
                            ForEach(group.items) { item in
                                Divider().opacity(0.6)
                                itemRow(item)
                                    .padding(.vertical, 4)
                            }
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                    .listCard(raised: hoveredCategory == group.category)
                    .onHover { hoveredCategory = $0 ? group.category : (hoveredCategory == group.category ? nil : hoveredCategory) }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    /// Every project the scan found build output for, largest first. Each row
    /// is what one project costs across the disk; archiving one selects its
    /// items and goes through the same confirmation as any batch, commands
    /// shown.
    @ViewBuilder
    private var projectList: some View {
        let projects = model.projectFootprints
        if projects.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "folder")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(model.isScanning ? L("Measuring…") : L("No project build output found"))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    projectSummary(projects)
                        .padding(.top, 6)
                        .padding(.bottom, 2)
                    ForEach(projects) { project in
                        ProjectRow(
                            project: project,
                            isBusy: project.items.contains { model.busyItemIDs.contains($0.id) }
                        ) { archive(project) }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .listCard(raised: hoveredProject == project.id)
                        .onHover { hoveredProject = $0 ? project.id : (hoveredProject == project.id ? nil : hoveredProject) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
        }
    }

    /// "31 projects · 18.2 GB · 9 idle 60+ days: 6.1 GB"
    private func projectSummary(_ projects: [ProjectFootprint]) -> some View {
        let total = projects.reduce(0) { $0 + $1.totalBytes }
        let idle = projects.filter { !$0.exists || ($0.idleDays ?? 0) >= ScanModel.idleProjectDays }
        let idleBytes = idle.reduce(0) { $0 + $1.totalBytes }
        var parts = [projects.count == 1
            ? L("1 project · %@", total.byteString)
            : L("%lld projects · %@", projects.count, total.byteString)]
        if !idle.isEmpty {
            parts.append(L("%lld idle %lld+ days: %@", idle.count, ScanModel.idleProjectDays, idleBytes.byteString))
        }
        return HStack(alignment: .firstTextBaseline) {
            Text(parts.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer(minLength: 8)
            Button {
                copyShareCard(projects)
            } label: {
                Label(L("Copy card"), systemImage: "square.and.arrow.up")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help(L("Copy an image of these totals to paste into a post. It names no project."))
        }
    }

    /// Puts the share card on the pasteboard, where every place people post
    /// takes an image from, and says so.
    private func copyShareCard(_ projects: [ProjectFootprint]) {
        guard let image = ProjectShareCard.image(for: projects) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        model.errorMessage = nil
        model.notice = L("Card copied. Paste it into a post.")
    }

    private func archive(_ project: ProjectFootprint) {
        pendingDeletion = nil
        model.selectedIDs = Set(project.archivableItems.map(\.id))
        archivingProject = project.name
        confirmsBatch = true
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
        // Starts under the category name, past the chevron, the checkbox and
        // the icon.
        .padding(.leading, 67)
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
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(model.collapsedCategories.contains(category) ? 0 : 90))
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
                HStack(spacing: 7) {
                    CategoryIcon(category: category, isRaised: hoveredCategory == category)
                    Text(category.title)
                        .fontWeight(.semibold)
                }
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .disabled(!model.categoryHasSelectableItems(category))
            if category == .projects, !model.idleProjectItems.isEmpty {
                Button(L("Idle %lld days: %lld", ScanModel.idleProjectDays, model.idleProjectItems.count)) {
                    model.selectIdleProjects()
                }
                .buttonStyle(.link)
                .font(.caption)
                .help(L("Select the build folders of projects whose own files nobody has changed in this long. Each is recreated by its build or install command."))
            }
            Spacer()
            // A category whose sizes are all unmeasurable — APFS never reports
            // a snapshot's size — summed to zero and displayed "0 bytes", which
            // reads as "nothing here" for the one group where the app does not
            // know. The rows already say "—"; the header now agrees with them.
            // A group where only some sizes are unknown keeps its total, which
            // is still the truth about what was measured.
            let isUnmeasurable = items.allSatisfy { $0.sizeBytes == nil }
            Text(isUnmeasurable ? "—" : total.byteString)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(isUnmeasurable ? .secondary : .primary)
                .contentTransition(.numericText(value: Double(total)))
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
                    if !showsHistory { model.growthFocus = nil }
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
            Toggle(L("Look for projects on external drives"), isOn: Binding(
                get: { model.scansExternalDrives },
                set: { wanted in
                    model.scansExternalDrives = wanted
                    Task { await model.scan() }
                }
            ))
            .help(L("Searches the Developer, Projects, Projeler, Code and dev folders of drives that are plugged in. Time Machine disks and network shares are never searched."))
            if DeleteAuthentication.isAvailable {
                Toggle(L("Ask for Touch ID before deleting"), isOn: Binding(
                    get: { model.requiresAuthenticationToDelete },
                    set: { model.requiresAuthenticationToDelete = $0 }
                ))
                .help(L("Asks for Touch ID, your Apple Watch or your Mac password before a delete you confirm here. The automatic weekly clean and Shortcuts run unattended and never ask."))
            }
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
                    // app would leave it with nowhere to appear, so the window
                    // opens before the icon goes — and when the switch is
                    // thrown from the menu bar panel, the icon waits for that
                    // panel to close.
                    guard wanted else {
                        MainWindow.shared.openWindowLeavingTheMenuBar()
                        return
                    }
                    model.showsMenuBarIcon = true
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
        // On a disc, the one filled icon in the header: everything the app
        // can be told to do is behind it.
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 28, height: 28)
        .background(Circle().fill(.quaternary.opacity(0.45)))
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
                feedbackRow(message, symbol: model.offersSnapshotCleanup ? "exclamationmark.circle.fill" : "checkmark.circle.fill",
                            tint: model.offersSnapshotCleanup ? .orange : .green) {
                    model.notice = nil
                    model.offersSnapshotCleanup = false
                }
                if model.noticeOffersEmptyingTheTrash, let trash = model.trashItem {
                    // Same confirmation as any other row: it forgets files for
                    // good, so the commands are shown and it is asked once.
                    Button(L("Empty the Trash…")) {
                        model.notice = nil
                        pendingDeletion = trash
                    }
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if model.offersSnapshotCleanup, let snapshots = model.snapshotItem {
                    // Through the same confirmation as any other row, command
                    // shown: the notice explains, the person still decides.
                    Button(L("Delete local snapshots…")) {
                        model.notice = nil
                        model.offersSnapshotCleanup = false
                        pendingDeletion = snapshots
                    }
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !model.selectedItems.isEmpty, !isConfirming {
                selectionTray
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(spacing: 10) {
                // Said only once there is something to say: "0 bytes" on
                // every launch was a line of noise under the list.
                if model.reclaimedBytes > 0 {
                    Label(L("Reclaimed this session: %@", model.reclaimedBytes.byteString),
                          systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(model.reclaimedBytes)))
                        .symbolEffect(.bounce, value: model.reclaimedBytes)
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
                authorBadge
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
        }
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: model.selectedItems.isEmpty)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // The list above is greedy; the footer must keep its full height so
        // a long error never overlaps the status line.
        .layoutPriority(1)
    }

    /// What is ticked, how much it comes to, and the two things to do with
    /// it. It used to be one more capsule in a footer row already holding
    /// the off-screen count, Deselect and Quit.
    private var selectionTray: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.selectedBytes.byteString)
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(model.selectedBytes)))
                // In the Projects view the rows are projects, and an
                // archive's items are in them, not off screen.
                if !listsByProject, model.selectedOffScreenCount > 0 {
                    // The batch reaches further than the window does. Say
                    // so, rather than deleting rows nobody can see.
                    Text(L("%lld not on screen", model.selectedOffScreenCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 8)
            // "Deselect", not "Clear": in a cleaner the word "Clear" reads as
            // the app's own verb — free space now — so people pressed it
            // expecting a delete and reported that nothing happened. This
            // only ever unticks the selection.
            Button(L("Deselect")) {
                model.clearSelection()
            }
            .buttonStyle(PanelButtonStyle(kind: .secondary, compact: true))
            .help(L("Untick the selected items. It deletes nothing."))
            Button(role: .destructive) {
                confirmsBatch = true
            } label: {
                Label(L("Delete %lld items", model.selectedItems.count), systemImage: "trash.fill")
                    .monospacedDigit()
            }
            .buttonStyle(PanelButtonStyle(kind: .destructive, compact: true))
            .disabled(!model.busyItemIDs.isEmpty)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.red.opacity(0.08))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.red.opacity(0.25))
                }
        }
    }

    /// A notice after an action: what happened, and a way to dismiss it.
    ///
    /// Only as tall as its text. It used to sit in a scroll view capped at
    /// 96 points, and on macOS a scroll view takes all the height it is
    /// allowed, so a one-line "Moved to the Trash" held a box three times its
    /// size. The scroll view is kept for what needs it: a batch's failures,
    /// one per line, can run long.
    private func feedbackRow(_ message: String, symbol: String, tint: Color, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            if message.count > 280 || message.split(whereSeparator: \.isNewline).count > 4 {
                ScrollView { feedbackText(message) }
                    .frame(height: 96)
            } else {
                feedbackText(message)
            }
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel(L("Dismiss"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func feedbackText(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
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
        case .window:
            // The header sits under the transparent title bar on its own
            // padding. Whether the title bar also counts as safe area depends
            // on the macOS and SDK the app meets, and on macOS 27 the two
            // added up to an empty band above the title.
            content
                .frame(minWidth: 460, minHeight: 520)
                .ignoresSafeArea(.container, edges: .top)
        }
    }
}
