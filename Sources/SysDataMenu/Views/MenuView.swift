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
            if !model.hasScanned, !model.isScanning { await model.scan() }
        }
        .confirmationDialog(
            pendingDeletion.map { L("Delete %@?", $0.name) } ?? "",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { item in
            Button(L("Delete"), role: .destructive) {
                Task { await model.reclaim(item) }
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: { item in
            Text(confirmationMessage(for: item))
        }
        .confirmationDialog(
            L("Delete %lld items?", model.selectedItems.count),
            isPresented: $confirmsBatch,
            titleVisibility: .visible
        ) {
            Button(L("Delete %lld items", model.selectedItems.count), role: .destructive) {
                Task { await model.reclaimSelected() }
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(batchMessage)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("System Data"))
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            if model.isScanning {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(L("Scanning"))
            } else {
                if !model.visibleItems.isEmpty {
                    Button(L("Select safe")) {
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
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var subtitle: String {
        if model.isScanning, !model.phase.isEmpty {
            return model.phase
        }
        return L("%@ free · %@ purgeable · %@ found",
                 model.freeBytes.byteString, model.purgeableBytes.byteString, model.measuredBytes.byteString)
    }

    // MARK: Full Disk Access

    private var accessBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Grant Full Disk Access once"))
                    .font(.caption.weight(.semibold))
                Text(L("Without it macOS asks for every protected folder and hides Mail, Safari and Time Machine data. Add System Data in the settings pane, then reopen the app."))
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
        if model.visibleItems.isEmpty {
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
            List {
                ForEach(model.categories, id: \.category) { group in
                    Section {
                        ForEach(group.items) { item in
                            ItemRow(
                                item: item,
                                isBusy: model.busyItemIDs.contains(item.id),
                                isSelected: model.selectedIDs.contains(item.id),
                                onToggle: { model.toggleSelection(item) },
                                onDelete: { pendingDeletion = item },
                                onHide: { model.hide(item) }
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
                    Button(L("Clear")) {
                        model.clearSelection()
                    }
                    .controlSize(.small)
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
                Button(L("Quit")) {
                    NSApplication.shared.terminate(nil)
                }
                .controlSize(.small)
                .keyboardShortcut("q")
            }
            HStack {
                authorBadge
                Spacer()
                Toggle(L("Launch at login"), isOn: Binding(
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

    private func feedbackRow(_ message: String, symbol: String, tint: Color, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(message)
                .font(.caption)
                .lineLimit(3)
                .textSelection(.enabled)
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(L("Dismiss"))
        }
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
        let privileged = selected.filter { if case .privilegedScript = $0.action { true } else { false } }
        var lines = [L("Frees about %@. ", model.selectedBytes.byteString)]
        if !review.isEmpty {
            let names = review.prefix(4).map(\.name).joined(separator: ", ") + (review.count > 4 ? ", …" : "")
            lines.append(L("%lld marked Review go to the Trash: %@", review.count, names))
        }
        if privileged.count > 1 {
            lines.append(L("%lld items need root; the password is asked once.", privileged.count))
        } else if privileged.count == 1 {
            lines.append(L("1 item needs root; the password is asked once."))
        }
        return lines.joined(separator: "\n")
    }
}
