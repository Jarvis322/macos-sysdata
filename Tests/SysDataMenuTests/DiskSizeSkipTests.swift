import Foundation
import Testing
@testable import SysDataMenu

/// `directorySizes(skipping:)` is what keeps the catch-all scan from walking
/// the parts of the disk it will refuse to report anyway, so the two things
/// that make it safe are pinned here: a skipped directory contributes nothing,
/// and everything else is measured exactly as before.
@Suite struct DiskSizeSkipTests {
    private func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "sysdata-skip-\(UUID().uuidString)")
        for path in ["keep", "skip/deep"] {
            try FileManager.default.createDirectory(
                at: root.appending(path: path), withIntermediateDirectories: true
            )
        }
        try Data(count: 10_000).write(to: root.appending(path: "keep/a.bin"))
        try Data(count: 20_000).write(to: root.appending(path: "skip/b.bin"))
        try Data(count: 30_000).write(to: root.appending(path: "skip/deep/c.bin"))
        return root
    }

    @Test func skippingLeavesTheRestUntouched() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let full = DiskSize.directorySizes(under: root, maxDepth: 4)
        let pruned = DiskSize.directorySizes(
            under: root, maxDepth: 4, skipping: [root.appending(path: "skip").path]
        )

        #expect(pruned[DiskSize.realPath(root.appending(path: "keep").path)] == full[DiskSize.realPath(root.appending(path: "keep").path)])
        #expect(pruned[DiskSize.realPath(root.appending(path: "skip").path)] == nil, "a skipped directory is never measured")
        #expect(pruned[DiskSize.realPath(root.appending(path: "skip/deep").path)] == nil, "nor is anything under it")
    }

    @Test func skippedBytesAreLeftOutOfTheParentTotal() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let full = try #require(DiskSize.directorySizes(under: root, maxDepth: 4)[DiskSize.realPath(root.path)])
        let pruned = try #require(DiskSize.directorySizes(
            under: root, maxDepth: 4, skipping: [root.appending(path: "skip").path]
        )[DiskSize.realPath(root.path)])

        // 50 KB of the 60 KB tree is under skip/, allowing a block of rounding
        // per file for the two files that remain measured.
        #expect(full >= 60_000)
        #expect(pruned >= 10_000 && pruned < full - 45_000)
    }

    @Test func anEmptySkipSetChangesNothing() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(DiskSize.directorySizes(under: root, maxDepth: 4)
                == DiskSize.directorySizes(under: root, maxDepth: 4, skipping: []))
    }

    /// The catch-all now walks the boot volume only, so a home or root on an
    /// external drive is not crawled — the fix for a scan that ran for over a
    /// day on a Mac mini with a 10 TB disk and a Time Machine volume. The
    /// danger in that guard is the opposite mistake: firmlinks put `/` and the
    /// home folder on separate APFS volumes within one group, and if those read
    /// as different volumes the guard would skip home on every Mac and break
    /// the scan for everyone. This pins that they do not.
    @Test func theStartupPathsAllCountAsBootVolume() {
        #expect(DiskSize.isOnBootVolume(URL(fileURLWithPath: "/")))
        #expect(DiskSize.isOnBootVolume(.home))
        for path in ["/private/var", "/Library", "/Users/Shared"] where URL(fileURLWithPath: path).exists {
            #expect(DiskSize.isOnBootVolume(URL(fileURLWithPath: path)), "\(path) is on the startup volume")
        }
    }
}
