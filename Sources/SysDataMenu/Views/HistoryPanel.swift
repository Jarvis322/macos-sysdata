import SwiftUI

/// What the log knows, in the place the list normally sits.
///
/// Inline rather than a sheet, for the same reason the delete confirmation is:
/// the menu bar panel is not a regular window, so sheets never appear on it.
struct HistoryPanel: View {
    let log: ScanHistory.Log
    let onForget: () -> Void

    var body: some View {
        if log.scans.count < 2 && log.deletions.isEmpty {
            empty
        } else {
            List {
                if !returned.isEmpty { returnedSection }
                if !growth.isEmpty { growthSection }
                if !log.deletions.isEmpty { deletionsSection }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
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

    // MARK: Came back

    private var returned: [(name: String, bytes: Int64, deleted: Date, seen: Date)] {
        ScanHistory.returned(in: log)
    }

    /// The most useful thing the log can say. A cache cleared on Monday that
    /// is back by Friday is not a failed delete — it is the reason to keep
    /// the app around rather than clean once and forget.
    private var returnedSection: some View {
        Section {
            ForEach(returned, id: \.name) { entry in
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
        Section {
            ForEach(growth, id: \.name) { entry in
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
        Section {
            ForEach(log.deletions.reversed(), id: \.date) { entry in
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
