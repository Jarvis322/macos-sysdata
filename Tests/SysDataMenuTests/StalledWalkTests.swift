import Foundation
import Testing
@testable import SysDataMenu

/// A directory read on a file system that stopped answering never returns.
/// The scan must give up on that one location and finish (#27), and must
/// never give up on a walk that is merely long.
@Suite struct StalledWalkTests {
    @Test(.timeLimit(.minutes(1))) func aWalkThatStopsReadingIsGivenUpOn() async {
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }

        let result = await DiskSize.watched(stallLimit: .milliseconds(600), checkEvery: .milliseconds(100)) { progress in
            progress.advance()
            // Blocked, the way a read on a dead network share is.
            release.wait()
            return 42
        }

        #expect(result == nil)
    }

    /// Slow is not stalled: a walk that keeps reading entries is waited for
    /// however long it takes.
    @Test(.timeLimit(.minutes(1))) func aSlowWalkThatKeepsReadingIsWaitedFor() async {
        let result = await DiskSize.watched(stallLimit: .milliseconds(600), checkEvery: .milliseconds(100)) { progress in
            for _ in 0..<12 {
                progress.advance()
                Thread.sleep(forTimeInterval: 0.2)
            }
            return 42
        }

        #expect(result == 42, "2.4 s of steady reading outlasts the 0.6 s limit and still finishes")
    }

    @Test func anUnansweredLocationIsListedWithoutASizeOrADelete() {
        let url = URL(fileURLWithPath: "/Volumes/share/stuck")
        let item = ProbeSupport.unansweredItem(id: "x", category: .apps, name: "stuck", url: url)

        #expect(item.sizeBytes == nil)
        #expect(item.action.isManual, "a folder nobody could measure is not offered for deletion")
        #expect(item.claimedURLs.contains(url), "the catch-all must not walk into it again")
    }
}
