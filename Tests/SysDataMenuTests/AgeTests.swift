import Foundation
import Testing
@testable import SysDataMenu

/// Size says what is big; age says what is dead. A build folder for today's
/// work and one for a project abandoned two years ago are the same number of
/// bytes and opposite decisions.
@Suite struct AgeTests {
    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "sysdata-age-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ name: String, in directory: URL, modified: Date) throws -> URL {
        let file = directory.appending(path: name)
        try Data(repeating: 0, count: 1024).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        return file
    }

    @Test func theWalkReportsTheNewestDateItSaw() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = Date.now.addingTimeInterval(-400 * 24 * 3600)
        let recent = Date.now.addingTimeInterval(-3 * 24 * 3600)
        _ = try write("old.bin", in: directory, modified: old)
        _ = try write("recent.bin", in: directory, modified: recent)

        let measured = await DiskSize.measure(at: directory)

        #expect(measured.bytes >= 2048)
        let seen = try #require(measured.lastModified)
        #expect(abs(seen.timeIntervalSince(recent)) < 2, "the newest file decides the age")
    }

    /// A pruning item deletes only what is older than its cutoff, so its age
    /// must describe that, not the recent files it would leave behind.
    @Test func excludedFilesDoNotCountTowardsTheAge() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = Date.now.addingTimeInterval(-400 * 24 * 3600)
        _ = try write("old.bin", in: directory, modified: old)
        _ = try write("today.bin", in: directory, modified: .now)

        let both = await DiskSize.measure(at: directory)
        let measured = await DiskSize.measure(at: directory, olderThan: .now.addingTimeInterval(-24 * 3600))

        // Sizes are allocated blocks, not the bytes written, so the claim is
        // that one of the two files was left out rather than an exact figure.
        #expect(measured.bytes == both.bytes / 2, "only the old file counts")
        let seen = try #require(measured.lastModified)
        #expect(abs(seen.timeIntervalSince(old)) < 2)
    }

    @Test func anEmptyDirectoryHasNoAge() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(await DiskSize.measure(at: directory).lastModified == nil)
    }

    private func item(_ id: String, bytes: Int64, daysAgo: Int?) -> StorageItem {
        StorageItem(
            id: id, category: .tools, name: id, detail: "d", sizeBytes: bytes,
            safety: .safe, action: .removePaths([]),
            lastModified: daysAgo.map { Date.now.addingTimeInterval(Double(-$0) * 24 * 3600) }
        )
    }

    @Test func recentThingsGetNoBadge() {
        #expect(item("a", bytes: 1, daysAgo: 3).idleLabel == nil, "in use is not worth saying")
        #expect(item("a", bytes: 1, daysAgo: nil).idleLabel == nil, "unmeasured is not idle")
        #expect(item("a", bytes: 1, daysAgo: 20).idleLabel != nil)
    }

    /// simctl knows when a runtime was last booted, which no file date under
    /// the disk image can tell you.
    @Test func simctlTimestampsAreUnderstood() throws {
        let parsed = try #require(RuntimeProbe.parseTimestamp("2026-09-06T18:57:10Z"))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        let expected = try #require(utc.date(from: DateComponents(
            year: 2026, month: 9, day: 6, hour: 18, minute: 57, second: 10
        )))
        #expect(parsed == expected, "the Z means UTC, not the local zone")
        // Accepted in case a future Xcode starts sending them.
        #expect(RuntimeProbe.parseTimestamp("2026-09-06T18:57:10.500Z") != nil)
        #expect(RuntimeProbe.parseTimestamp("not a date") == nil)
    }

    @MainActor
    @Test func sortingByAgePutsTheDeadestFirst() {
        let model = ScanModel(scansAutomatically: false, items: [
            item("fresh", bytes: 900, daysAgo: 1),
            item("ancient", bytes: 100, daysAgo: 800),
            item("undated", bytes: 500, daysAgo: nil),
        ])

        model.sortOrder = .age
        #expect(model.categories.first?.items.map(\.id) == ["ancient", "fresh", "undated"],
                "no date is not an age, so it sorts last rather than first")

        model.sortOrder = .size
        #expect(model.categories.first?.items.map(\.id) == ["fresh", "undated", "ancient"])
    }
}
