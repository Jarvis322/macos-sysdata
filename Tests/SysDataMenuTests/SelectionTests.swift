import Foundation
import Testing
@testable import SysDataMenu

/// A selection must never hold rows the person cannot see: whatever "Delete N
/// selected" acts on has to be on screen when they press it.
@MainActor
@Suite struct SelectionTests {
    private func item(_ name: String, category: StorageCategory = .tools) -> StorageItem {
        StorageItem(
            id: name, category: category, name: name, detail: "detail",
            sizeBytes: 1, safety: .safe, action: .removePaths([URL(fileURLWithPath: "/tmp/\(name)")])
        )
    }

    private func model(_ items: [StorageItem]) -> ScanModel {
        let model = ScanModel(scansAutomatically: false, items: items)
        model.filterText = ""
        model.selectedIDs = []
        return model
    }

    @Test func theCategoryCheckboxSkipsRowsTheFilterHides() {
        let model = model([item("npm cache"), item("yarn cache")])
        model.filterText = "npm"

        model.setSelection(.tools, selected: true)

        #expect(model.selectedIDs == ["npm cache"])
    }

    @Test func theCategoryCheckboxIsTickedWhenEveryListedRowIs() {
        let model = model([item("npm cache"), item("yarn cache")])
        model.filterText = "npm"
        model.selectedIDs = ["npm cache"]

        // "yarn cache" is unselected but off screen, so the header reads as
        // ticked for what it actually covers.
        #expect(model.isCategorySelected(.tools))
    }

    @Test func aCategoryWithNothingListedHasNothingToSelect() {
        let model = model([item("npm cache")])
        model.filterText = "docker"

        #expect(!model.categoryHasSelectableItems(.tools))
    }

    @Test func collapsingACategoryDropsItsSelection() {
        let model = model([item("npm cache"), item("Xcode archives", category: .xcode)])
        model.selectedIDs = ["npm cache", "Xcode archives"]

        model.deselect(.tools)

        #expect(model.selectedIDs == ["Xcode archives"])
    }
}
