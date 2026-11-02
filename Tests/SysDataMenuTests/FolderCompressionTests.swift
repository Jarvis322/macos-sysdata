import Darwin
import Foundation
import Testing
@testable import SysDataMenu

/// Shrinking rewrites every file in a folder, so the properties that matter
/// are that nothing is lost and that it refuses the cases where it would
/// make the disk fuller rather than emptier.
@Suite struct FolderCompressionTests {
    private let plenty: Int64 = 1 << 50

    private func folder(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "sysdata-shrink-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url.appending(path: "nested"), withIntermediateDirectories: true)
        let text = String(repeating: "module.exports = function compressible() { return 42 }\n", count: 40_000)
        try Data(text.utf8).write(to: url.appending(path: "a.js"))
        try Data(text.utf8).write(to: url.appending(path: "nested/b.js"))
        return url
    }

    private func contents(_ root: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for case let url as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)! {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            files[String(url.path.dropFirst(root.path.count))] = try Data(contentsOf: url)
        }
        return files
    }

    @Test func shrinksWithoutChangingAByte() async throws {
        let root = try folder("plain")
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try contents(root)

        let outcome = try await FolderCompression.shrink(root, freeSpace: plenty)

        #expect(outcome.after < outcome.before / 2)
        #expect(try contents(root) == before)
        #expect(DiskSize.allocatedSync(at: root) == outcome.after, "the scan measures what the shrink reports")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.deletingLastPathComponent().path)
            .filter { $0.contains(root.lastPathComponent) && $0 != root.lastPathComponent }
        #expect(leftovers.isEmpty, "the copy is gone after the swap")
    }

    @Test func aSecondShrinkSaysItIsAlreadyDone() async throws {
        let root = try folder("twice")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await FolderCompression.shrink(root, freeSpace: plenty)

        await #expect(throws: FolderCompression.Refusal.alreadyCompressed(name: root.lastPathComponent)) {
            try await FolderCompression.shrink(root, freeSpace: plenty)
        }
    }

    /// pnpm's node_modules is hard links into its store.
    @Test func hardLinksAreLeftAlone() async throws {
        let root = try folder("links")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.linkItem(at: root.appending(path: "a.js"), to: root.appending(path: "linked.js"))

        await #expect(throws: FolderCompression.Refusal.sharesBlocks(name: root.lastPathComponent)) {
            try await FolderCompression.shrink(root, freeSpace: plenty)
        }
    }

    /// A handful of stray links is no reason to refuse a whole tree.
    @Test func aFewSmallHardLinksAreTolerated() async throws {
        let root = try folder("fewlinks")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("tiny".utf8).write(to: root.appending(path: "tiny.txt"))
        try FileManager.default.linkItem(at: root.appending(path: "tiny.txt"), to: root.appending(path: "tiny-link.txt"))

        let outcome = try await FolderCompression.shrink(root, freeSpace: plenty)
        #expect(outcome.saved > 0)
    }

    @Test func clonesAreLeftAlone() async throws {
        let root = try folder("clones")
        defer { try? FileManager.default.removeItem(at: root) }
        guard clonefile(root.appending(path: "a.js").path, root.appending(path: "clone.js").path, 0) == 0 else {
            Issue.record("could not clone: \(String(cString: strerror(errno)))")
            return
        }

        await #expect(throws: FolderCompression.Refusal.sharesBlocks(name: root.lastPathComponent)) {
            try await FolderCompression.shrink(root, freeSpace: plenty)
        }
    }

    @Test func itNeedsRoomForTheCopy() async throws {
        let root = try folder("space")
        defer { try? FileManager.default.removeItem(at: root) }

        await #expect(throws: FolderCompression.Refusal.notEnoughSpace(name: root.lastPathComponent)) {
            try await FolderCompression.shrink(root, freeSpace: 0)
        }
    }

    /// Offered where compression lasts, and never where the next write
    /// would undo it or the data is dense already.
    @Test func shrinkIsOfferedWhereItLasts() {
        func row(_ id: String, _ category: StorageCategory, folder: String = "x") -> StorageItem {
            let url = URL(fileURLWithPath: "/tmp/\(folder)")
            return StorageItem(id: id, category: category, name: id, detail: "", sizeBytes: 1 << 30,
                               safety: .review, action: .removePaths([url]), revealURL: url)
        }
        #expect(ScanModel.shrinkIdleDays(for: row("android-ndk-29", .android)) == 0)
        #expect(ScanModel.shrinkIdleDays(for: row("android-avd-Pixel.avd", .android)) == nil)
        #expect(ScanModel.shrinkIdleDays(for: row("xcode-Archives", .xcode)) == 0)
        #expect(ScanModel.shrinkIdleDays(for: row("xcode-deriveddata-App-abc", .xcode)) == 30)
        #expect(ScanModel.shrinkIdleDays(for: row("xcode-caches", .xcode)) == nil)
        #expect(ScanModel.shrinkIdleDays(for: row("jetbrains-old-PyCharm2023.2", .tools)) == 0)
        #expect(ScanModel.shrinkIdleDays(for: row("tool-hidden-.rembg", .tools)) == nil)
        #expect(ScanModel.shrinkIdleDays(for: row("project-a", .projects, folder: "node_modules")) == 7)
        #expect(ScanModel.shrinkIdleDays(for: row("project-b", .projects, folder: ".next")) == 30)
        #expect(ScanModel.shrinkIdleDays(for: row("vm-x", .vms)) == nil)
        #expect(ScanModel.shrinkIdleDays(for: row("ai-model", .ai)) == nil)
    }
}
