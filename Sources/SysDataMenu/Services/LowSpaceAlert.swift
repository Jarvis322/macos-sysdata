import Foundation
import UserNotifications

/// Tells you the disk is filling up, and never does anything about it.
///
/// The background scan already runs once a day, so the app knows the disk is
/// nearly full long before the person does — usually a build fails first, or
/// a download stops halfway. Saying so is worth a notification. Acting on it
/// is not: this app deletes things that cannot always be undone, and nothing
/// it could do unattended is worth the one time it gets it wrong.
///
/// Off until switched on, because turning it on is what asks macOS for
/// permission to post notifications, and an app that asks at launch for
/// something the person has not chosen is the kind of app this one is not.
enum LowSpaceAlert {
    private static let enabledKey = "warnsAboutLowSpace"
    private static let thresholdKey = "lowSpaceThresholdBytes"
    private static let lastStateKey = "lowSpaceWasBelow"

    static let gigabyte: Int64 = 1_073_741_824
    /// Offered thresholds. Below 10 GB macOS is already in trouble on its own;
    /// above 100 GB the warning stops meaning anything on a 256 GB Mac.
    static let choices: [Int64] = [10, 20, 50, 100].map { $0 * gigabyte }

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var threshold: Int64 {
        get {
            let stored = UserDefaults.standard.object(forKey: thresholdKey) as? Int
            return stored.map(Int64.init) ?? 20 * gigabyte
        }
        set { UserDefaults.standard.set(Int(newValue), forKey: thresholdKey) }
    }

    /// Asks macOS for permission. Returns false when it is refused, so the
    /// switch can go back off rather than sit on next to nothing happening.
    static func requestPermission() async -> Bool {
        guard isAvailable else { return false }
        return (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Posts at most one notification per crossing.
    ///
    /// A daily scan on a disk that sits just under the line would otherwise
    /// post every day forever, which is how a useful warning becomes one
    /// people switch off. The alert fires when free space crosses below the
    /// threshold and stays quiet until it has been back above it.
    static func check(freeBytes: Int64, reclaimable: Int64) async {
        guard isEnabled, isAvailable else { return }
        let wasBelow = UserDefaults.standard.bool(forKey: lastStateKey)
        UserDefaults.standard.set(freeBytes < threshold, forKey: lastStateKey)
        guard shouldPost(freeBytes: freeBytes, threshold: threshold, wasBelow: wasBelow) else { return }

        let content = UNMutableNotificationContent()
        content.title = L("%@ free on disk", freeBytes.byteString)
        content.body = reclaimable > 0
            ? L("System Data holds %@ that is safe to free.", reclaimable.byteString)
            : L("Open System Data to see what is taking up room.")
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "low-space", content: content, trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// The rule on its own, so it can be checked without a notification
    /// centre: fire on the way down, and not again until free space has been
    /// back above the line.
    static func shouldPost(freeBytes: Int64, threshold: Int64, wasBelow: Bool) -> Bool {
        freeBytes < threshold && !wasBelow
    }

    /// UNUserNotificationCenter raises rather than returning nil when the
    /// process has no application bundle, which is how `--json` and the tests
    /// run. Nothing here may touch it before this is true.
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }
}
