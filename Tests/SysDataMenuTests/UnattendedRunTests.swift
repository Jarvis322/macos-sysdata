import Foundation
import Testing
@testable import SysDataMenu

/// The runs nobody is watching — the weekly clean, the low-space button, the
/// Shortcut — must never ask for a password and must never touch what a
/// person would want a say in.
@MainActor
@Suite struct UnattendedRunTests {
    @Test func aScriptIsRefusedInsteadOfPrompting() async {
        await #expect(throws: NeedsAdministrator.self) {
            try await Reclaimer.perform(.privilegedScript("true"), allowsAdministrator: false)
        }
    }

    /// A folder whose contents the user cannot delete used to fall through to
    /// `rm -rf` as root, which is a password dialog out of nowhere.
    @Test func aPathOnlyRootCouldDeleteIsRefusedInsteadOfPrompting() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "sysdata-unattended-\(UUID().uuidString)")
        let locked = root.appending(path: "locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data(count: 8).write(to: locked.appending(path: "file.bin"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: root)
        }

        await #expect(throws: NeedsAdministrator.self) {
            try await Reclaimer.perform(.emptyDirectories([locked]), allowsAdministrator: false)
        }
        #expect(locked.appending(path: "file.bin").exists)
    }

    private func item(_ id: String, category: StorageCategory, action: ReclaimAction) -> StorageItem {
        StorageItem(id: id, category: category, name: id, detail: "detail", sizeBytes: 1, safety: .safe, action: action)
    }

    @Test func theSafeSetLeavesTheTrashAndRunningSimulatorsAlone() {
        let scratch = URL(fileURLWithPath: "/tmp/sysdata-not-real")
        let model = ScanModel(scansAutomatically: false, items: [
            item("npm", category: .packages, action: .removePaths([scratch])),
            item("trash", category: .trash, action: .emptyDirectories([scratch])),
            item("sim-caches", category: .simulators, action: .steps([.shutdownSimulators, .emptyDirectories([scratch])])),
        ])

        #expect(model.safeAutoItems.map(\.id) == ["npm"])
    }
}

/// A clean command that waits on another program's lock — `uv cache clean`
/// behind a running uvx server — left the Free button spinning for good.
struct CommandTimeoutTests {
    @Test func aCleanThatNeverFinishesIsStoppedAndSaysWhy() async {
        do {
            try await Reclaimer.perform(.command(executable: "/bin/sleep", arguments: ["30"]),
                                        commandTimeout: .milliseconds(300))
            Issue.record("the command should have been stopped")
        } catch let error as CommandError {
            #expect(error.result.status == SIGTERM)
            #expect(error.localizedDescription.contains("stopped"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}
