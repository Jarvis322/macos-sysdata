import SwiftUI
import WidgetKit
import WidgetSnapshot

/// System Data at a glance on the desktop or in Notification Center, as of
/// the app's last scan. It measures nothing itself: a widget is sandboxed and
/// cannot walk the disk, so it shows what the app last found and says when.
@main
struct SysDataWidgets: WidgetBundle {
    var body: some Widget {
        SystemDataWidget()
    }
}

struct SystemDataWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshot.widgetKind, provider: SnapshotProvider()) { entry in
            SnapshotView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("System Data")
        .description("How much System Data there is, and how much of it is safe to free.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: .now, snapshot: WidgetSnapshot(
            systemDataBytes: 96_000_000_000, freeBytes: 28_000_000_000, safeBytes: 6_000_000_000,
            capacityBytes: 245_000_000_000, scannedAt: .now
        ))
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : SnapshotEntry(date: .now, snapshot: WidgetSnapshot.load()))
    }

    /// The app reloads the timeline after every scan; the hourly refresh is
    /// only there so the "scanned … ago" line does not go stale.
    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let entry = SnapshotEntry(date: .now, snapshot: WidgetSnapshot.load())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(3_600))))
    }
}

struct SnapshotView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let snapshot = entry.snapshot {
            switch family {
            case .systemMedium: medium(snapshot)
            default: small(snapshot)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Label("System Data", systemImage: "internaldrive")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("Open System Data Unpacked once to see the numbers here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func small(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("System Data", systemImage: "internaldrive")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(bytes(snapshot.systemDataBytes))
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .minimumScaleFactor(0.7)
            Text("\(bytes(snapshot.freeBytes)) free")
                .font(.caption)
                .foregroundStyle(.secondary)
            if snapshot.safeBytes > 0 {
                Text("\(bytes(snapshot.safeBytes)) safe to free")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            scanned(snapshot)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func medium(_ snapshot: WidgetSnapshot) -> some View {
        HStack(alignment: .top, spacing: 16) {
            small(snapshot)
            VStack(alignment: .leading, spacing: 6) {
                Text("Disk")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                // Used, of which System Data, and free: the same three things
                // the app's header says, drawn at a glance.
                let capacity = max(snapshot.capacityBytes, 1)
                let systemData = Double(snapshot.systemDataBytes) / Double(capacity)
                let free = Double(snapshot.freeBytes) / Double(capacity)
                GeometryReader { proxy in
                    HStack(spacing: 0) {
                        Rectangle().fill(.orange).frame(width: proxy.size.width * systemData)
                        Rectangle().fill(.secondary.opacity(0.4))
                        Rectangle().fill(.green).frame(width: proxy.size.width * free)
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 8)
                .accessibilityLabel("\(bytes(snapshot.systemDataBytes)) System Data, \(bytes(snapshot.freeBytes)) free")
                Spacer(minLength: 0)
                Text("\(bytes(snapshot.capacityBytes)) disk")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func scanned(_ snapshot: WidgetSnapshot) -> some View {
        Text("Scanned \(snapshot.scannedAt, style: .relative) ago")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
