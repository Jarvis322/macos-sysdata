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

/// The published release, fetched the way the app fetches it.
///
/// Every other guard in the updater can be checked against a made-up URL.
/// The redirect check cannot: GitHub answers a release download with a 302
/// to an entirely different host, and no test that invents a URL will ever
/// see it. That is how 0.3.10 shipped an updater that refused every real
/// update. Gated on the same variable as the disk-walking tests, so it runs
/// on release and not on every save.
@Suite struct ReleaseDownloadTests {
    static let isEnabled = ProcessInfo.processInfo.environment["SYSDATA_SCAN_TESTS"] != nil

    @Test(.enabled(if: isEnabled), .timeLimit(.minutes(5)))
    func theLatestReleaseSurvivesTheRedirectAndIsOurs() async throws {
        let latest = URL(string: "https://github.com/Jarvis322/macos-sysdata/releases/latest")!
        let (data, _) = try await URLSession.shared.data(
            from: URL(string: "https://api.github.com/repos/Jarvis322/macos-sysdata/releases/latest")!
        )
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let assets = try #require(json["assets"] as? [[String: Any]])
        let image = try #require(
            assets.compactMap { $0["browser_download_url"] as? String }
                .first { $0.hasSuffix(".dmg") }
                .flatMap(URL.init(string:))
        )
        #expect(Updater.isExpectedDownloadURL(image), "\(latest) publishes an asset we would refuse to ask for")

        // Throws Failure.unexpectedHost if the post-redirect check is wrong.
        let downloaded = try await Updater.download(image)
        defer { try? FileManager.default.removeItem(at: downloaded) }

        let mount = try await Updater.attach(downloaded)
        defer { Task { _ = try? await Shell.run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"]) } }

        // Gatekeeper's own verdict on the download, the first gate `verify`
        // applies. The second gate compares the team against Bundle.main,
        // which under `swift test` is the test runner rather than the
        // installed app, so `refusesAnAppFromAnotherDeveloper` covers that
        // one instead.
        let app = mount.appending(path: "SysDataMenu.app")
        let assessment = try await Shell.run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path])
        #expect(assessment.succeeded, "Gatekeeper refused the published release: \(assessment.output)")
    }
}
