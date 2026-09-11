import Foundation
import UserNotifications

/// A once-a-week note on which way System Data is heading.
///
/// The app already scans in the background and keeps a history; the one thing
/// it never did was say, without being opened, that the number is climbing. A
/// cache that is 12 GB again by Friday is the reason to keep the app around,
/// and a person who never opens the window is exactly the one who should hear
/// it. Off until switched on, and never more than one notification a week.
enum WeeklyDigest {
    private static let enabledKey = "weeklySummaryEnabled"
    private static let lastPostedKey = "weeklySummaryLastPosted"

    /// A week's growth below this is not worth interrupting anyone for.
    static let floor: Int64 = 2 * 1_073_741_824
    private static let period: TimeInterval = 7 * 24 * 60 * 60

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Called after each background scan. Posts at most once every seven days,
    /// and only when System Data has grown by more than the floor since a scan
    /// about a week old.
    static func check(log: ScanHistory.Log, at now: Date = .now) async {
        guard isEnabled, LowSpaceAlert.isAvailable else { return }
        if let last = UserDefaults.standard.object(forKey: lastPostedKey) as? Date,
           now.timeIntervalSince(last) < period { return }
        guard let change = ScanHistory.totalChange(overPastDays: 7, in: log),
              change.delta >= floor else { return }

        let content = UNMutableNotificationContent()
        content.title = L("System Data grew %@ this week", change.delta.byteString)
        if let top = ScanHistory.fastestGrowing(in: log, limit: 1).first {
            content.body = L("Mostly %@, up %@.", top.name, top.bytes.byteString)
        } else {
            content.body = L("Open Unpacked to see what grew.")
        }
        content.sound = .default

        let request = UNNotificationRequest(identifier: "weekly-summary", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
        UserDefaults.standard.set(now, forKey: lastPostedKey)
    }
}
