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
    @NSApplicationDelegateAdaptor(PowerOffGuard.self) private var powerOffGuard
    @State private var model = ScanModel()
    /// The same preference `ScanModel` stores, read through `@AppStorage`
    /// because that is what makes this scene re-evaluate when it changes.
    @AppStorage(ScanModel.menuBarIconKey) private var showsMenuBarIcon = true

    init() {
        // No Dock icon while the app is only a menu bar item; MainWindow puts
        // one there as soon as the window opens or the icon is switched off.
        NSApplication.shared.setActivationPolicy(.accessory)
        Updater.unhide(Bundle.main.bundleURL)
        MainWindow.shared.use(model)
    }

    var body: some Scene {
        MenuBarExtra(isInserted: $showsMenuBarIcon) {
            MenuView()
                .environment(model)
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.window)
    }

    /// The drive glyph, and beside it whichever number the person chose to
    /// keep an eye on. System Data is the default because it is the figure the
    /// app exists to surface; free space and icon-only are the alternatives.
    @ViewBuilder
    private var menuBarLabel: some View {
        switch model.menuBarContent {
        case .systemData:
            if model.measuredBytes >= 100 * ProbeSupport.megabyte {
                labelWithValue(model.measuredBytes.byteString,
                               help: L("System Data found: %@", model.measuredBytes.byteString))
            } else {
                Image(systemName: "internaldrive")
            }
        case .freeSpace:
            labelWithValue(model.freeBytes.byteString,
                           help: L("%@ free on disk", model.freeBytes.byteString))
        case .iconOnly:
            Image(systemName: "internaldrive")
        }
    }

    private func labelWithValue(_ value: String, help: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "internaldrive")
            Text(value).monospacedDigit()
        }
        .help(help)
    }
}
