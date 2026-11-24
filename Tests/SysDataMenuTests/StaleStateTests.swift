import Foundation
import Testing
@testable import SysDataMenu

/// State that outlived what it described: a plan with nothing in it, rows
/// hidden along with a parent, and a Compose project claiming its folder.
@MainActor
@Suite(.serialized) struct StaleStateTests {
    private func item(
        _ id: String, bytes: Int64 = 1, category: StorageCategory = .tools,
        hiddenWith: String? = nil, revealURL: URL? = nil, project: URL? = nil
    ) -> StorageItem {
        StorageItem(
            id: id, category: category, name: id, detail: "detail",
            sizeBytes: bytes, safety: .safe, action: .manual("by hand"),
            revealURL: revealURL, project: project, hiddenWith: hiddenWith
        )
    }

    @Test func anEmptyPlanEndsWhenTheSelectionIsCleared() {
        let model = ScanModel(scansAutomatically: false, items: [])
        model.selectedIDs = []
        model.planSpace(freeing: 100 * 1_073_741_824)
        #expect(model.activeSpacePlan != nil)

        model.clearSelection()

        #expect(model.activeSpacePlan == nil)
    }

    @Test func aPlanDoesNotComeBackWhenTheSelectionReturnsToMatchIt() {
        let cache = StorageItem(
            id: "a", category: .tools, name: "a", detail: "detail",
            sizeBytes: 5, safety: .safe, action: .removePaths([URL(fileURLWithPath: "/tmp/a")])
        )
        let model = ScanModel(scansAutomatically: false, items: [cache])
        model.selectedIDs = []
        model.planSpace(freeing: 100 * 1_073_741_824)
        let planned = model.selectedIDs
        #expect(planned == ["a"])

        model.selectedIDs = []
        model.selectedIDs = planned

        #expect(model.activeSpacePlan == nil)
    }

    @Test func hidingAParentDeselectsTheRowsHiddenWithIt() {
        let model = ScanModel(scansAutomatically: false, items: [
            item("store"), item("model-a", hiddenWith: "store"), item("other"),
        ])
        model.selectedIDs = ["model-a", "other"]
        defer { model.unhideAll() }

        model.hide(model.items[0])

        #expect(model.selectedIDs == ["other"])
    }

    @Test func aComposeProjectDoesNotClaimItsFolder() {
        let folder = URL(fileURLWithPath: "/Users/someone/code/app")
        let compose = item("docker-project-app", category: .docker, revealURL: folder, project: folder)
        let engine = item("docker-images", category: .docker, revealURL: URL(fileURLWithPath: "/vms"))

        #expect(compose.claimedURLs.isEmpty)
        #expect(engine.claimedURLs == [URL(fileURLWithPath: "/vms")])
    }
}
