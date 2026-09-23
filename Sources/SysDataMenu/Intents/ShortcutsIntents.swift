import AppIntents
import Foundation

/// Frees the Safe, password-free items — the same set the low-space button
/// frees — so the clean can run on a schedule from Shortcuts. Nothing that
/// needs review or a password is ever in it, which is what makes it fit to
/// run without anyone watching.
struct FreeSafeItemsIntent: AppIntent {
    static let title: LocalizedStringResource = "Free Safe Items"
    static let description = IntentDescription(
        "Scans System Data and deletes the items marked Safe — caches that regenerate on their own. Nothing that needs review or a password is touched."
    )

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        // Inside the running app, the app's own model: the list and the
        // widget then show what the Shortcut freed instead of going stale.
        let model = MainWindow.shared.model ?? ScanModel(scansAutomatically: false)
        await model.scan()
        // `scan()` returns at once when one is already under way, and the
        // list it is building is not the whole picture yet.
        guard !model.isScanning else {
            return .result(value: 0, dialog: "System Data Unpacked is still scanning. Try again when it finishes.")
        }
        let before = model.reclaimedBytes
        await model.reclaimSafeNow()
        let freed = model.reclaimedBytes - before
        return .result(value: Int(freed), dialog: "Freed \(freed.byteString).")
    }
}

/// System Data's current size, for a shortcut that decides what to do next.
struct SystemDataSizeIntent: AppIntent {
    static let title: LocalizedStringResource = "Get System Data Size"
    static let description = IntentDescription("Scans and returns how much System Data this app found, in bytes.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let model = ScanModel(scansAutomatically: false)
        await model.scan()
        return .result(value: Int(model.measuredBytes), dialog: "System Data: \(model.measuredBytes.byteString).")
    }
}

struct SystemDataShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: FreeSafeItemsIntent(),
            phrases: ["Free safe items with \(.applicationName)"],
            shortTitle: "Free Safe Items",
            systemImageName: "internaldrive"
        )
        AppShortcut(
            intent: SystemDataSizeIntent(),
            phrases: ["How much System Data in \(.applicationName)"],
            shortTitle: "System Data Size",
            systemImageName: "chart.bar"
        )
    }
}
