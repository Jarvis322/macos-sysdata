import AppKit
import SwiftUI

struct ItemRow: View {
    let item: StorageItem
    /// Growth since the previous scan, when there is one to compare against.
    let change: Int64?
    let isBusy: Bool
    let isSelected: Bool
    let onToggle: (Bool) -> Void
    let onDelete: () -> Void
    let onHide: () -> Void

    @State private var showsInstructions = false
    @State private var isExpanded = false
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breakdown: [(url: URL, bytes: Int64)]?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Toggle(isOn: Binding(get: { isSelected }, set: { onToggle($0) })) {
                    EmptyView()
                }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(item.action.isManual || isBusy)
                .opacity(item.action.isManual ? 0 : 1)
                .accessibilityLabel(L("Select %@", item.name))
                .padding(.top, 2)

                // Everything between the checkbox and the buttons opens the
                // breakdown, which is most of the row — aiming at a 13pt label
                // was work the pointer should not have had. The checkbox and
                // the action buttons stay outside it: whether a tap gesture or
                // the control under the pointer wins is SwiftUI's to
                // arbitrate, and the selection checkbox is not the place to
                // find out.
                HStack(alignment: .top, spacing: 10) {
                    details
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
        .onHover { isHovered = $0 }
        // Hover is a pointer idea. The same three controls have to be
        // reachable without one — by right-click, and by the keyboard through
        // the context menu — or hiding them takes them away from the people
        // least able to spare them.
        .contextMenu { rowMenu }
        .opacity(isBusy ? 0.5 : 1)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(item.name)
                    .lineLimit(1)
                safetyBadge
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let idle = item.idleLabel {
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

    private var canExpand: Bool {
        item.revealURL?.isDirectory ?? false
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

    private var safetyBadge: some View {
        Text(item.safety.label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(badgeColor.opacity(0.18), in: Capsule())
            .foregroundStyle(badgeColor)
            .accessibilityLabel(L("Safety: %@", item.safety.label))
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
    /// They stay in the view tree at zero opacity rather than being removed, so
    /// VoiceOver still reaches them; hit testing goes with the opacity so an
    /// invisible "hide this item" button cannot be clicked by accident.
    private var showsSecondaryActions: Bool {
        isHovered || isExpanded
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 4) {
            Group {
                if canExpand {
                    Button(action: toggleExpanded) {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    }
                    .accessibilityLabel(isExpanded ? L("Hide breakdown") : L("Show largest entries"))
                }

                if let url = item.revealURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Image(systemName: "folder")
                    }
                    .accessibilityLabel(L("Reveal %@ in Finder", item.name))
                }

                Button(action: onHide) {
                    Image(systemName: "eye.slash")
                }
                .accessibilityLabel(L("Hide %@ from future scans", item.name))
                .help(L("Don't show this item again"))
            }
            .opacity(showsSecondaryActions ? 1 : 0)
            .allowsHitTesting(showsSecondaryActions)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: showsSecondaryActions)

            if let instructions = item.action.manualInstructions {
                Button {
                    showsInstructions.toggle()
                } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel(L("How to remove %@", item.name))
                .popover(isPresented: $showsInstructions, arrowEdge: .trailing) {
                    instructionsPopover(instructions)
                }
            } else if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 20)
            } else {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .accessibilityLabel(L("Delete %@", item.name))
            }
        }
        .buttonStyle(.borderless)
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
