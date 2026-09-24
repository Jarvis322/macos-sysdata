import Foundation
import Testing
@testable import SysDataMenu

/// The daily scan used to empty the window, clear the filter and fill the
/// list again row by row, which looked like the app had quit and restarted.
/// It walks the disk twice, so it is opt-in like the other machine scans.
@MainActor
@Suite struct QuietScanTests {
    @Test(.enabled(if: MachineScan.isEnabled), .timeLimit(.minutes(30)))
    func theDailyScanKeepsTheListAndTheFilter() async {
        let model = ScanModel(scansAutomatically: false)
        await model.scan()
        guard !model.items.isEmpty else { return }
        model.filterText = "cache"

        let quiet = Task { await model.scan(quietly: true) }
        await Task.yield()
        #expect(model.isScanning)
        #expect(!model.items.isEmpty)
        await quiet.value

        #expect(model.filterText == "cache")
        #expect(!model.items.isEmpty)
    }
}
