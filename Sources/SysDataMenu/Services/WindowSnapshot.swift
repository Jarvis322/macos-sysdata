import AppKit
import SwiftUI

/// `SysDataMenu --screenshot out.png` renders the menu window offscreen with
/// a real scan, so the README image is reproducible without clicking.
@MainActor
enum WindowSnapshot {
    static func write(to path: String) async {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: .darkAqua)

        let model = ScanModel(scansAutomatically: false)
        await model.scan()
        render(model: model, to: path)
    }

    /// Synchronous on purpose: pumping the run loop is not allowed from an
    /// async function, and SwiftUI needs a few turns to lay the list out.
    private static func render(model: ScanModel, to path: String) {
        let size = NSSize(width: 460, height: 640)
        let appearance = NSAppearance(named: .darkAqua)
        // The menu bar panel paints its own material; offscreen there is
        // none, so give the view an opaque window background to draw on.
        let root = MenuView()
            .environment(model)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = appearance
        let window = NSWindow(
            contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false
        )
        window.appearance = appearance
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        // Ordering the window in (offscreen, behind everything) makes AppKit
        // actually display it, which is what the layer-backed text needs.
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderBack(nil)

        for _ in 0..<8 {
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
        }

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            FileHandle.standardError.write(Data("could not create bitmap\n".utf8))
            return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            print("wrote \(path) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        }
    }
}
