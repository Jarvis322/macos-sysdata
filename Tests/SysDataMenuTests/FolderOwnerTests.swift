import Foundation
import Testing

@testable import SysDataMenu

/// "Other large folders" was 19 GB of rows that said only "not recognised".
/// Most carry their owner in their path; the case that matters most is an
/// owner that is no longer installed.
struct FolderOwnerTests {
    private let apps = InstalledApps(
        namesByIdentifier: ["com.anthropic.claudefordesktop": "Claude", "com.google.chrome": "Google Chrome"],
        names: ["Claude", "Google Chrome", "Safari"]
    )

    private func describe(_ path: String) -> String? {
        FolderOwner.describe(URL(fileURLWithPath: path), apps: apps)
    }

    /// The four rows this was written against, on the Mac it was written on.
    @Test func theRowsFromTheMacThisWasBuiltOn() {
        #expect((describe("/Users/me/Library/Metadata") ?? "").contains("Spotlight"))
        #expect(describe("/Users/me/Library/Application Support/Claude/Partitions") == "Belongs to Claude.")
        #expect(describe("/Users/me/Library/Application Support/Google") == "Belongs to Google Chrome.")
    }

    @Test func aBundleIdentifierIsResolvedToItsApp() {
        #expect(describe("/Users/me/Library/Containers/com.google.Chrome/Data") == "Belongs to Google Chrome.")
        #expect(describe("/Users/me/Library/Caches/com.anthropic.claudefordesktop") == "Belongs to Claude.")
    }

    @Test func anUninstalledOwnerIsSaidToBeGone() {
        #expect(describe("/Users/me/Library/Application Support/com.example.retired")
                == "Left by com.example.retired, which is no longer installed on this Mac.")
    }

    @Test func aTeamPrefixedGroupContainerIsReadPastItsPrefix() {
        #expect(describe("/Users/me/Library/Group Containers/ABCDE12345.com.google.chrome")
                == "Belongs to Google Chrome.")
    }

    @Test func aPathThatDoesNotSayStaysUnexplained() {
        #expect(describe("/Users/me/Library/Application Support/SomethingElse") == nil)
        #expect(describe("/opt/homebrew/Cellar") == nil)
    }
}
