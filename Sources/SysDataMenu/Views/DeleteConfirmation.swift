import SwiftUI

/// The question asked before anything is deleted, as a card that rises over
/// the list instead of a strip squeezed in above the footer.
///
/// The strip said "Delete 5 items?" and nothing about which five, its two
/// buttons looked alike, and opening the command list pushed the window's
/// own header off the top. Here the items are named, the destination is a
/// choice between two described options, the plan scrolls inside its own
/// box, and the one button that deletes is the only red thing on screen.
///
/// Inline rather than a sheet: the menu bar panel is not a regular window,
/// so sheets and confirmation dialogs never appear on it.
struct DeleteConfirmation: View {
    let title: String
    let items: [StorageItem]
    /// What a single Safe or Manual item does, said in a sentence. Nil for a
    /// batch, whose rows say it themselves.
    let message: String?
    let confirmTitle: String
    let needsAdministrator: Bool
    /// Whether any item can go to the Trash, which is when the destination
    /// is the person's to choose.
    let offersDestination: Bool
    @Binding var deletesImmediately: Bool
    @Binding var showsPlan: Bool
    let plan: [String]
    let copiedPlan: Bool
    let isAuthenticating: Bool
    let onCopyPlan: () -> Void
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var totalBytes: Int64 {
        items.reduce(0) { $0 + ($1.sizeBytes ?? 0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if items.count > 1 {
                itemList
            } else if let item = items.first {
                RecoveryLabel(recovery: item.recovery)
            }
            recoverySummary
            if offersDestination {
                destination
            }
            if !plan.isEmpty {
                planSection
            }
            buttons
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(.white.opacity(0.1))
                }
                .shadow(color: .black.opacity(0.45), radius: 30, y: 12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                DepthTile(symbol: "trash.fill", tint: .red, size: 36)
                Text(title)
                    .font(.headline)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(totalBytes.byteString)
                    .font(.title2.weight(.bold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(totalBytes)))
            }
            chips
        }
    }

    /// How much thought the batch needs, at a glance.
    private var chips: some View {
        let safe = items.filter { $0.safety == .safe }.count
        let review = items.filter { $0.safety == .review }.count
        return HStack(spacing: 6) {
            if safe > 0 { chip(L("%lld safe", safe), tint: .green) }
            if review > 0 { chip(L("%lld to review", review), tint: .orange) }
            if needsAdministrator {
                chip(L("Asks for your password"), tint: .secondary, symbol: "lock.fill")
            }
        }
    }

    private func chip(_ text: String, tint: Color, symbol: String? = nil) -> some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .semibold)) }
            Text(text)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(tint.opacity(0.14), in: Capsule())
        .lineLimit(1)
    }

    // MARK: Recovery

    /// What a delete would cost someone who then goes offline: how much of
    /// it needs a network to come back, and how much nothing brings back.
    /// Said once for the batch, under the per-row labels, because that is
    /// the number they will act on.
    @ViewBuilder
    private var recoverySummary: some View {
        let needsNetwork = bytes(.downloads)
        let lost = bytes(.gone)
        if needsNetwork > 0 || lost > 0 {
            VStack(alignment: .leading, spacing: 4) {
                if needsNetwork > 0 {
                    Label(L("%@ needs an internet connection to come back.", needsNetwork.byteString),
                          systemImage: Recovery.downloads.symbol)
                }
                if lost > 0 {
                    Label(L("%@ does not come back on its own.", lost.byteString),
                          systemImage: Recovery.gone.symbol)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }

    private func bytes(_ recovery: Recovery) -> Int64 {
        items.filter { $0.recovery == recovery }.reduce(0) { $0 + ($1.sizeBytes ?? 0) }
    }

    // MARK: Items

    /// Every item in the batch, largest first, so "5 items" is never the
    /// whole of what the person is told.
    private var itemList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(items.sorted { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }) { item in
                    ConfirmationItemRow(item: item)
                }
            }
            .padding(.vertical, 4)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: min(CGFloat(items.count) * 44 + 8, 200))
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Destination

    /// Where Review items go, as two described options rather than a bare
    /// segmented control: the Trash is the undo and frees nothing until it
    /// is emptied, and the other choice is the opposite.
    private var destination: some View {
        HStack(spacing: 8) {
            DestinationOption(
                title: L("Move to the Trash"),
                caption: L("Recoverable from the Trash until you empty it. Frees nothing yet."),
                symbol: "arrow.uturn.backward.circle.fill",
                tint: .accentColor,
                isSelected: !deletesImmediately
            ) { deletesImmediately = false }
            DestinationOption(
                title: L("Delete now"),
                caption: L("Deleted for good. The space is free at once."),
                symbol: "bolt.circle.fill",
                tint: .red,
                isSelected: deletesImmediately
            ) { deletesImmediately = true }
        }
        // Both as tall as the taller caption, and no taller.
        .fixedSize(horizontal: false, vertical: true)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.75), value: deletesImmediately)
    }

    // MARK: Plan

    private var planSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button {
                    showsPlan.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .rotationEffect(.degrees(showsPlan ? 90 : 0))
                        Text(needsAdministrator
                             ? L("Show the commands that run as administrator")
                             : L("Show exactly what runs"))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Spacer()
                if showsPlan {
                    // Paths are long and the box scrolls, so reading the
                    // whole plan often means taking it somewhere else.
                    Button(action: onCopyPlan) {
                        Label(copiedPlan ? L("Copied") : L("Copy"),
                              systemImage: copiedPlan ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(copiedPlan ? Color.green : Color.accentColor)
                    .accessibilityLabel(L("Copy the plan"))
                }
            }
            .font(.caption)
            if showsPlan {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(plan.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(10)
                }
                .frame(maxHeight: 120)
                .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: showsPlan)
    }

    // MARK: Buttons

    private var buttons: some View {
        HStack(spacing: 10) {
            Button(L("Cancel"), action: onCancel)
                .buttonStyle(PanelButtonStyle(kind: .secondary))
                .keyboardShortcut(.cancelAction)
            Button(role: .destructive, action: onConfirm) {
                if isAuthenticating {
                    // The button used to go grey with no reason given,
                    // which looked like the app had stopped.
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(L("Waiting for Touch ID…"))
                    }
                } else {
                    Text(confirmTitle)
                }
            }
            .buttonStyle(PanelButtonStyle(kind: .destructive))
            .keyboardShortcut(.defaultAction)
            .disabled(isAuthenticating)
        }
    }
}

