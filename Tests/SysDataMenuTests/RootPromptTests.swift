import Foundation
import Testing
@testable import SysDataMenu

/// The confirmation counted "N items need root" from actions whose type is a
/// privileged script. That is not the same set as the actions that prompt: a
/// plain delete of something this user cannot unlink falls back to `rm -rf` as
/// root, so it asks too — and asks separately, which the old message denied by
/// promising the password would be wanted once.
@Suite struct RootPromptTests {
    private func rootOwnedPath() throws -> URL {
        // /private/var/db is root-owned on every Mac and nothing here writes
        // to it; only `isDeletableFile` is asked.
        let url = URL(fileURLWithPath: "/private/var/db")
        try #require(url.exists, "expected a root-owned directory to test against")
        try #require(!FileManager.default.isDeletableFile(atPath: url.path),
                     "this user can unlink it, so it cannot stand in for one they cannot")
        return url
    }

    @Test func aPlainDeleteOfARootOwnedPathCountsAsNeedingRoot() throws {
        let action = ReclaimAction.removePaths([try rootOwnedPath()])

        #expect(action.needsAdministrator, "the reclaimer would run rm as root for this")
        #expect(action.asksForThePasswordSeparately, "and it is not folded into the batch's script")
    }

    @Test func aDeleteInTheUsersOwnFolderDoesNot() throws {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "sysdata-root-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let action = ReclaimAction.removePaths([scratch])

        #expect(!action.needsAdministrator)
        #expect(!action.asksForThePasswordSeparately)
    }

    /// Privileged scripts are combined into one script by the batch, so they
    /// need the password once between them.
    @Test func privilegedScriptsAskOnceBetweenThem() {
        let action = ReclaimAction.privilegedScript("rm -rf /Library/Logs/x")
        #expect(action.needsAdministrator)
        #expect(!action.asksForThePasswordSeparately)
    }

    @Test func aPathThatIsNotThereAsksForNothing() {
        let action = ReclaimAction.removePaths([URL(fileURLWithPath: "/private/var/db/nothing-\(UUID().uuidString)")])
        #expect(!action.needsAdministrator, "an absent path is never deleted, let alone as root")
    }

    @Test func aStepListInheritsBothAnswers() throws {
        let action = ReclaimAction.steps([
            .shutdownSimulators,
            .removePaths([try rootOwnedPath()]),
        ])
        #expect(action.needsAdministrator)
        #expect(action.asksForThePasswordSeparately)
    }

    @Test func manualItemsNeverPrompt() {
        #expect(!ReclaimAction.manual("do it yourself").needsAdministrator)
        #expect(!ReclaimAction.shutdownSimulators.needsAdministrator)
    }
}
