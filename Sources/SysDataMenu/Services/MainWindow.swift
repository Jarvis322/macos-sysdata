import AppKit
import SwiftUI

/// The app as a window, not only a menu bar item.
///
/// A number you glance at belongs in the menu bar. A list you sit with for
/// ten minutes, scroll, filter and delete from does not, and people asked for
/// the second thing: open it from Applications, and let the menu bar icon go.
/// So the same panel is also a real window, and the icon became a preference.
///
/// The window is AppKit rather than a SwiftUI `Window` scene because it has
/// to be openable from the app delegate — that is where macOS reports a click
/// on the Dock icon or a second launch from Finder — and `openWindow` only
/// exists inside a view.
@MainActor
final class MainWindow: NSObject, NSWindowDelegate {
    static let shared = MainWindow()

    private var window: NSWindow?
    private var model: ScanModel?

    private static let frameName = "SysDataMenuMainWindow"
    private static let defaultSize = NSSize(width: 520, height: 760)
    private static let minimumSize = NSSize(width: 460, height: 520)

    /// Called once at launch. Without it the delegate has a window to open
    /// and nothing to show in it.
    func use(_ model: ScanModel) {
        self.model = model
        syncActivationPolicy(windowIsOpen: window?.isVisible ?? false)
    }

    /// Opens the window at launch when the menu bar icon is switched off,
    /// because otherwise the app would start with nowhere to appear.
    func showIfMenuBarIsHidden() {
        guard let model, !model.showsMenuBarIcon else { return }
        show()
    }

    func show() {
        guard let model else { return }
        let window = self.window ?? make(for: model)
        self.window = window
        syncActivationPolicy(windowIsOpen: true)
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Re-reads the menu bar preference. Turning the icon off has to put the
    /// app in the Dock: an app with no icon and no Dock tile cannot be
    /// reached again, which is not a preference, it is a disappearance.
    func menuBarPreferenceChanged() {
        syncActivationPolicy(windowIsOpen: window?.isVisible ?? false)
    }

    func windowWillClose(_ notification: Notification) {
        syncActivationPolicy(windowIsOpen: false)
    }

    private func syncActivationPolicy(windowIsOpen: Bool) {
        let showsMenuBarIcon = model?.showsMenuBarIcon ?? true
        let policy: NSApplication.ActivationPolicy =
            windowIsOpen || !showsMenuBarIcon ? .regular : .accessory
        NSApplication.shared.setActivationPolicy(policy)
    }

    private func make(for model: ScanModel) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // The panel's own header carries the name and the total, so the title
        // bar would only say it twice. It stays as an empty strip for the
        // traffic lights, and the content runs up underneath it.
        window.title = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? "System Data Unpacked"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentView = NSHostingView(
            rootView: MenuView(presentation: .window).environment(model)
        )
        window.minSize = Self.minimumSize
        window.delegate = self
        // Closing the window must not deallocate it: the menu bar item and the
        // Dock can both ask for it back.
        window.isReleasedWhenClosed = false
        window.center()
        // After `center()`, so a remembered position wins over it.
        window.setFrameAutosaveName(Self.frameName)
        return window
    }
}
