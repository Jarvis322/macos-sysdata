import AppKit

/// Shuts booted simulators down when the Mac starts to power off.
///
/// A booted simulator's `launchd_sim` ignores SIGTERM, so launchd waits its
/// full 33 second exit timeout before killing it and the whole shutdown
/// stalls for that long. This app is a login item, so it is around to run
/// `simctl shutdown all` the moment loginwindow announces the power off, and
/// it delays its own termination until that finished.
@MainActor
final class PowerOffGuard: NSObject, NSApplicationDelegate {
    static let preferenceKey = "shutsDownSimulatorsAtPowerOff"
    private static let deadline: Duration = .seconds(25)

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: preferenceKey) }
    }

    private var shutdownTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceWillPowerOff),
            name: NSWorkspace.willPowerOffNotification,
            object: nil
        )
    }

    @objc private func workspaceWillPowerOff(_ notification: Notification) {
        guard Self.isEnabled, shutdownTask == nil else { return }
        shutdownTask = Task {
            _ = try? await Shell.run("/usr/bin/xcrun", ["simctl", "shutdown", "all"])
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let shutdownTask else { return .terminateNow }
        Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await shutdownTask.value }
                group.addTask { try? await Task.sleep(for: Self.deadline) }
                await group.next()
                group.cancelAll()
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
