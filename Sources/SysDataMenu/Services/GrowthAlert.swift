import Foundation
import UserNotifications

/// Alerts when one storage category grows far beyond its recent median.
///
/// This runs only after the app's daily background scan. It does not inspect
/// any new locations or send data away; it compares the history already kept
/// on the Mac. One category is reported at a time, and it must grow by another
/// 2 GB before the same category can interrupt again.
enum GrowthAlert {
    private static let enabledKey = "unusualGrowthAlertsEnabled"
    private static let alertedSizesKey = "unusualGrowthAlertedSizes"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static func check(log: ScanHistory.Log) async {
        guard isEnabled, LowSpaceAlert.isAvailable else { return }

        let anomalies = ScanHistory.unusualCategoryGrowth(in: log)
        var alertedSizes = loadAlertedSizes()
        alertedSizes = alertedSizes.filter { stored in
            anomalies.contains { $0.category.rawValue == stored.key }
        }

        guard let anomaly = anomalies.first(where: {
            anomaly in shouldPost(
                currentBytes: anomaly.currentBytes,
                lastNotifiedBytes: alertedSizes[anomaly.category.rawValue]
            )
        }) else {
            saveAlertedSizes(alertedSizes)
            return
        }

        let content = UNMutableNotificationContent()
        content.title = L("Unusual storage growth")
        content.body = L("%@ grew %@ beyond its recent size.", anomaly.category.title, anomaly.growthBytes.byteString)
        content.sound = .default
        content.threadIdentifier = "storage-growth"

        let request = UNNotificationRequest(
            identifier: "storage-growth-\(anomaly.category.rawValue)", content: content, trigger: nil
        )
        guard (try? await UNUserNotificationCenter.current().add(request)) != nil else { return }

        alertedSizes[anomaly.category.rawValue] = anomaly.currentBytes
        saveAlertedSizes(alertedSizes)
    }

    private static let floor: Int64 = 2 * 1_073_741_824

    static func shouldPost(currentBytes: Int64, lastNotifiedBytes: Int64?) -> Bool {
        guard let lastNotifiedBytes else { return true }
        return currentBytes >= lastNotifiedBytes && currentBytes - lastNotifiedBytes >= floor
    }

    private static func loadAlertedSizes() -> [String: Int64] {
        guard let data = UserDefaults.standard.data(forKey: alertedSizesKey),
              let sizes = try? JSONDecoder().decode([String: Int64].self, from: data) else { return [:] }
        return sizes
    }

    private static func saveAlertedSizes(_ sizes: [String: Int64]) {
        guard let data = try? JSONEncoder().encode(sizes) else { return }
        UserDefaults.standard.set(data, forKey: alertedSizesKey)
    }
}
