import Foundation
import Testing
@testable import SysDataMenu

/// `Reclaimer` is the only code in the app that deletes anything, so its
/// behaviour is pinned here against a scratch tree. Nothing outside the
/// temporary directory this suite creates is ever touched.
@Suite struct ReclaimerTests {
    /// A disposable directory tree, removed when the test ends.
    private struct Scratch: ~Copyable {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appending(path: "sysdata-reclaim-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        @discardableResult
        func file(_ name: String, bytes: Int = 32, modified: Date? = nil) throws -> URL {
            let url = root.appending(path: name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(count: bytes).write(to: url)
            if let modified {
                try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            }
            return url
        }

        func url(_ name: String) -> URL { root.appending(path: name) }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    @Test func removePathsDeletesFilesAndDirectories() async throws {
        let scratch = try Scratch()
        let file = try scratch.file("loose.bin")
        try scratch.file("tree/nested/deep.bin")
        let tree = scratch.url("tree")

        try await Reclaimer.perform(.removePaths([file, tree]))

        #expect(!file.exists)
        #expect(!tree.exists)
    }

    @Test func removePathsIgnoresPathsThatAreAlreadyGone() async throws {
        let scratch = try Scratch()
        let missing = scratch.url("never-existed")

        // A second delete of an item the user removed by hand must not throw,
        // otherwise a batch stops halfway on a no-op.
        try await Reclaimer.perform(.removePaths([missing]))
    }

    @Test func emptyDirectoriesClearsContentsButKeepsTheDirectory() async throws {
        let scratch = try Scratch()
        try scratch.file("cache/a.bin")
        try scratch.file("cache/.hidden")
        try scratch.file("cache/sub/b.bin")
        let cache = scratch.url("cache")

        try await Reclaimer.perform(.emptyDirectories([cache]))

        #expect(cache.exists, "the directory itself must survive; tools expect it to be there")
        #expect(cache.children(includeHidden: true).isEmpty, "hidden entries must go too")
    }

    @Test func pruneRemovesOldFilesAndKeepsRecentOnes() async throws {
        let scratch = try Scratch()
        let old = try scratch.file("logs/old.log", modified: .now.addingTimeInterval(-40 * 86_400))
        let recent = try scratch.file("logs/recent.log", modified: .now.addingTimeInterval(-2 * 86_400))

        try await Reclaimer.perform(.pruneOlderThan(scratch.url("logs"), days: 30))

        #expect(!old.exists)
        #expect(recent.exists)
    }

    @Test func pruneRemovesDirectoriesLeftEmptyButKeepsPopulatedOnes() async throws {
        let scratch = try Scratch()
        try scratch.file("logs/stale/only.log", modified: .now.addingTimeInterval(-40 * 86_400))
        try scratch.file("logs/live/kept.log", modified: .now)

        try await Reclaimer.perform(.pruneOlderThan(scratch.url("logs"), days: 30))

        #expect(!scratch.url("logs/stale").exists)
        #expect(scratch.url("logs/live").exists)
    }

    @Test func stepsStopAtTheFirstFailure() async throws {
        let scratch = try Scratch()
        let second = try scratch.file("second.bin")

        await #expect(throws: CommandError.self) {
            try await Reclaimer.perform(.steps([
                .command(executable: "/usr/bin/false", arguments: []),
                .removePaths([second]),
            ]))
        }

        #expect(second.exists, "a step after a failed one must not run")
    }

    @Test func stepsRunInOrderWhenNothingFails() async throws {
        let scratch = try Scratch()
        let file = try scratch.file("box/thing.bin")
        let box = scratch.url("box")

        try await Reclaimer.perform(.steps([
            .command(executable: "/usr/bin/true", arguments: []),
            .removePaths([file]),
        ]))

        #expect(!file.exists)
        #expect(box.exists)
    }

    @Test func failingCommandReportsTheCommandItRan() async throws {
        let error = await #expect(throws: CommandError.self) {
            try await Reclaimer.perform(.command(executable: "/bin/sh", arguments: ["-c", "exit 3"]))
        }

        #expect(error?.result.status == 3)
        #expect(error?.command.contains("/bin/sh") == true)
    }

    @Test func manualActionDoesNothing() async throws {
        let scratch = try Scratch()
        let file = try scratch.file("kept.bin")

        try await Reclaimer.perform(.manual("Open System Settings"))

        #expect(file.exists)
    }
}
