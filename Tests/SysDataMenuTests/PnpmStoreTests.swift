import Foundation
import Testing
@testable import SysDataMenu

/// Finding a store its own command can no longer point to is worth doing, and
/// getting it wrong means telling someone a live package store is dead weight.
@Suite struct PnpmStoreTests {
    @Test func theSearchPathCoversTheVersionManagersThatHideATool() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // A GUI process inherits no PATH, so a tool missing from this list
        // reads as "not installed" — which for pnpm decides whether its store
        // is offered for deletion.
        for shims in [".volta/bin", ".asdf/shims", ".local/share/mise/shims", ".bun/bin"] {
            #expect(Shell.searchPathForTesting.contains("\(home)/\(shims)"), "\(shims) is missing")
        }
        #expect(Shell.searchPathForTesting.contains("/opt/homebrew/bin"))
    }

    @Test func theDefaultStoreIsOnlyReportedWhenItExists() {
        // Whatever this machine has, the answer must be a directory that is
        // actually there rather than a guess.
        if let store = PackageProbe.defaultPnpmStore {
            #expect(store.exists)
            #expect(store.path.hasSuffix("store"))
        }
    }

    /// The item the probe builds when pnpm cannot be found must be reversible,
    /// because the app is inferring rather than knowing. Safe items are
    /// deleted outright; Review items go to the Trash.
    @Test func aStoreFoundWithoutItsToolGoesToTheTrash() async {
        let items = await PackageProbe().probe()
        guard let store = items.first(where: { $0.id == "pkg-pnpm" }) else { return }

        if Shell.which("pnpm") == nil {
            #expect(store.safety == .review, "an inference must not delete outright")
            #expect(!store.detail.contains("is not installed"),
                    "the app observed that it could not find pnpm, which is not the same claim")
        } else {
            #expect(store.safety == .safe)
        }
    }
}
