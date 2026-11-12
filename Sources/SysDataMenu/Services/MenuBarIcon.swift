import AppKit

/// The menu bar icon as a status item the app can hide and show.
///
/// `MenuBarExtra(isInserted:)` is read when the scene is built: changing the
/// preference afterwards did not take the icon out of the menu bar on macOS
/// 26, and a published scene value did not either. The extra now stays
/// inserted and the status item behind it is hidden instead.
///
/// SwiftUI has no public accessor for that status item. It is reached through
/// the window `MenuBarExtra` creates for it, the same way the menu bar extra
/// helpers do. A status item can be rebuilt when SwiftUI updates the extra,
/// so the preference is also re-applied by a short timer and by KVO on the
/// item's own `isVisible`; keep all of that in this one place.
@MainActor
enum MenuBarIcon {
    /// What the preference asks for, even while no item exists yet.
    private static var isWanted = true
    private static var timer: Timer?

    static func apply(_ visible: Bool, attempt: Int = 0) {
        isWanted = visible
        enforce()
        if visible {
            stopWatching()
        } else {
            startWatching()
        }

        // The item is created with the scene, a moment after launch.
        if items().isEmpty, attempt < 40 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                MainActor.assumeIsolated {
                    apply(visible, attempt: attempt + 1)
                }
            }
        }
    }

    private static func enforce() {
        for item in items() where item.isVisible != isWanted {
            item.isVisible = isWanted
        }
    }

    /// The status item can be replaced when SwiftUI rebuilds the extra. The
    /// timer is what hides a replacement; a few times a second is enough, and
    /// it only changes an item that is in the wrong state.
    private static func startWatching() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
            Task { @MainActor in
                enforce()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private static func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    private static func items() -> [NSStatusItem] {
        NSApplication.shared.windows
            .filter { $0.className.contains("NSStatusBarWindow") }
            .compactMap { window in
                window.value(forKey: "statusItem") as? NSStatusItem
            }
            .filter { item in
                // A second display gets a replicant, which is not the item
                // that can be hidden.
                item.className == "NSStatusItem" || item.className == "NSSceneStatusItem"
            }
    }
}
