import AppKit
import SwiftUI

struct ItemRow: View {
    let item: StorageItem
    let isBusy: Bool
    let isSelected: Bool
    let onToggle: () -> Void
    let onDelete: () -> Void

    @State private var showsInstructions = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle(isOn: Binding(get: { isSelected }, set: { _ in onToggle() })) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(item.action.isManual || isBusy)
            .opacity(item.action.isManual ? 0 : 1)
            .accessibilityLabel("Select \(item.name)")
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
            Spacer(minLength: 8)
            Text(item.sizeBytes?.byteString ?? "—")
                .monospacedDigit()
                .foregroundStyle(item.sizeBytes == nil ? .secondary : .primary)
                .frame(minWidth: 68, alignment: .trailing)
            actions
        }
        .padding(.vertical, 2)
        .opacity(isBusy ? 0.5 : 1)
    }

    private var safetyBadge: some View {
        Text(item.safety.label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(badgeColor.opacity(0.18), in: Capsule())
            .foregroundStyle(badgeColor)
            .accessibilityLabel("Safety: \(item.safety.label)")
    }

    private var badgeColor: Color {
        switch item.safety {
        case .safe: .green
        case .review: .orange
        case .manual: .secondary
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 4) {
            if let url = item.revealURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Image(systemName: "folder")
                }
                .accessibilityLabel("Reveal \(item.name) in Finder")
            }

            if let instructions = item.action.manualInstructions {
                Button {
                    showsInstructions.toggle()
                } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel("How to remove \(item.name)")
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
                .accessibilityLabel("Delete \(item.name)")
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
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(instructions, forType: .string)
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 340)
    }
}
