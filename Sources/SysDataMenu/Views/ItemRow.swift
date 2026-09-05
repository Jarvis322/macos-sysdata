import AppKit
import SwiftUI

struct ItemRow: View {
    let item: StorageItem
    let isBusy: Bool
    let isSelected: Bool
    let onToggle: () -> Void
    let onDelete: () -> Void
    let onHide: () -> Void

    @State private var showsInstructions = false
    @State private var isExpanded = false
    @State private var breakdown: [(url: URL, bytes: Int64)]?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Toggle(isOn: Binding(get: { isSelected }, set: { _ in onToggle() })) {
                    EmptyView()
                }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(item.action.isManual || isBusy)
                .opacity(item.action.isManual ? 0 : 1)
                .accessibilityLabel(L("Select %@", item.name))
                .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.name)
                            .lineLimit(1)
                        safetyBadge
                    }
                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .contentShape(Rectangle())
                .onTapGesture { toggleExpanded() }

                Spacer(minLength: 8)
                Text(item.sizeBytes?.byteString ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(item.sizeBytes == nil ? .secondary : .primary)
                    .frame(minWidth: 68, alignment: .trailing)
                actions
            }
            if isExpanded {
                breakdownView
                    .padding(.leading, 28)
            }
        }
        .padding(.vertical, 2)
        .opacity(isBusy ? 0.5 : 1)
    }

    private var canExpand: Bool {
        item.revealURL?.isDirectory ?? false
    }

    private func toggleExpanded() {
        guard canExpand else { return }
        isExpanded.toggle()
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

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 4) {
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
