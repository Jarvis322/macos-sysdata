import Foundation
import Testing

@testable import SysDataMenu

/// `/Library/Caches` holds entries the system will not let anyone remove, root
/// included, and which this app cannot even see. A glob reached them, so every
/// delete of the system caches ended in three "Operation not permitted" lines
/// and was reported as a failure, though everything removable was gone.
struct SystemCachesTests {
    @Test func theScriptNamesEachPathInsteadOfGlobbing() {
        let script = SystemProbe.removeScript(for: [
            URL(fileURLWithPath: "/Library/Caches/com.example.one"),
            URL(fileURLWithPath: "/Library/Caches/com.example.two"),
        ])

        #expect(script == "rm -rf '/Library/Caches/com.example.one' '/Library/Caches/com.example.two'")
        #expect(!script.contains("*"))
    }

    /// The three that were reported — data vaults under /Library/Caches — do
    /// not exist on every Mac, but a restricted path does: /usr/bin carries
    /// the same flag, and nothing on the machine may remove it.
    @Test func aRestrictedPathIsNotOfferedForRemoval() {
        #expect(!SystemProbe.isRemovable(URL(fileURLWithPath: "/usr/bin")))
        #expect(!SystemProbe.isRemovable(URL(fileURLWithPath: "/System")))
    }

    @Test func anOrdinaryDirectoryIsRemovable() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(SystemProbe.isRemovable(directory))
    }

    /// A path that cannot be looked at cannot be deleted either, and one that
    /// is not there any more has nothing to delete.
    @Test func whatCannotBeInspectedIsNotOffered() {
        #expect(!SystemProbe.isRemovable(URL(fileURLWithPath: "/Library/Caches/\(UUID().uuidString)")))
    }

    @Test func aPathWithAQuoteOrASpaceStaysOnePath() {
        let script = SystemProbe.removeScript(for: [
            URL(fileURLWithPath: "/Library/Caches/it's here"),
        ])

        #expect(script == #"rm -rf '/Library/Caches/it'\''s here'"#)
    }
}
