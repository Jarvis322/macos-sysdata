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
    private var prompt: NSWindow?
    private var model: ScanModel?

    /// Whether the one-time question about where the app should live has been
    /// answered. Closing the question counts as an answer: it is a question,
    /// not a gate, and asking twice would make it one.
    private static let choiceKey = "presentationChoiceMade"

    static var hasChosenPresentation: Bool {
        get { UserDefaults.standard.bool(forKey: choiceKey) }
        set { UserDefaults.standard.set(newValue, forKey: choiceKey) }
    }

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

    /// The one-time question, asked on the first launch of the version that
    /// has a window. Someone who only ever wanted a window should not have to
    /// find a switch to stop the icon appearing.
    func askWherePresentationBelongs() {
        guard !Self.hasChosenPresentation, prompt == nil, model != nil else { return }
        let view = PresentationChoiceView { [weak self] usesWindow in
            self?.answer(usesWindow: usesWindow)
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        // Named for the Window menu, which would otherwise say "Untitled".
        window.title = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? "System Data Unpacked"
        window.center()
        prompt = window
        // The prompt is the only thing on screen at this point, so the app
        // needs a Dock tile and the focus to go with it.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func answer(usesWindow: Bool) {
        Self.hasChosenPresentation = true
        model?.showsMenuBarIcon = !usesWindow
        prompt?.close()
        if usesWindow {
            show()
        } else {
            syncActivationPolicy(windowIsOpen: window?.isVisible ?? false)
        }
    }

    func show() {
        guard let model else { return }
        // While the question is up it is the app: opening the list behind it
        // would answer it on the person's behalf.
        if let prompt {
            NSApplication.shared.activate()
            prompt.makeKeyAndOrderFront(nil)
            return
        }
        let window = self.window ?? make(for: model)
        self.window = window
        syncActivationPolicy(windowIsOpen: true)
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Switches the icon off from the menu bar panel itself.
    ///
    /// The panel belongs to the icon: taking the icon away underneath it
    /// leaves it on screen with nothing behind it. Ordering that panel away
    /// by hand is worse — SwiftUI still believes it is showing, and the icon
    /// comes back stuck in its pressed state, opening nothing. So the window
    /// opens, which takes the focus, and the panel is left to close itself.
    /// The icon goes when it has.
    func openWindowLeavingTheMenuBar() {
        show()
        Task { @MainActor in
            for _ in 0..<15 where hasOpenMenuBarPanel {
                try? await Task.sleep(for: .milliseconds(200))
            }
            // Whether or not it closed: a panel that stays is a smaller
            // problem than a switch that did nothing.
            model?.showsMenuBarIcon = false
            menuBarPreferenceChanged()
        }
    }

    /// Any visible window of this app that is not one of ours: the menu bar
    /// panel, or the menu the switch was thrown from.
    private var hasOpenMenuBarPanel: Bool {
        NSApplication.shared.windows.contains {
            $0 !== window && $0 !== prompt && $0.isVisible
        }
    }

    /// Re-reads the menu bar preference. Turning the icon off has to put the
    /// app in the Dock: an app with no icon and no Dock tile cannot be
    /// reached again, which is not a preference, it is a disappearance.
    func menuBarPreferenceChanged() {
        syncActivationPolicy(windowIsOpen: window?.isVisible ?? false)
    }

    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as AnyObject?
        if closing === prompt {
            // Dismissed without an answer: keep what the app already does,
            // and do not ask again.
            Self.hasChosenPresentation = true
            prompt = nil
        }
        let windowStaysOpen = closing !== window && (window?.isVisible ?? false)
        syncActivationPolicy(windowIsOpen: windowStaysOpen)
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
