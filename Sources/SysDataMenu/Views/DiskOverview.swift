import Charts
import SwiftUI

/// The top of the list: the one number the person can act on, the whole disk
/// as a ring so that number has a scale, and where System Data has been
/// heading.
///
/// The ring is drawn against the volume's capacity, not against System Data,
/// because "how much of my disk is this" is the question people open the app
/// with. System Data is split by how much thought deleting it needs, in the
/// same green, orange and grey as the badges; everything else on the disk is
/// one quiet part, and free space is the faint remainder.
struct DiskOverview: View {
    let safe: Int64
    let review: Int64
    let manual: Int64
    let free: Int64
    let capacity: Int64
    let purgeable: Int64
    /// The line under the trend: System Data, free space and the weekly change.
    let pulse: String
    let showsGrowthArrow: Bool
    let allSafeSelected: Bool
    let canSelectSafe: Bool
    let onSelectSafe: () -> Void
    /// Asked for from the "Free up…" menu: how much space is wanted.
    var onPlan: (Int64) -> Void = { _ in }
    /// Off while a scan is filling the list: a plan built from half a list
    /// counts overlapping rows the finished scan drops, or misses items.
    var canPlan = true
    /// What the last delete gave back, shown for a few seconds in the middle
    /// of the ring. Nil the rest of the time.
    var justFreed: Int64?
    /// System Data at each recent scan, oldest first. Under two, no trend.
    var trend: [Int64] = []

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: Slice?
    /// 0 when the card first appears, 1 once the ring and the trend have drawn
    /// themselves in. Straight to 1 under Reduce Motion.
    @State private var progress: Double = 0

    /// The parts of the ring, so pointing at one in the legend can bring that
    /// part forward and let the others recede.
    private enum Slice: Hashable { case safe, review, manual, other, free }

    private struct Part: Identifiable {
        let slice: Slice
        let bytes: Int64
        var id: Slice { slice }
    }

    private static let otherColor = Color.gray.opacity(0.45)

    /// What people actually need room for: an update, a project, a recording.
    private static let planTargets: [Int64] = [5, 10, 20, 50, 100].map { $0 * 1_000_000_000 }

    private var other: Int64 {
        max(capacity - free - safe - review - manual, 0)
    }

