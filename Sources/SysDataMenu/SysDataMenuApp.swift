import AppKit
import SwiftUI

@main
struct SysDataMenuApp: App {
    @State private var model = ScanModel()

    init() {
        // Menu bar only: no Dock icon, no main window.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra("System Data", systemImage: "internaldrive") {
            MenuView()
                .environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}