/// One item of the batch: what it is, how safe, how big.
private struct ConfirmationItemRow: View {
    let item: StorageItem

    var body: some View {
        HStack(spacing: 9) {
            CategoryIcon(category: item.category, size: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                RecoveryLabel(recovery: item.recovery)
            }
            Spacer(minLength: 6)
            Circle()
                .fill(item.safety == .safe ? Color.green : item.safety == .review ? .orange : .secondary)
                .frame(width: 6, height: 6)
                .accessibilityLabel(item.safety.label)
            Text((item.sizeBytes ?? 0).byteString)
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}

/// One of the two places Review items can go.
private struct DestinationOption: View {
    let title: String
    let caption: String
    let symbol: String
    let tint: Color
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: symbol)
                        .font(.body)
                        .foregroundStyle(isSelected ? tint : .secondary)
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: 0)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? tint : .secondary.opacity(0.5))
                }
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? tint.opacity(0.13) : Color.secondary.opacity(0.07))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(isSelected ? tint.opacity(0.7) : .white.opacity(0.08),
                                          lineWidth: isSelected ? 1.5 : 1)
                    }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityHint(caption)
    }
}

/// Buttons drawn here rather than by the system, so a delete is red whether
/// or not the panel is the key window, and it never looks like the button
/// beside it. Full width in the confirmation; `compact` sizes to the label
/// for the selection tray.
struct PanelButtonStyle: ButtonStyle {
    enum Kind { case secondary, destructive }
    let kind: Kind
    var compact = false

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(compact ? .callout.weight(.semibold) : .body.weight(.semibold))
            .foregroundStyle(kind == .destructive ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: compact ? nil : .infinity, minHeight: compact ? 28 : 34)
            .padding(.horizontal, 12)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(kind == .destructive ? AnyShapeStyle(Color.red.gradient) : AnyShapeStyle(.quaternary))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white.opacity(kind == .destructive ? 0.25 : 0.08))
            }
            .opacity(configuration.isPressed ? 0.8 : isEnabled ? 1 : 0.6)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Whether an item comes back after it is deleted, and how.
private struct RecoveryLabel: View {
    let recovery: Recovery

    var body: some View {
        Label(recovery.label, systemImage: recovery.symbol)
            .font(.caption)
            .foregroundStyle(tint)
            .lineLimit(1)
    }

    /// Green and blue for what returns, orange for what does not; grey for
    /// what nothing will miss. The symbol carries it too, for anyone who
    /// cannot tell the colours apart.
    private var tint: Color {
        switch recovery {
        case .rebuilds: .green
        case .downloads: .blue
        case .notNeeded: .secondary
        case .gone: .orange
        }
    }
}
