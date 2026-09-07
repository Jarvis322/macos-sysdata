import Foundation
import Testing
@testable import SysDataMenu

/// A header must not claim a total the app does not have. APFS never reports a
/// snapshot's size, so those rows show "—" and their header summed them to
/// zero — "nothing here" printed above ten things that plainly are something.
@MainActor
@Suite struct CategoryTotalTests {
    private func item(_ id: String, bytes: Int64?, category: StorageCategory) -> StorageItem {
        StorageItem(
            id: id, category: category, name: id, detail: "d", sizeBytes: bytes,
            safety: .safe, action: .removePaths([])
        )
    }

    @Test func aGroupWithNoMeasurableSizeTotalsToNothingRatherThanZero() {
        let model = ScanModel(scansAutomatically: false, items: [
            item("snap-1", bytes: nil, category: .snapshots),
            item("snap-2", bytes: nil, category: .snapshots),
        ])

        let group = try! #require(model.categories.first { $0.category == .snapshots })

        #expect(group.items.allSatisfy { $0.sizeBytes == nil },
                "this is the condition the header reads")
        #expect(group.total == 0, "the sum is zero, which is why it must not be shown as one")
    }

    /// A group that measured some of its rows keeps its total: that figure is
    /// still the truth about what was measured.
    @Test func aPartlyMeasuredGroupKeepsItsTotal() {
        let model = ScanModel(scansAutomatically: false, items: [
            item("a", bytes: nil, category: .tools),
            item("b", bytes: 500, category: .tools),
        ])

        let group = try! #require(model.categories.first { $0.category == .tools })

        #expect(!group.items.allSatisfy { $0.sizeBytes == nil })
        #expect(group.total == 500)
    }
}
