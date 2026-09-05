import AppKit
import SwiftUI

struct MenuView: View {
    @Environment(ScanModel.self) private var model
    @State private var pendingDeletion: StorageItem?
    @State private var confirmsBatch = false

    private static let fullDiskAccessPane = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )!

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !model.hasFullDiskAccess {
                accessBanner
                Divider()
            }
            content
            Divider()
            footer
        }
        .frame(width: 460, height: 640)
        .task {
            if !model.hasScanned { await model.scan() }
        }
        .confirmationDialog(
            pendingDeletion.map { "Delete \($0.name)?" } ?? "",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { item in
            Button("Delete", role: .destructive) {
                Task { await model.reclaim(item) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text(confirmationMessage(for: item))
        }
        .confirmationDialog(
            "Delete \(model.selectedItems.count) items?",
            isPresented: $confirmsBatch,
            titleVisibility: .visible
        ) {
            Button("Delete \(model.selectedItems.count) items", role: .destructive) {
                Task { await model.reclaimSelected() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(batchMessage)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("System Data")
                    .font(.headline)
                Text(model.isScanning && !model.phase.isEmpty
                     ? model.phase
                     : "\(model.freeBytes.byteString) free · \(model.measuredBytes.byteString) found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            if model.isScanning {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Scanning")
            } else {
                if !model.items.isEmpty {
                    Button("Select safe") {
                        model.selectAllSafe()
                    }
                    .controlSize(.small)
                    .help("Select every item that is regenerated automatically")
                }
                Button {
                    Task { await model.scan() }
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Full Disk Access

    private var accessBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Grant Full Disk Access once")
                    .font(.caption.weight(.semibold))
                Text("Without it macOS asks for every protected folder and hides Mail, Safari and Time Machine data. Add System Data in the settings pane, then rescan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Settings") {
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
        if model.items.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                if model.isScanning {
                    ProgressView()
                    Text("Measuring…")
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "checkmark.circle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Nothing to reclaim")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            List {
                ForEach(model.categories, id: \.category) { group in
                    Section {
                        ForEach(group.items) { item in
                            ItemRow(
                                item: item,
                                isBusy: model.busyItemIDs.contains(item.id),
                                isSelected: model.selectedIDs.contains(item.id),
                                onToggle: { model.toggleSelection(item) },
                                onDelete: { pendingDeletion = item }
                            )
                        }
                    } header: {
                        HStack {
                            Text(group.category.title)
                            Spacer()
                            Text(group.total.byteString)
                                .monospacedDigit()
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 6) {
            if let message = model.errorMessage {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(message)
                        .font(.caption)
                        .lineLimit(3)
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        model.errorMessage = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss error")
                }
            }
            HStack {
                if model.selectedItems.isEmpty {
                    Text("Reclaimed this session: \(model.reclaimedBytes.byteString)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Button(role: .destructive) {
                        confirmsBatch = true
                    } label: {
                        Text("Delete \(model.selectedItems.count) selected · \(model.selectedBytes.byteString)")
                            .monospacedDigit()
                    }
                    .controlSize(.small)
                    .disabled(!model.busyItemIDs.isEmpty)
                    Button("Clear") {
                        model.clearSelection()
                    }
                    .controlSize(.small)
                }
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .controlSize(.small)
                .keyboardShortcut("q")
            }
            HStack {
                authorBadge
                Spacer()
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchesAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
        .accessibilityLabel("Open x.com/yigitech")
    }

    // MARK: Confirmation copy

    private func confirmationMessage(for item: StorageItem) -> String {
        let size = item.sizeBytes.map { "Frees about \($0.byteString). " } ?? ""
        switch item.safety {
        case .safe:
            return size + "This is regenerated automatically when needed."
        case .review:
            return size + item.detail
        case .manual:
            return item.detail
        }
    }

    private var batchMessage: String {
        let selected = model.selectedItems
        let review = selected.filter { $0.safety == .review }
        let privileged = selected.filter { if case .privilegedScript = $0.action { true } else { false } }
        var lines = ["Frees about \(model.selectedBytes.byteString)."]
        if !review.isEmpty {
            lines.append("\(review.count) marked Review: " + review.prefix(4).map(\.name).joined(separator: ", ")
                         + (review.count > 4 ? ", …" : ""))
        }
        if privileged.count > 1 {
            lines.append("\(privileged.count) items need root; the password is asked once.")
        } else if privileged.count == 1 {
            lines.append("1 item needs root; the password is asked once.")
        }
        return lines.joined(separator: "\n")
    }
}
