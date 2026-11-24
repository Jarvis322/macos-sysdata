import Foundation
import Testing
@testable import SysDataMenu

/// Every link to a file reports the file's whole size, so a walk that added
/// them up counted the same blocks once per link (#31).
@Suite struct HardLinkSizeTests {
    private func makeTree() throws -> (root: URL, single: Int64) {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appending(path: "sysdata-links-\(UUID().uuidString)")
        for path in ["a", "b"] {
            try fileManager.createDirectory(at: root.appending(path: path), withIntermediateDirectories: true)
        }
        let original = root.appending(path: "a/data.bin")
        try Data(count: 200_000).write(to: original)
        for link in ["a/second.bin", "b/third.bin"] {
            try fileManager.linkItem(at: original, to: root.appending(path: link))
        }
        let single = Int64(try #require(original.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
            .totalFileAllocatedSize))
        return (root, single)
    }

    @Test func aWalkCountsAHardLinkedFileOnce() throws {
        let (root, single) = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(DiskSize.allocatedSync(at: root) == single)
    }

    @Test func directorySizesCountAHardLinkedFileOnce() throws {
        let (root, single) = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let sizes = DiskSize.directorySizes(under: root, maxDepth: 2)
        let rootPath = DiskSize.realPath(root.path)
        #expect(sizes[rootPath] == single)
        #expect((sizes[rootPath + "/a"] ?? 0) + (sizes[rootPath + "/b"] ?? 0) == single)
    }
}
