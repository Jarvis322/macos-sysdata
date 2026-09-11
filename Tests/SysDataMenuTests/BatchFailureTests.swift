import Foundation
import Testing
@testable import SysDataMenu

/// A batch used to report only its last failure. Two simulators failed to
/// erase in a batch that otherwise succeeded, the footer showed one line or
/// none, and the rows came back on the next scan as if the app had ignored
/// the click.
@Suite struct BatchFailureTests {
    @MainActor
    @Test func everyFailureInABatchIsReported() async throws {
        let failing = ReclaimAction.command(executable: "/usr/bin/false", arguments: [])
        let items = ["First", "Second"].map {
            StorageItem(
                id: "test-\($0)", category: .other, name: $0, detail: "test",
                sizeBytes: 1, safety: .safe, action: failing
            )
        }
        let model = ScanModel(scansAutomatically: false, items: items)
        await model.reclaim(items)
        let message = try #require(model.errorMessage)
        #expect(message.contains("First") && message.contains("Second"))
    }

    /// Erasing one device must not shut down every simulator the person has
    /// open, and the plan must show both commands before they run.
    @Test func erasingASimulatorShutsOnlyThatOneDown() {
        let action = ReclaimAction.eraseSimulator(udid: "ABC")
        #expect(action.plan == ["/usr/bin/xcrun simctl shutdown ABC", "/usr/bin/xcrun simctl erase ABC"])
        #expect(!action.needsAdministrator)
        #expect(action.paths.isEmpty)
    }
}
