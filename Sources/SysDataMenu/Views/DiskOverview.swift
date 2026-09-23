import SwiftUI

/// The top of the list: the one number the person can act on, and the whole
/// disk as a single bar so that number has a scale.
///
/// The bar is drawn against the volume's capacity, not against System Data,
/// because "how much of my disk is this" is the question people open the app
/// with. System Data is split by how much thought deleting it needs, in the
/// same green, orange and grey as the badges; everything else on the disk is
/// one quiet segment, and free space is left open.
struct DiskOverview: View {
    let safe: Int64
    let review: Int64
    let manual: Int64
    let free: Int64
    let capacity: Int64
    let purgeable: Int64
    /// The line under the bar: System Data, free space and the weekly change.
    let pulse: String
    let showsGrowthArrow: Bool
    let allSafeSelected: Bool
    let canSelectSafe: Bool
    let onSelectSafe: () -> Void

    private static let otherColor = Color.gray.opacity(0.45)

    private var other: Int64 {
        max(capacity - free - safe - review - manual, 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(safe.byteString)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.green)
                        .contentTransition(.numericText(value: Double(safe)))
                    Text(L("safe to free now"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(allSafeSelected ? L("Deselect safe") : L("Select safe"), action: onSelectSafe)
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(!canSelectSafe)
                    .help(L("Select every item that is regenerated automatically"))
            }

            bar
                .frame(height: 10)

            legend

            HStack(spacing: 4) {
                if showsGrowthArrow {
                    Image(systemName: "arrow.up.right")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                }
                Text(pulse)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary.opacity(0.35))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.08))
                }
        }
    }

    private var bar: some View {
        GeometryReader { geometry in
            let whole = CGFloat(max(capacity, 1))
            let gap: CGFloat = 2
            let parts: [(Int64, AnyShapeStyle)] = [
                (safe, AnyShapeStyle(.green)),
                (review, AnyShapeStyle(.orange)),
                (manual, AnyShapeStyle(.secondary)),
                (other, AnyShapeStyle(Self.otherColor)),
            ].filter { $0.0 > 0 }
            let room = geometry.size.width - gap * CGFloat(parts.count)
            HStack(spacing: gap) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    Capsule()
                        .fill(part.1)
                        .frame(width: max(room * CGFloat(part.0) / whole, 3))
                }
                Spacer(minLength: 0)
            }
            .background(Capsule().strokeBorder(.quaternary, lineWidth: 1))
        }
        .accessibilityElement()
        .accessibilityLabel(L("%@ safe · %@ to review · %@ manual",
                              safe.byteString, review.byteString, manual.byteString))
    }

    /// Five equal columns, the figure under its label: on one line the
    /// labels were cut to "Revi…" at the panel's width.
    private var legend: some View {
        HStack(alignment: .top, spacing: 6) {
            key(L("Safe"), safe, .green)
            key(L("Review"), review, .orange)
            key(L("Manual"), manual, .secondary)
            key(L("Other files"), other, Self.otherColor)
            key(L("Free"), free, .clear, outlined: true, note: purgeable > 0 ? L("%@ purgeable", purgeable.byteString) : nil)
                // The purgeable figure is the one number here nobody can act
                // on, and the one people meet in Finder wondering why free
                // space they can see will not open a file. Measured on this
                // Mac: writing 6.44 GB cost 6.44 GB of real free space and
                // took nothing from the pool, which then refilled itself. See
                // docs/purgeable-measurement.md.
                .help(purgeable > 0
                      ? L("Purgeable is what macOS estimates it could give back if it had to: caches and local snapshots. It is an estimate, not space you can count on — it moves on its own, and writing a file does not spend it. The items below are the ones you can actually free.")
                      : L("Free space on the startup disk."))
        }
        .monospacedDigit()
    }

    private func key(_ title: String, _ bytes: Int64, _ color: Color, outlined: Bool = false, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .overlay { if outlined { Circle().strokeBorder(.secondary, lineWidth: 1) } }
                    .frame(width: 7, height: 7)
                Text(title)
                    .foregroundStyle(.secondary)
            }
            .font(.caption2)
            Text(bytes.byteString)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
            if let note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