    private var parts: [Part] {
        [
            Part(slice: .safe, bytes: safe), Part(slice: .review, bytes: review),
            Part(slice: .manual, bytes: manual), Part(slice: .other, bytes: other),
            Part(slice: .free, bytes: free),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                ring
                    .frame(width: 128, height: 128)
                VStack(alignment: .leading, spacing: 10) {
                    actions
                    legend
                }
            }
            trendStrip
        }
        .padding(14)
        .background {
            // A wash of green at the corner the ring sits in, fading to the
            // usual card: the number in it is what this card is for.
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.quaternary.opacity(0.35))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(LinearGradient(
                            colors: [.green.opacity(safe > 0 ? 0.13 : 0.04), .clear],
                            startPoint: .topLeading, endPoint: .center
                        ))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.09))
                }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8), value: justFreed)
        .onAppear {
            guard progress == 0 else { return }
            if reduceMotion {
                progress = 1
            } else {
                withAnimation(.spring(response: 1.1, dampingFraction: 0.9).delay(0.1)) { progress = 1 }
            }
        }
    }

    // MARK: Ring

    private var ring: some View {
        ZStack {
            Chart {
                ForEach(parts) { part in
                    SectorMark(
                        angle: .value("Bytes", Double(part.bytes) * progress),
                        innerRadius: .ratio(0.7),
                        angularInset: 1.2
                    )
                    .cornerRadius(3)
                    .foregroundStyle(style(for: part.slice))
                    .opacity(dimmed(part.slice) ? 0.25 : 1)
                }
                // The part of the circle not drawn yet, so the ring sweeps in
                // from the top instead of popping into place.
                SectorMark(angle: .value("Bytes", Double(max(capacity, 1)) * (1 - progress)), innerRadius: .ratio(0.7))
                    .foregroundStyle(.clear)
            }
            .chartLegend(.hidden)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovered)
            .animation(reduceMotion ? nil : .smooth(duration: 0.5), value: [safe, review, manual, free])

            VStack(spacing: 1) {
                if let justFreed {
                    Label(L("Freed %@", justFreed.byteString), systemImage: "sparkles")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.green)
                        .symbolEffect(.bounce, value: justFreed)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
                }
                Text(safe.byteString)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.green)
                    .contentTransition(.numericText(value: Double(safe)))
                    .minimumScaleFactor(0.6)
                Text(L("safe to free now"))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .lineLimit(1)
            .frame(width: 80)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("%@ safe · %@ to review · %@ manual",
                              safe.byteString, review.byteString, manual.byteString))
    }

    private func style(for slice: Slice) -> AnyShapeStyle {
        switch slice {
        case .safe: AnyShapeStyle(Color.green.gradient)
        case .review: AnyShapeStyle(Color.orange.gradient)
        case .manual: AnyShapeStyle(Color.secondary.gradient)
        case .other: AnyShapeStyle(Self.otherColor)
        case .free: AnyShapeStyle(Color.secondary.opacity(0.08))
        }
    }

    /// Something is pointed at and this is not it.
    private func dimmed(_ slice: Slice) -> Bool {
        hovered != nil && hovered != slice
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 8) {
            Button(allSafeSelected ? L("Deselect safe") : L("Select safe"), action: onSelectSafe)
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(!canSelectSafe)
                .help(L("Select every item that is regenerated automatically"))
            Menu {
                ForEach(Self.planTargets, id: \.self) { bytes in
                    Button(L("Free up %@", bytes.byteString)) { onPlan(bytes) }
                }
            } label: {
                Label(L("Free up…"), systemImage: "target")
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()
            .disabled(!canPlan)
            .help(L("Selects the least worrying items that add up to this much. Nothing is deleted until you confirm."))
        }
    }

    // MARK: Legend

    /// One row per part of the ring, the figure at the end of its line, so the
    /// labels never have to be cut to fit.
    private var legend: some View {
        VStack(alignment: .leading, spacing: 3) {
            key(L("Safe"), safe, .green, slice: .safe)
            key(L("Review"), review, .orange, slice: .review)
            key(L("Manual"), manual, .secondary, slice: .manual)
            key(L("Other files"), other, Self.otherColor, slice: .other)
            key(L("Free"), free, .clear, slice: .free, outlined: true,
                note: purgeable > 0 ? L("%@ purgeable", purgeable.byteString) : nil)
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

    private func key(_ title: String, _ bytes: Int64, _ color: Color, slice: Slice, outlined: Bool = false, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(color)
                    .overlay {
                        if outlined {
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous).strokeBorder(.secondary, lineWidth: 1)
                        }
                    }
                    .frame(width: 9, height: 9)
                Text(title)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Text(bytes.byteString)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
            }
            .font(.caption)
            if let note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 15)
            }
        }
        .lineLimit(1)
        .opacity(dimmed(slice) ? 0.4 : 1)
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? slice : (hovered == slice ? nil : hovered) }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovered)
        .accessibilityElement(children: .combine)
    }

    // MARK: Trend

    /// System Data over the recent scans, drawn left to right. Orange when it
    /// ended higher than it started, green when lower: the direction is the
    /// news, the exact figures are in the line under it.
    @ViewBuilder
    private var trendStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            if trend.count >= 2, let low = trend.min(), let high = trend.max() {
                let tint: Color = (trend.last ?? 0) > (trend.first ?? 0) ? .orange : .green
                let floor = Double(low) * 0.97
                let ceiling = Double(max(high, low + 1)) * 1.01
                Chart(Array(trend.enumerated()), id: \.offset) { index, bytes in
                    AreaMark(
                        x: .value("Scan", index),
                        yStart: .value("Floor", floor),
                        yEnd: .value("System Data", Double(bytes))
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(LinearGradient(
                        colors: [tint.opacity(0.32), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom
                    ))
                    LineMark(x: .value("Scan", index), y: .value("System Data", Double(bytes)))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(tint)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartYScale(domain: floor...ceiling)
                .chartXScale(domain: 0...(trend.count - 1))
                .frame(height: 34)
                // Drawn in from the left, once, with the ring.
                .mask(alignment: .leading) {
                    GeometryReader { geometry in
                        Rectangle().frame(width: geometry.size.width * progress)
                    }
                }
                .accessibilityHidden(true)
            }
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
    }
}
