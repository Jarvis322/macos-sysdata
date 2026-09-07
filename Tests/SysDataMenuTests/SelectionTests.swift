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

    @Test func selectSafeTicksEveryListedSafeRow() {
        let model = model([item("npm cache"), item("yarn cache")])

        model.selectAllSafe()

        #expect(model.selectedIDs == ["npm cache", "yarn cache"])
        #expect(model.everyListedSafeItemIsSelected)
    }

    @Test func selectSafeUnticksWhenEverythingListedIsAlreadyTicked() {
        // The button undoes itself; reaching for Clear to undo one press was a
        // detour, and Clear also drops selections the person made by hand.
        let model = model([item("npm cache"), item("yarn cache")])
        model.selectAllSafe()

        model.selectAllSafe()

        #expect(model.selectedIDs.isEmpty)
    }

    @Test func selectSafeLeavesRowsTheFilterHidesAlone() {
        let model = model([item("npm cache"), item("yarn cache")])
        model.selectedIDs = ["yarn cache"]
        model.filterText = "npm"

        model.selectAllSafe()

        // yarn was ticked before the filter and stays ticked; npm is added.
        #expect(model.selectedIDs == ["npm cache", "yarn cache"])
        // And unticking only takes back what is listed.
        model.selectAllSafe()
        #expect(model.selectedIDs == ["yarn cache"])
    }

    @Test func theFooterCountsSelectedRowsTheFilterIsHiding() {
        let model = model([item("npm cache"), item("yarn cache")])
        model.selectedIDs = ["npm cache", "yarn cache"]

        model.filterText = "npm"

        #expect(model.selectedOffScreenCount == 1)
        #expect(model.selectedItems.count == 2, "the batch still holds both")
    }

    @Test func nothingIsOffScreenWithoutAFilterOrAFold() {
        let model = model([item("npm cache"), item("yarn cache")])
        model.selectedIDs = ["npm cache", "yarn cache"]

        #expect(model.selectedOffScreenCount == 0)
    }

    /// A fold and a filter do the same thing to a row, so they answer for it
    /// the same way: the selection stands and the footer counts it.
    @Test func foldingACategoryKeepsItsSelectionAndCountsIt() {
        let model = model([item("npm cache"), item("Xcode archives", category: .xcode)])
        model.selectedIDs = ["npm cache", "Xcode archives"]

        model.collapsedCategories = [.tools]

        #expect(model.selectedIDs == ["npm cache", "Xcode archives"], "the batch is not edited by a fold")
        #expect(model.selectedOffScreenCount == 1)
        #expect(model.selectedItems.count == 2)
    }

    @Test func selectSafeLeavesAFoldedCategoryAlone() {
        let model = model([item("npm cache"), item("Xcode archives", category: .xcode)])
        model.collapsedCategories = [.xcode]

        model.selectAllSafe()

        #expect(model.selectedIDs == ["npm cache"], "a folded row is not ticked behind the person's back")
        #expect(model.selectedOffScreenCount == 0)
    }

    @Test func unfoldingBringsTheCountBackToZero() {
        let model = model([item("npm cache"), item("Xcode archives", category: .xcode)])
        model.selectedIDs = ["npm cache", "Xcode archives"]
        model.collapsedCategories = [.xcode]
        #expect(model.selectedOffScreenCount == 1)

        model.collapsedCategories = []

        #expect(model.selectedOffScreenCount == 0)
        #expect(model.selectedIDs == ["npm cache", "Xcode archives"])
    }
}
