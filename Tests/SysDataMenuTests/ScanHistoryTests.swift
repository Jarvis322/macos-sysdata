import Foundation
import Testing
@testable import SysDataMenu

/// The log exists to answer questions a single scan cannot: what grew, and
/// whether what you deleted came back.
@Suite struct ScanHistoryTests {
    private func item(_ id: String, bytes: Int64) -> StorageItem {
        StorageItem(
            id: id, category: .tools, name: id.capitalized, detail: "d",
            sizeBytes: bytes, safety: .safe,
            action: .removePaths([URL(fileURLWithPath: "/tmp/\(id)")])
        )
    }

    private func day(_ offset: Int) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(Double(offset) * 24 * 3600)
    }

    private func log(_ scans: [ScanHistory.Scan], _ deletions: [ScanHistory.Deletion] = []) -> ScanHistory.Log {
        ScanHistory.Log(scans: scans, deletions: deletions)
    }

    private func scan(
        _ date: Date,
        _ sizes: [String: Int64],
        categories: [String: String] = [:]
    ) -> ScanHistory.Scan {
        ScanHistory.Scan(
            date: date, totalBytes: sizes.values.reduce(0, +), freeBytes: 0,
            sizes: sizes,
            names: sizes.keys.reduce(into: [:]) { $0[$1] = $1.capitalized },
            categories: categories
        )
    }

    @Test func changeNeedsTwoScansThatBothKnewTheItem() {
        #expect(ScanHistory.change(forItem: "npm", in: log([scan(day(0), ["npm": 100])])) == nil,
                "one scan is not a comparison")

        let grew = log([scan(day(0), ["npm": 100]), scan(day(1), ["npm": 340])])
        #expect(ScanHistory.change(forItem: "npm", in: grew) == 240)

        let shrank = log([scan(day(0), ["npm": 340]), scan(day(1), ["npm": 100])])
        #expect(ScanHistory.change(forItem: "npm", in: shrank) == -240)

        let newcomer = log([scan(day(0), ["yarn": 10]), scan(day(1), ["npm": 100, "yarn": 10])])
        #expect(ScanHistory.change(forItem: "npm", in: newcomer) == nil,
                "an item the previous scan never saw has no change, which is not zero")
    }

    @Test func fastestGrowingMeasuresFromTheOldestScanThatKnewTheItem() {
        let history = log([
            scan(day(0), ["npm": 100, "docker": 1_000]),
            scan(day(1), ["npm": 200, "docker": 1_100]),
            scan(day(2), ["npm": 900, "docker": 1_200]),
        ])

        let growth = ScanHistory.fastestGrowing(in: history)

        #expect(growth.map(\.name) == ["Npm", "Docker"], "800 beats 200")
        #expect(growth.first?.bytes == 800)
        #expect(growth.first?.since == day(0))
    }

    @Test func thingsThatShrankAreNotGrowth() {
        let history = log([scan(day(0), ["npm": 900]), scan(day(1), ["npm": 100])])
        #expect(ScanHistory.fastestGrowing(in: history).isEmpty)
    }

    @Test func unusualCategoryGrowthNeedsAStableLargeIncrease() {
        let gigabyte: Int64 = 1_073_741_824
        let categories = ["derived": StorageCategory.xcode.rawValue]
        let history = log([
            scan(day(0), ["derived": 4 * gigabyte], categories: categories),
            scan(day(1), ["derived": 4 * gigabyte], categories: categories),
            scan(day(2), ["derived": 5 * gigabyte], categories: categories),
            scan(day(3), ["derived": 12 * gigabyte], categories: categories),
        ])

        let anomaly = ScanHistory.unusualCategoryGrowth(in: history).first

        #expect(anomaly?.category == .xcode)
        #expect(anomaly?.growthBytes == 8 * gigabyte)
    }

    @Test func unusualCategoryGrowthIgnoresOlderScansWithoutCategories() {
        let gigabyte: Int64 = 1_073_741_824
        let history = log([
            scan(day(0), ["derived": 4 * gigabyte]),
            scan(day(1), ["derived": 4 * gigabyte]),
            scan(day(2), ["derived": 4 * gigabyte]),
            scan(day(3), ["derived": 12 * gigabyte], categories: ["derived": StorageCategory.xcode.rawValue]),
        ])

        #expect(ScanHistory.unusualCategoryGrowth(in: history).isEmpty)
    }

    @Test func earlierHistoryWithoutCategoriesStillDecodes() throws {
        let legacyHistory = """
        {"scans":[{"date":"2023-11-14T22:13:20Z","totalBytes":1,"freeBytes":2,"sizes":{"npm":1},"names":{"npm":"Npm"}}],"deletions":[]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let history = try decoder.decode(ScanHistory.Log.self, from: Data(legacyHistory.utf8))

        #expect(history.scans.first?.categories.isEmpty == true)
    }

    /// The log's most useful answer: a cache cleared on Monday that is back by
    /// Friday.
    @Test func aDeletedItemFoundAgainLaterCountsAsReturned() {
        let deletion = ScanHistory.Deletion(
            date: day(1), itemID: "derived", name: "DerivedData",
            category: "xcode", paths: ["/tmp/derived"], bytes: 12_000
        )
        let history = log([
            scan(day(0), ["derived": 12_000]),
            scan(day(2), ["derived": 8_000]),
            scan(day(4), ["derived": 9_500]),
        ], [deletion])

        let returned = ScanHistory.returned(in: history)

        #expect(returned.count == 1)
        #expect(returned.first?.name == "DerivedData")
        #expect(returned.first?.bytes == 9_500, "the latest scan is what it is now")
        #expect(returned.first?.seen == day(4))
    }

    @Test func somethingDeletedAndStillGoneIsNotReturned() {
        let deletion = ScanHistory.Deletion(
            date: day(1), itemID: "derived", name: "DerivedData",
            category: "xcode", paths: [], bytes: 12_000
        )
        let history = log([scan(day(0), ["derived": 12_000]), scan(day(2), ["npm": 5])], [deletion])
        #expect(ScanHistory.returned(in: history).isEmpty)
    }

    /// A scan taken before the deletion must not be read as the item coming
    /// back, or every delete would report itself as futile.
    @Test func onlyScansAfterTheDeletionCount() {
        let deletion = ScanHistory.Deletion(
            date: day(5), itemID: "derived", name: "DerivedData",
            category: "xcode", paths: [], bytes: 12_000
        )
        let history = log([scan(day(0), ["derived": 12_000])], [deletion])
        #expect(ScanHistory.returned(in: history).isEmpty)
    }

    @Test func theFileSurvivesARoundTrip() throws {
        let log = log(
            [scan(day(0), ["npm": 100])],
            [ScanHistory.Deletion(date: day(1), itemID: "npm", name: "Npm",
                                  category: "tools", paths: ["/tmp/npm"], bytes: 100)]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let restored = try decoder.decode(ScanHistory.Log.self, from: encoder.encode(log))

        #expect(restored.scans.first?.sizes == ["npm": 100])
        #expect(restored.deletions.first?.paths == ["/tmp/npm"])
        #expect(restored.deletions.first?.date == day(1))
    }
}
