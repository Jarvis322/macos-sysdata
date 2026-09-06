import Foundation
import Testing
@testable import SysDataMenu

/// The updater replaces the running app, so the guards on where a download may
/// come from are the difference between an update and arbitrary code execution.
@Suite struct UpdaterTests {
    @Test func acceptsGitHubAndItsSubdomains() {
        for address in ["https://github.com/Jarvis322/macos-sysdata/releases/download/v0.3.11/SysDataMenu.dmg",
                        "https://objects.github.com/example.dmg"] {
            #expect(Updater.isExpectedDownloadURL(URL(string: address)!))
        }
    }

    @Test func refusesAHostThatIsNotGitHub() {
        for address in ["https://evil.example.com/SysDataMenu.dmg",
                        "https://github.com.evil.example.com/SysDataMenu.dmg",
                        "https://notgithub.com/SysDataMenu.dmg",
                        "https://evilgithub.com/SysDataMenu.dmg"] {
            #expect(!Updater.isExpectedDownloadURL(URL(string: address)!))
        }
    }

    @Test func refusesPlainHTTPEvenFromGitHub() {
        #expect(!Updater.isExpectedDownloadURL(URL(string: "http://github.com/a.dmg")!))
    }

    /// An app signed by someone else is rejected before anything is replaced.
    /// Apple's own apps carry no team identifier, which is equally not ours.
    @Test func refusesAnAppFromAnotherDeveloper() async {
        await #expect(throws: Updater.Failure.self) {
            try await Updater.verify(URL(fileURLWithPath: "/System/Applications/Calculator.app"))
        }
    }
}
