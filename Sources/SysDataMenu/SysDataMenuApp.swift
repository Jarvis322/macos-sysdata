import AppKit
import SwiftUI

@main
enum Entry {
    static func main() async {
        // `--json` turns the binary into a scanner for scripts: no UI, the
        // full inventory on stdout, exit.
        let arguments = CommandLine.arguments
        if arguments.contains("--json") {
            await JSONInventory.write(to: FileHandle.standardOutput)
            return
        }
        if let index = arguments.firstIndex(of: "--screenshot"), arguments.indices.contains(index + 1) {
            await WindowSnapshot.write(to: arguments[index + 1])
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

    /// Drive glyph plus the size of everything the scan found, the same
    /// number Storage settings calls "System Data".
    @ViewBuilder
    private var menuBarLabel: some View {
        if model.measuredBytes >= 100 * ProbeSupport.megabyte {
            HStack(spacing: 3) {
                Image(systemName: "internaldrive")
                Text(model.measuredBytes.byteString)
                    .monospacedDigit()
            }
            .help(L("System Data found: %@", model.measuredBytes.byteString))
        } else {
            Image(systemName: "internaldrive")
        }
    }
}
