import Foundation
import UserNotifications

/// The one thing the app will do on its own, once the person has asked it to.
///
/// This app's rule is that it never deletes what you did not click. Automatic
/// cleaning is the deliberate exception, and it is drawn as narrowly as the
/// rule allows: only items marked Safe — the caches macOS or a tool rebuilds
/// on demand — and only those that delete without an administrator password,
/// so nothing here can ever touch a device backup, a login, or a root-owned
/// path unattended. It runs at most once a week, and it always says afterward
/// what it freed. Off until switched on.
enum AutoClean {
    private static let enabledKey = "autoCleanEnabled"
    private static let lastRunKey = "autoCleanLastRun"
    private static let period: TimeInterval = 7 * 24 * 60 * 60

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// True when a week has passed since the last run (or it has never run).
    static func isDue(at now: Date = .now) -> Bool {
        guard isEnabled else { return false }
        guard let last = UserDefaults.standard.object(forKey: lastRunKey) as? Date else { return true }
        return now.timeIntervalSince(last) >= period
    }

    static func markRun(at now: Date = .now) {
        UserDefaults.standard.set(now, forKey: lastRunKey)
    }

    /// Says what the automatic clean did, so it is never a silent deletion.
    static func announce(freed: Int64, count: Int) async {
        guard LowSpaceAlert.isAvailable, count > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = L("Freed %@ automatically", freed.byteString)
        content.body = L("Cleared %lld safe items that had built back up.", count)
        content.sound = .default
        let request = UNNotificationRequest(identifier: "auto-clean", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
