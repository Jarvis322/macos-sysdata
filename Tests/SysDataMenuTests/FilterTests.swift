import Foundation
import Testing
@testable import SysDataMenu

@Suite struct FilterTests {
    private func item(name: String, detail: String = "detail", category: StorageCategory = .tools) -> StorageItem {
        StorageItem(
            id: "id-\(name)", category: category, name: name, detail: detail,
            sizeBytes: 1, safety: .safe, action: .removePaths([])
        )
    }

    @Test func anEmptyFilterKeepsEverything() {
        #expect(item(name: "npm cache").matches(filter: ""))
        #expect(item(name: "npm cache").matches(filter: "   "))
    }

    @Test func matchesNameDetailAndCategoryTitle() {
        let simulator = item(name: "iOS 26.5", detail: "Downloaded runtime.", category: .runtimes)
        #expect(simulator.matches(filter: "26.5"), "name")
        #expect(simulator.matches(filter: "downloaded"), "detail")
        #expect(simulator.matches(filter: "simulator runtimes"), "category title")
        #expect(!simulator.matches(filter: "docker"))
    }

    @Test func ignoresCaseAndSurroundingSpace() {
        let npm = item(name: "npm cache")
        #expect(npm.matches(filter: "NPM"))
        #expect(npm.matches(filter: "  npm  "))
    }

    @MainActor
    @Test func changingTheFilterClearsTheSelection() {
        // Otherwise "Delete N selected" would still act on rows the filter has
        // taken off screen.
        let model = ScanModel(scansAutomatically: false)
        model.selectedIDs = ["one", "two"]

        model.filterText = "npm"

        #expect(model.selectedIDs.isEmpty)
    }

    @MainActor
    @Test func rewritingTheSameFilterKeepsTheSelection() {
        let model = ScanModel(scansAutomatically: false)
        model.filterText = "npm"
        model.selectedIDs = ["one"]

        model.filterText = "npm"

        #expect(model.selectedIDs == ["one"])
    }
}
