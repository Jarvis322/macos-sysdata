import Foundation
import Testing
@testable import SysDataMenu

/// Deletes that reported success without freeing anything, and sizes that
/// counted the same bytes twice.
@Suite struct ReclaimFixesTests {
    private func item(
        _ id: String, category: StorageCategory = .tools, safety: Safety = .safe,
        action: ReclaimAction, reveal: URL? = nil, bytes: Int64 = 10
    ) -> StorageItem {
        StorageItem(id: id, category: category, name: id, detail: "", sizeBytes: bytes,
                    safety: safety, action: action, revealURL: reveal)
    }

    /// With "Move safe items to the Trash" on, the Trash row is still Safe,
    /// and trashing what is already in the Trash leaves it there.
    @Test func emptyingTheTrashNeverMovesItToTheTrash() {
        let trash = item("trash", category: .trash, action: .emptyDirectories([URL.home(".Trash")]))
        #expect(!ScanModel.goesToTrash([trash], deletesReviewItemsImmediately: false, movesSafeToTrash: true))

        let cache = item("cache", action: .removePaths([URL(fileURLWithPath: "/tmp/x")]))
        #expect(ScanModel.goesToTrash([cache], deletesReviewItemsImmediately: false, movesSafeToTrash: true))
    }

    /// Gone since the scan: nothing was deleted, so nothing is credited.
    @MainActor
    @Test func aPathThatIsAlreadyGoneIsNotCountedAsFreed() async {
        let missing = URL(fileURLWithPath: "/tmp/sysdata-gone-\(UUID().uuidString)")
        let gone = item("gone", action: .removePaths([missing]), bytes: 5_000_000_000)
        let model = ScanModel(scansAutomatically: false, items: [gone])

        await model.reclaim(gone)

        #expect(model.reclaimedBytes == 0)
        #expect(model.items.isEmpty)
    }

    /// A generic folder row that holds a location another probe names would
    /// count those bytes twice.
    @Test func aGenericRowContainingANamedOneIsDropped() {
        let home = URL(fileURLWithPath: "/tmp/sysdata-overlap")
        let hidden = item("tool-hidden-.tart", action: .removePaths([home.appending(path: ".tart")]),
                          reveal: home.appending(path: ".tart"))
        let vm = item("vm-x", action: .removePaths([home.appending(path: ".tart/vms/x")]),
                      reveal: home.appending(path: ".tart/vms/x"))
        let unrelated = item("tool-hidden-.other", action: .removePaths([home.appending(path: ".other")]),
                             reveal: home.appending(path: ".other"))
        // A named row is never dropped, even when another row sits inside it.
        let named = item("pkg-brew", action: .removePaths([home.appending(path: ".tart/vms")]),
                         reveal: home.appending(path: ".tart/vms"))

        let kept = ProbeRegistry.withoutOverlaps([hidden, vm, unrelated, named]).map(\.id)
        #expect(Set(kept) == ["vm-x", "tool-hidden-.other", "pkg-brew"])
    }

    @Test func anUnreadableHistoryIsKeptAsideRatherThanOverwritten() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "sysdata-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "history.json")
        try Data("{\"scans\": [{\"date\": 42}]}".utf8).write(to: file)

        let log = try #require(ScanHistory.loadForWriting(at: file))
        #expect(log.scans.isEmpty)
        let aside = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(aside.count == 1 && aside[0].hasPrefix("history-unreadable-"))
    }

    @Test func aProgramThatIgnoresSIGTERMIsKilled() async throws {
        let result = try await Shell.run("/bin/sh", ["-c", "trap '' TERM; sleep 60"], timeout: .milliseconds(300))
        #expect(result.timedOut)
        #expect(!result.succeeded)
    }

    @Test func aProgramThatExitsWithFifteenItselfIsNotATimeout() async throws {
        let result = try await Shell.run("/bin/sh", ["-c", "exit 15"], timeout: .seconds(10))
        #expect(result.status == 15)
        #expect(!result.timedOut)
    }

    /// The password prompt comes first and stops everything when dismissed,
    /// so Touch ID before it is the same question asked twice.
    @Test func touchIDIsSkippedOnlyWhenThePasswordComesFirst() {
        let script = item("logs", action: .privilegedScript("log erase --all"))
        let cache = item("cache", action: .removePaths([URL(fileURLWithPath: "/tmp/x")]))
        #expect(ScanModel.passwordGuardsWholeBatch([cache, script]))
        #expect(!ScanModel.passwordGuardsWholeBatch([cache]))
        // A root-owned folder is asked for mid-batch, after others are gone.
        let rootFolder = item("root", action: .removePaths([URL(fileURLWithPath: "/Library/Caches")]))
        #expect(!ScanModel.passwordGuardsWholeBatch([cache, rootFolder]))
    }
}
