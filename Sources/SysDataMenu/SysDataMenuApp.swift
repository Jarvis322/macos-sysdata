import AppKit
import SwiftUI

@main
enum Entry {
    static func main() async {
        // `--json` turns the binary into a scanner for scripts: no UI, the
        // full inventory on stdout, exit.
        if CommandLine.arguments.contains("--json") {
            await JSONInventory.write(to: FileHandle.standardOutput)
            return
        }
        SysDataMenuApp.main()
    }
}

struct SysDataMenuApp: App {
    @State private var model = ScanModel()

    init() {
        // Menu bar only: no Dock icon, no main window.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environment(model)
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.window)
    }

    /// Drive glyph plus what can be freed right now, so the number is visible
    /// without opening the window.
    @ViewBuilder
    private var menuBarLabel: some View {
        if model.safeBytes >= 100 * ProbeSupport.megabyte {
            HStack(spacing: 3) {
                Image(systemName: "internaldrive")
                Text(model.safeBytes.byteString)
                    .monospacedDigit()
            }
        } else {
            Image(systemName: "internaldrive")
        }
    }
}
