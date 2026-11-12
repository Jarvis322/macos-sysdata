import AppKit
import SwiftUI

struct ItemRow: View {
    let item: StorageItem
    /// Whether the folder can be opened here. Worked out once by the model:
    /// asking the disk while the row is built made every redraw a filesystem
    /// call.
    let canExpand: Bool
    /// Growth since the previous scan, when there is one to compare against.
    let change: Int64?
    /// This item's size over the recent scans, for the sparkline. Fewer than
    /// three points is not a trend and draws nothing.
    var trend: [Int64] = []
    let isBusy: Bool
    let isSelected: Bool
    let onToggle: (Bool) -> Void
    let onDelete: () -> Void
    let onHide: () -> Void
    /// Set when the row can be shrunk instead of deleted.
    var onShrink: (() -> Void)?

    @State private var showsInstructions = false
    @State private var isExpanded = false
    @State private var isHovered = false
    /// Waits for the pointer to settle before revealing the secondary
    /// actions. Scrolling moves a new row under a still pointer many times a
    /// second; without the wait, each one re-rendered its row just to hide
    /// the buttons again.
    @State private var hoverTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breakdown: [(url: URL, bytes: Int64)]?

    var body: some View {
        // Asked once for the row instead of by every line that shows an age.
        let idleDays = item.idleDays
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                checkbox
                // Everything between the checkbox and the buttons opens the
                // breakdown, which is most of the row — aiming at a 13pt label
                // was work the pointer should not have had. The checkbox and
                // the action buttons stay outside it.
                HStack(alignment: .top, spacing: 10) {
                    details(idleDays: idleDays)
                    Spacer(minLength: 8)
                    sizeColumn
                }
                .contentShape(Rectangle())
                .onTapGesture { toggleExpanded() }

                actions
            }
            if isExpanded {
                breakdownView
                    .padding(.leading, 28)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 4)
        .background(rowBackground)
        .onHover { inside in
            hoverTask?.cancel()
            guard inside else {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                    isHovered = false
                }
                return
            }
            hoverTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(60))
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                    isHovered = true
                }
            }
        }
        .onDisappear { hoverTask?.cancel() }
        // Hover is a pointer idea. The same controls have to be reachable
        // without one — by right-click, and by the keyboard through the
        // context menu — or hiding them takes them away from the people
        // least able to spare them.
        .contextMenu { rowMenu }
        .opacity(isBusy ? 0.5 : 1)
    }

    /// Drawn rather than a `Toggle`: a native checkbox is an AppKit view, and
    /// a list of rows each carrying one put hundreds of them inside the
    /// scroll view. A `Canvas` keeps the box and its tick in one layer.
    private var checkbox: some View {
        Canvas { context, size in
            let box = CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
            let shape = Path(roundedRect: box, cornerRadius: 3.5)
            if isSelected {
                context.fill(shape, with: .color(.accentColor))
                var tick = Path()
                tick.move(to: CGPoint(x: size.width * 0.24, y: size.height * 0.52))
                tick.addLine(to: CGPoint(x: size.width * 0.43, y: size.height * 0.70))
                tick.addLine(to: CGPoint(x: size.width * 0.78, y: size.height * 0.31))
                context.stroke(
                    tick, with: .color(.white),
                    style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)
                )
            } else {
                context.stroke(shape, with: .color(.secondary.opacity(0.55)), lineWidth: 1)
            }
        }
        .frame(width: 14, height: 14)
        .contentShape(Rectangle())
        .opacity(item.action.isManual ? 0 : 1)
        .allowsHitTesting(!item.action.isManual && !isBusy)
        .onTapGesture { onToggle(!isSelected) }
        .padding(.top, 2)
        .accessibilityElement()
        .accessibilityLabel(L("Select %@", item.name))
        .accessibilityValue(isSelected ? L("Selected") : L("Not selected"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onToggle(!isSelected) }
    }

    private func details(idleDays: Int?) -> some View {
        let isIdleProject = item.category == .projects && (idleDays ?? 0) >= ScanModel.idleProjectDays
        let idle = idleDays.flatMap(StorageItem.idlePhrase)
        return VStack(alignment: .leading, spacing: 3) {
            // The name comes first and gives way before the badge does: the
            // badge's word is fixed, so a narrow window truncates the name
            // rather than spelling out "Reviewed" as "Rev…".
            HStack(spacing: 6) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                safetyBadge
                if isIdleProject, let idle {
                    idleBadge(idle)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if !isIdleProject, let idle {
                    // Only appears past a fortnight, so it marks the rows
                    // where age is the deciding fact rather than repeating
                    // "in use" on every line.
                    Text(idle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tertiary)
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var sizeColumn: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(item.sizeBytes?.byteString ?? "—")
                .monospacedDigit()
                .foregroundStyle(item.sizeBytes == nil ? .secondary : .primary)
            if let change, change != 0 {
                // Only growth and shrinkage since the previous scan. No
                // comparison at all reads as nothing here rather than as
                // "+0", which would be a claim.
                Text(change > 0 ? "+\(change.byteString)" : "−\(abs(change).byteString)")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(change > 0 ? Color.orange : Color.secondary)
            }
            if trend.count >= 3, trend.min() != trend.max() {
                // Coloured by direction, like the overview's line: growth is
                // the news, so it is the one that is warm.
                Sparkline(values: trend)
                    .foregroundStyle((trend.last ?? 0) > (trend.first ?? 0) ? Color.orange.opacity(0.8) : Color.green.opacity(0.8))
                    .accessibilityLabel(L("Size trend over recent scans"))
            }
        }
        .frame(minWidth: 68, alignment: .trailing)
    }

    @ViewBuilder
    private var rowMenu: some View {
        if canExpand {
            Button(isExpanded ? L("Hide breakdown") : L("Show largest entries"), action: toggleExpanded)
        }
        if let url = item.revealURL {
            Button(L("Reveal in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        Button(L("Don't show this item again"), action: onHide)
        if let onShrink {
            Divider()
            Button(L("Shrink without deleting"), action: onShrink)
        }
        if !item.action.isManual {
            Divider()
            Button(L("Delete"), role: .destructive, action: onDelete)
        }
    }

    /// Only rows that do something on click light up, so the highlight is a
    /// promise rather than decoration.
    @ViewBuilder
    private var rowBackground: some View {
        if isHovered, canExpand, !isBusy {
            // Bleeds past the row's own width rather than padding the content,
            // which would push every row 6pt off the category headers above it.
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary.opacity(0.5))
                .padding(.horizontal, -6)
        }
    }

    private func toggleExpanded() {
        guard canExpand else { return }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.22, extraBounce: 0)) {
            isExpanded.toggle()
        }
    }

    // MARK: Breakdown

    @ViewBuilder
    private var breakdownView: some View {
        if let breakdown {
            if breakdown.isEmpty {
                Text(L("Empty folder"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(breakdown, id: \.url) { child in
                        HStack {
                            Image(systemName: child.url.isDirectory ? "folder" : "doc")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(child.url.lastPathComponent)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            Text(child.bytes.byteString)
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } else {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text(L("Measuring the largest entries…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .task(id: item.id) {
                guard let url = item.revealURL else { return }
                breakdown = await DiskSize.largestChildren(of: url)
            }
        }
    }

    // MARK: Badge

    /// The safety as a chip with its own symbol, so it reads by shape as well
    /// as by colour: a shield for Safe, an eye for Review, a hand for Manual.
    private var safetyBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: badgeSymbol)
                .font(.system(size: 8, weight: .bold))
            Text(item.safety.label)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 1.5)
        .background(badgeColor.opacity(0.16), in: Capsule())
        .overlay { Capsule().strokeBorder(badgeColor.opacity(0.25), lineWidth: 0.5) }
        .foregroundStyle(badgeColor)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Safety: %@", item.safety.label))
    }

    private var badgeSymbol: String {
        switch item.safety {
        case .safe: "checkmark.shield.fill"
        case .review: "eye.fill"
        case .manual: "hand.raised.fill"
        }
    }

    /// The link's colour, so the rows and the count visibly belong together.
    private func idleBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.accentColor.opacity(0.18), in: Capsule())
            .foregroundStyle(Color.accentColor)
            .fixedSize()
            .help(L("Nobody has changed this project's own files in %lld days.", item.idleDays ?? 0))
    }

    private var badgeColor: Color {
        switch item.safety {
        case .safe: .green
        case .review: .orange
        case .manual: .secondary
        }
    }

    // MARK: Actions

    /// Reveal, hide and the breakdown chevron are shown on hover. They are the
    /// three least-used controls on a row, and a list of 180 rows was carrying
    /// well over five hundred icons at rest, which made the one control that
    /// matters — delete — no more prominent than the rest.
    ///
    /// They are built only while they are shown, with a placeholder of the
    /// same width holding their place otherwise: at rest every row was still
    /// a handful of image layers inside the scroll view. The row's context
    /// menu carries the same actions for assistive technology.
    private var showsSecondaryActions: Bool {
        isHovered || isExpanded
    }

    /// The three hover-only controls, in points, so the placeholder that
    /// replaces them keeps the row the same width.
    private var secondaryActionsWidth: CGFloat {
        // The chevron, the folder button and Hide, as the actions above.
        let count = (canExpand ? 1 : 0) + 1 + (item.revealURL != nil ? 1 : 0)
        return CGFloat(count) * 18 + CGFloat(max(count - 1, 0)) * 4
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 4) {
            if showsSecondaryActions {
                // One HStack so the three fade in and out as a group; the
                // placeholder below is the same width, so the row does not
                // change size while they cross-fade.
                HStack(spacing: 4) {
                    if canExpand {
                        RowAction(
                            symbol: isExpanded ? "chevron.up" : "chevron.down",
                            label: isExpanded ? L("Hide breakdown") : L("Show largest entries"),
                            help: isExpanded ? L("Hide breakdown") : L("Show largest entries"),
                            action: toggleExpanded
                        )
                    }

                    if let url = item.revealURL {
                        RowAction(
                            symbol: "folder",
                            label: L("Reveal %@ in Finder", item.name),
                            help: L("Reveal in Finder"),
                            action: { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        )
                    }

                    RowAction(
                        symbol: "eye.slash",
                        label: L("Hide %@ from future scans", item.name),
                        help: L("Don't show this item again"),
                        action: onHide
                    )
                }
                .transition(.opacity)
            } else {
                Spacer()
                    .frame(width: secondaryActionsWidth, height: 18)
            }

            if let instructions = item.action.manualInstructions {
                RowAction(
                    symbol: "info.circle",
                    label: L("How to remove %@", item.name),
                    help: L("How to remove this item"),
                    action: { showsInstructions.toggle() }
                )
                .popover(isPresented: $showsInstructions, arrowEdge: .trailing) {
                    instructionsPopover(instructions)
                }
            } else if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 20)
            } else {
                // Shown at rest, unlike the hover controls: it is the one
                // alternative to the delete beside it, and nobody looks for
                // a way to keep files on a row that only offers to delete.
                if let onShrink {
                    RowAction(
                        symbol: "arrow.down.right.and.arrow.up.left",
                        label: L("Shrink %@ without deleting", item.name),
                        help: L("Stores these files compressed, the way macOS stores its own. Nothing is deleted and everything opens as before."),
                        tint: Color.accentColor,
                        action: onShrink
                    )
                }
                RowAction(
                    symbol: "trash",
                    label: L("Delete %@", item.name),
                    help: L("Delete"),
                    action: onDelete
                )
            }
        }
    }

    private func instructionsPopover(_ instructions: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.name)
                .font(.headline)
            Text(item.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(instructions)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            Button(L("Copy")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(instructions, forType: .string)
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 340)
    }
}

/// One icon in a row's action column.
///
/// A `Button` would be an AppKit button on macOS, hosted inside the scroll
/// view; several per row made scrolling stutter as new rows arrived. This is
/// drawn by SwiftUI and carries the same label and action for assistive
/// technology.
private struct RowAction: View {
    let symbol: String
    let label: String
    let help: String
    var tint: Color = .primary
    let action: () -> Void

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13))
            .foregroundStyle(tint)
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .help(help)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}
