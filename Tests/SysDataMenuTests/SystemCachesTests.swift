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

    @Test func aPathWithAQuoteOrASpaceStaysOnePath() {
        let script = SystemProbe.removeScript(for: [
            URL(fileURLWithPath: "/Library/Caches/it's here"),
        ])

        #expect(script == #"rm -rf '/Library/Caches/it'\''s here'"#)
    }
}
