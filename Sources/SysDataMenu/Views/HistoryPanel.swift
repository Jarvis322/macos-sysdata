import Charts
import SwiftUI

/// What the log knows, in the place the list normally sits.
///
/// Inline rather than a sheet, for the same reason the delete confirmation is:
/// the menu bar panel is not a regular window, so sheets never appear on it.
struct HistoryPanel: View {
    let log: ScanHistory.Log
    /// The category a growth notification named, if the panel was opened from one.
    var focus: StorageCategory?
    let onForget: () -> Void

    var body: some View {
        if log.scans.count < 2 && log.deletions.isEmpty {
            empty
        } else {
            VStack(spacing: 0) {
                // Outside the List: a chart has no fixed row height, and a
                // table row that sizes itself mid-layout is what sent the main
                // list into AppKit's constraint loop in #18.
                if log.scans.count >= 2 {
                    overTimeChart
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .padding(.bottom, 4)
                }
                // A scroll view of cards, not a List, for the reason the main
                // list gave one up: a self-sizing table row fell into AppKit's
                // constraint loop (#18), and rendering this one logged the
                // same reentrancy warning.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if let focus { whySection(focus) }
                        if !returned.isEmpty { returnedSection }
                        if !growth.isEmpty { growthSection }
                        if !log.deletions.isEmpty { deletionsSection }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(L("Nothing to compare yet"))
                .foregroundStyle(.secondary)
            Text(L("After a second scan this shows what grew, and whether anything you deleted came back."))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Why it grew

    /// Opened from the growth notification, so the first thing shown is its
    /// answer: which items in that category are bigger than they usually are.
    private func whySection(_ category: StorageCategory) -> some View {
        let contributors = ScanHistory.growthContributors(in: category, log: log)
        return HistoryCard {
            if contributors.isEmpty {
                Text(L("No single item stands out. Many small ones grew together."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(contributors, id: \.id) { entry in
                row(
                    entry.name,
                    detail: entry.baselineBytes.map {
                        L("Usually %@, now %@", $0.byteString, entry.currentBytes.byteString)
                    } ?? L("New: %@ now", entry.currentBytes.byteString),
                    trailing: "+\(entry.growthBytes.byteString)",
                    tint: .orange
                )
            }
        } header: {
            Text(L("Why %@ grew", category.title))
        }
    }

    // MARK: Over time

    /// System Data at each scan, and what was freed on each day: the two
    /// halves of "why is it full again" side by side.
    private var overTimeChart: some View {
        let scans = Array(log.scans.suffix(90))
        let low = Double(scans.map(\.totalBytes).min() ?? 0) * 0.97
        let freed = Dictionary(grouping: log.deletions) { Calendar.current.startOfDay(for: $0.date) }
            .map { (day: $0.key, bytes: $0.value.reduce(0) { $0 + $1.bytes }) }
            .filter { $0.day >= (scans.first?.date ?? .distantPast) }
            .sorted { $0.day < $1.day }
        return VStack(alignment: .leading, spacing: 8) {
                Text(L("Over time"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Chart(scans, id: \.date) { scan in
                    AreaMark(
                        x: .value("Date", scan.date),
                        yStart: .value("Floor", low / 1e9),
                        yEnd: .value(L("System Data"), Double(scan.totalBytes) / 1e9)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(
                        colors: [Color.accentColor.opacity(0.3), Color.accentColor.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom
                    ))
                    LineMark(x: .value("Date", scan.date), y: .value(L("System Data"), Double(scan.totalBytes) / 1e9))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine().foregroundStyle(.quaternary)
                        AxisValueLabel { if let gb = value.as(Double.self) { Text(verbatim: Int64(gb * 1e9).byteString) } }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    }
                }
                .frame(height: 96)

                if !freed.isEmpty {
                    Text(L("Freed, by day"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Chart(freed, id: \.day) { entry in
                        BarMark(
                            x: .value("Date", entry.day, unit: .day),
                            y: .value(L("Freed, by day"), Double(entry.bytes) / 1e9)
                        )
                        .foregroundStyle(Color.green.gradient)
                        .cornerRadius(2)
                    }
                    .chartYAxis {
                        AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { value in
                            // Formatted like every other size in the app: in the reader's
                            // locale, and a day that freed 300 MB no longer reads "0 GB".
                            AxisValueLabel { if let gb = value.as(Double.self) { Text(verbatim: Int64(gb * 1e9).byteString) } }
                        }
                    }
                    .chartXAxis(.hidden)
                    .frame(height: 40)
                }
            }
            .padding(12)
            .listCard()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("Over time"))
    }

    // MARK: Came back

    private var returned: [(name: String, bytes: Int64, deleted: Date, seen: Date)] {
        ScanHistory.returned(in: log)
    }

    /// The most useful thing the log can say. A cache cleared on Monday that
    /// is back by Friday is not a failed delete — it is the reason to keep
    /// the app around rather than clean once and forget.
    private var returnedSection: some View {
        HistoryCard {
            // Names repeat (two projects' node_modules), so position is the identity.
            ForEach(Array(returned.enumerated()), id: \.offset) { _, entry in
                row(
                    entry.name,
                    detail: L("Deleted %@, back by %@", Self.day(entry.deleted), Self.day(entry.seen)),
                    trailing: entry.bytes.byteString,
                    tint: .orange
                )
            }
        } header: {
            Text(L("Came back"))
        }
    }

    // MARK: Growth

    private var growth: [(name: String, bytes: Int64, since: Date)] {
        ScanHistory.fastestGrowing(in: log)
    }

    private var growthSection: some View {
        HistoryCard {
            ForEach(Array(growth.enumerated()), id: \.offset) { _, entry in
                row(
                    entry.name,
                    detail: L("Since %@", Self.day(entry.since)),
                    trailing: "+\(entry.bytes.byteString)",
                    tint: .secondary
                )
            }
        } header: {
            Text(L("Grew most"))
        }
    }

    // MARK: Deletions

    private var deletionsSection: some View {
        HistoryCard {
            // A batch shares one timestamp, so the date cannot tell its rows apart.
            ForEach(Array(log.deletions.reversed().enumerated()), id: \.offset) { _, entry in
                row(
                    entry.name,
                    detail: entry.paths.isEmpty
                        ? Self.day(entry.date)
                        : "\(Self.day(entry.date)) · \(entry.paths.joined(separator: ", "))",
                    trailing: entry.bytes.byteString,
                    tint: .secondary
                )
            }
        } header: {
            HStack {
                Text(L("Deleted"))
                Spacer()
                Button(L("Forget everything"), action: onForget)
                    .buttonStyle(.link)
                    .font(.caption)
                    .help(L("Delete the history file"))
            }
        }
    }

    // MARK: Pieces

    private func row(_ title: String, detail: String, trailing: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(trailing)
                .monospacedDigit()
                .foregroundStyle(tint)
        }
        .padding(.vertical, 2)
    }

    private static func day(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// One part of the history: a title and its rows on a card, like the list's
/// groups.
private struct HistoryCard<Content: View, Header: View>: View {
    @ViewBuilder var content: () -> Content
    @ViewBuilder var header: () -> Header

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header()
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            // Spaced rather than ruled: splitting arbitrary rows with lines
            // needs macOS 15, and this runs on 14.
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .listCard()
        }
    }
}
