import AppKit
import Foundation

/// Downloads a release and replaces the running app with it.
///
/// This is the one place the app can be made to run code it did not ship with,
/// so the download is checked before anything is moved: the image must come
/// from the expected host over HTTPS, and the app inside it must be signed by
/// the same team as the copy asking for the update and accepted by Gatekeeper.
/// A release channel that is compromised, or a proxy that answers for GitHub,
/// then produces a failed update rather than arbitrary code running as the
/// person who trusted this app with their disk.
enum Updater {
    enum Failure: LocalizedError {
        case unexpectedHost
        case downloadFailed
        case cannotMount
        case noAppInImage
        case signatureRejected(String)
        case cannotReplace(String)

        var errorDescription: String? {
            switch self {
            case .unexpectedHost:
                L("The download does not come from GitHub. Nothing was installed.")
            case .downloadFailed:
                L("The download did not finish. Nothing was installed.")
            case .cannotMount:
                L("The downloaded image could not be opened. Nothing was installed.")
            case .noAppInImage:
                L("The downloaded image does not contain the app. Nothing was installed.")
            case .signatureRejected(let detail):
                L("The download is not signed by this app's developer, so it was discarded. (%@)", detail)
            case .cannotReplace(let detail):
                L("The app could not be replaced: %@", detail)
            }
        }
    }

    /// Where a release may come from. A redirect off this host is refused.
    private static let expectedHost = "github.com"

    static func installLatest(from url: URL) async throws {
        guard url.host()?.hasSuffix(expectedHost) == true, url.scheme == "https" else {
            throw Failure.unexpectedHost
        }

        let image = try await download(url)
        defer { try? FileManager.default.removeItem(at: image) }

        let mount = try await attach(image)
        defer { Task { _ = try? await Shell.run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"]) } }

        let candidate = mount.appending(path: Bundle.main.bundleURL.lastPathComponent)
        guard FileManager.default.fileExists(atPath: candidate.path) else { throw Failure.noAppInImage }

        try await verify(candidate)
        try replace(with: candidate)
        relaunch()
    }

    private static func download(_ url: URL) async throws -> URL {
        guard let (temporary, response) = try? await URLSession.shared.download(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure.downloadFailed
        }
        // A redirect could have left the expected host between the request and
        // the bytes that arrived, so the final URL is checked too.
        if let final = response.url, final.host()?.hasSuffix(expectedHost) != true {
            try? FileManager.default.removeItem(at: temporary)
            throw Failure.unexpectedHost
        }
        let destination = temporary.deletingLastPathComponent()
            .appending(path: "sysdata-update-\(UUID().uuidString).dmg")
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    private static func attach(_ image: URL) async throws -> URL {
        // -nobrowse keeps it out of the Finder sidebar; -noautoopen stops a
        // window appearing behind the menu.
        let result = try await Shell.run(
            "/usr/bin/hdiutil",
            ["attach", image.path, "-nobrowse", "-noautoopen", "-readonly", "-plist"],
            mergeStderr: false
        )
        guard result.succeeded,
              let data = result.output.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let point = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw Failure.cannotMount
        }
        return URL(fileURLWithPath: point)
    }

    /// The download must be signed by the same team as the running app and
    /// pass the same assessment Gatekeeper applies to a fresh download.
    /// Not private: this is the check the whole feature rests on, so it is
    /// reachable from the tests.
    static func verify(_ app: URL) async throws {
        let assessment = try await Shell.run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path])
        guard assessment.succeeded else {
            throw Failure.signatureRejected(assessment.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        guard let mine = teamIdentifier(of: Bundle.main.bundleURL),
              let theirs = await teamIdentifierAsync(of: app), mine == theirs else {
            throw Failure.signatureRejected(L("different developer"))
        }
    }

    private static func teamIdentifier(of app: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static func teamIdentifierAsync(of app: URL) async -> String? {
        await Task.detached { teamIdentifier(of: app) }.value
    }

    private static func replace(with candidate: URL) throws {
        let installed = Bundle.main.bundleURL
        let manager = FileManager.default
        let staging = installed.deletingLastPathComponent()
            .appending(path: ".\(installed.lastPathComponent).incoming")

        do {
            try? manager.removeItem(at: staging)
            // Copy beside the installed app first, so a failure part-way
            // through leaves the working copy untouched.
            try manager.copyItem(at: candidate, to: staging)
            _ = try manager.replaceItemAt(installed, withItemAt: staging)
        } catch {
            try? manager.removeItem(at: staging)
            throw Failure.cannotReplace(error.localizedDescription)
        }
    }

    private static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            Task { @MainActor in NSApplication.shared.terminate(nil) }
        }
    }
}
