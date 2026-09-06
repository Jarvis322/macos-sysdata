import Foundation
import Observation

/// Asks GitHub once a day whether a newer release exists.
///
/// This is the only network request the app makes, and it is off unless the
/// person turns it on. Everything else the app does happens on the machine,
/// and a version check quietly phoning home would spend that for a
/// convenience. What it sends is what any HTTP request sends — an IP address
/// and the app's version — and it goes to GitHub, where the releases already
/// are.
@MainActor
@Observable
final class UpdateCheck {
    private static let releases = URL(string: "https://api.github.com/repos/Jarvis322/macos-sysdata/releases/latest")!
    private static let enabledKey = "checksForUpdates"
    private static let lastCheckKey = "lastUpdateCheck"
    private static let interval: TimeInterval = 24 * 60 * 60

    /// The version on GitHub when it is newer than this build, else nil.
    private(set) var newVersion: String?
    /// The disk image for that version.
    private(set) var newVersionImage: URL?
    private(set) var isInstalling = false
    var installError: String?

    var isEnabled: Bool = UserDefaults.standard.bool(forKey: UpdateCheck.enabledKey) {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if !isEnabled { newVersion = nil }
        }
    }

    /// The build's own version, from the bundle rather than a constant, so it
    /// cannot drift from what was shipped.
    static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    var downloadURL: URL {
        URL(string: "https://github.com/Jarvis322/macos-sysdata/releases/latest")!
    }

    func checkIfDue() async {
        guard isEnabled else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
        if let last, Date.now.timeIntervalSince(last) < Self.interval { return }
        await check()
    }

    func check() async {
        guard isEnabled else { return }
        UserDefaults.standard.set(Date.now, forKey: Self.lastCheckKey)

        var request = URLRequest(url: Self.releases, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { return }

        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard Self.isNewer(latest, than: Self.current) else {
            newVersion = nil
            newVersionImage = nil
            return
        }
        newVersion = latest
        let assets = json["assets"] as? [[String: Any]] ?? []
        newVersionImage = assets
            .compactMap { $0["browser_download_url"] as? String }
            .first { $0.hasSuffix(".dmg") }
            .flatMap(URL.init(string:))
    }

    /// Downloads the release and replaces this app with it. Everything that
    /// decides whether that is safe lives in `Updater`.
    func install() async {
        guard let image = newVersionImage, !isInstalling else { return }
        isInstalling = true
        installError = nil
        defer { isInstalling = false }
        do {
            try await Updater.installLatest(from: image)
        } catch {
            installError = error.localizedDescription
        }
    }

    /// Compares dotted versions numerically, so 0.3.10 is newer than 0.3.9;
    /// a string comparison would say the opposite. Pure arithmetic, so it is
    /// not bound to the main actor and can be tested without one.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let left = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let right = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }
}
