import Foundation
import Testing
@testable import SysDataMenu

/// The folded list is meant to read as a map of the disk, and its amber mark
/// is meant to flag growth that is actually unusual. These pin both.
@Suite struct CategoryAtlasTests {
    private let gigabyte: Int64 = 1_073_741_824

    private func scan(_ day: Int, _ bytes: Int64) -> ScanHistory.Scan {
        ScanHistory.Scan(
            date: Date(timeIntervalSince1970: Double(day) * 86_400), totalBytes: bytes, freeBytes: 0,
            sizes: ["derived": bytes], names: ["derived": "DerivedData"],
            categories: ["derived": StorageCategory.xcode.rawValue]
        )
    }

    /// Small for five months, then bigger for good a month ago: that is its
    /// size now, not an anomaly. Against the whole history's median it read
    /// as a 5 GB jump every day.
    @Test func theBaselineIsRecentNotLifetime() {
        let scans = (0..<150).map { scan($0, 1 * gigabyte) } + (150..<181).map { scan($0, 6 * gigabyte) }
        #expect(ScanHistory.unusualCategoryGrowth(in: ScanHistory.Log(scans: scans, deletions: [])).isEmpty)
    }

    @Test func aJumpOverTheRecentBaselineIsStillReported() {
        let scans = (0..<20).map { scan($0, 4 * gigabyte) } + [scan(20, 12 * gigabyte)]
        let growth = ScanHistory.unusualCategoryGrowth(in: ScanHistory.Log(scans: scans, deletions: []))
        #expect(growth.first?.growthBytes == 8 * gigabyte)
    }

    @MainActor
    @Test func categoriesAreListedLargestFirst() {
        func item(_ id: String, _ category: StorageCategory, _ bytes: Int64) -> StorageItem {
            StorageItem(
                id: "atlas-\(id)", category: category, name: id, detail: "test",
                sizeBytes: bytes, safety: .safe, action: .removePaths([])
            )
        }
        let model = ScanModel(scansAutomatically: false, items: [
            item("a", .snapshots, 1), item("b", .xcode, 3), item("c", .packages, 2),
        ])
        #expect(model.categories.map(\.category) == [.xcode, .packages, .snapshots])
    }
}
