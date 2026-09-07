import Foundation
import Testing
@testable import SysDataMenu

/// Reading another app's container asks macOS for permission by that app's
/// name. A scan that walks ~/Library/Containers before Full Disk Access exists
/// therefore greets a new user with a queue of dialogs — one for Music, one
/// for Photos, one for everything else that keeps a container — for a grant
/// that would have covered all of them at once.
@Suite struct ProtectedAccessTests {
    @Test func theProtectedListCoversWhatMacOSActuallyGuards() {
        let paths = ProbeSupport.protectedLocations.map(\.lastPathComponent)
        for guarded in ["Containers", "Group Containers", "Desktop", "Documents", "Downloads", "Music", "Pictures", "Movies"] {
            #expect(paths.contains(guarded), "\(guarded) prompts and is not on the list")
        }
    }

    /// The probe used to detect access must not itself be one that prompts.
    /// ~/Library/Safari is denied outright rather than asked about, which is
    /// the whole reason it is the one used.
    @Test func theAccessCheckDoesNotItselfAsk() {
        let probe = URL.home("Library/Safari")
        #expect(!ProbeSupport.protectedLocations.contains { probe.path.hasPrefix($0.path) },
                "the detector must not live inside something it would have to ask about")
        // Answers rather than hanging or trapping, whichever way it comes out.
        _ = ProbeSupport.hasFullDiskAccess
    }

    @Test func everyProtectedLocationIsUnderTheHomeFolder() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(ProbeSupport.protectedLocations.allSatisfy { $0.path.hasPrefix(home) })
    }

    /// The whole scan, run as if there were no access. Every probe that walks
    /// a protected place has to stay out of it — one that does not is a dialog
    /// in someone's face on first launch.
    ///
    /// Run in a child process, because the answer is read from the
    /// environment and the test host cannot change its own.
    @Test(.enabled(if: MachineScan.isEnabled), .timeLimit(.minutes(10)))
    func nothingProtectedIsTouchedWithoutAccess() throws {
        // Found from the source path rather than argv[0], which under
        // `swift test` is swiftpm's own runner.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SysDataMenuTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
        let candidates: [URL] = [".build/release/SysDataMenu", ".build/debug/SysDataMenu"]
            .map { root.appending(path: $0) }
        let binary = try #require(
            candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) },
            "needs a built binary; run swift build first"
        )

        let process = Process()
        process.executableURL = binary
        process.arguments = ["--json"]
        process.environment = ProcessInfo.processInfo.environment
            .merging(["SYSDATA_NO_FULL_DISK_ACCESS": "1"]) { _, new in new }
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let inventory = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let items = try #require(inventory["items"] as? [[String: Any]])
        #expect(!items.isEmpty, "the scan still has plenty to report without access")

        let guarded = ProbeSupport.protectedLocations.map { $0.path + "/" }
        let leaked = items.compactMap { $0["path"] as? String }
            .filter { path in guarded.contains { path.hasPrefix($0) } }
        #expect(leaked.isEmpty, "reported from a protected place without the access to read it: \(leaked.prefix(3))")
    }

    /// The catch-all walks the home folder, so without access it has to treat
    /// the containers as excluded or it descends into them itself.
    @MainActor
    @Test func theCatchAllKnowsToLeaveContainersAlone() async {
        // Whichever state this machine is in, the probe must complete without
        // reporting anything from inside a container it should not have read.
        let items = await LargeFolderProbe(claimed: []).probe()
        if !ProbeSupport.hasFullDiskAccess {
            #expect(!items.contains { $0.revealURL?.path.contains("/Library/Containers/") == true },
                    "a container was reported without the access needed to read it")
        }
    }
}
