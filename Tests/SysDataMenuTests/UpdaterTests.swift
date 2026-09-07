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
        #expect(!Updater.isExpectedAssetURL(URL(string: "http://release-assets.githubusercontent.com/a.dmg")!))
    }

    /// A release download from github.com answers with a 302 to the asset
    /// host, so refusing everything but github.com after the redirect refused
    /// every real update. This is the host the bytes actually come from.
    @Test func acceptsTheHostGitHubServesReleaseAssetsFrom() {
        #expect(Updater.isExpectedAssetURL(
            URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/1/2?sig=x")!
        ))
        #expect(Updater.isExpectedAssetURL(URL(string: "https://objects.githubusercontent.com/example.dmg")!))
    }

    /// The redirect target is checked, not just the URL that was asked for.
    @Test func refusesALookalikeAssetHost() {
        for address in ["https://notgithubusercontent.com/a.dmg",
                        "https://githubusercontent.com.evil.example.com/a.dmg",
                        "https://evil.example.com/a.dmg"] {
            #expect(!Updater.isExpectedAssetURL(URL(string: address)!))
        }
    }

    /// The predicates above are the rule; these prove `installLatest` is the
    /// thing that applies it, so a later edit cannot route around them.
    @Test func installRefusesAHostThatIsNotGitHub() async {
        for address in ["https://notgithub.com/SysDataMenu.dmg",
                        "http://github.com/SysDataMenu.dmg",
                        // The asset host is where bytes may arrive from, not
                        // somewhere an update may be requested from.
                        "https://release-assets.githubusercontent.com/SysDataMenu.dmg"] {
            await #expect(throws: Updater.Failure.self) {
                try await Updater.installLatest(from: URL(string: address)!)
            }
        }
    }

    /// An app signed by someone else is rejected before anything is replaced.
    /// Apple's own apps carry no team identifier, which is equally not ours.
    @Test func refusesAnAppFromAnotherDeveloper() async {
        await #expect(throws: Updater.Failure.self) {
            try await Updater.verify(URL(fileURLWithPath: "/System/Applications/Calculator.app"))
        }
    }
}
