import Foundation
import Testing
@testable import SysDataMenu

/// The app was renamed in 1.0.5, and the updater used to look inside the
/// downloaded image for its own file name, which a renamed image does not
/// contain. It now finds the app by bundle identifier; these pin that, and
/// that the hidden old-name copy kept for earlier updaters is not preferred.
@Suite struct AppInImageTests {
    private func makeImage() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "sysdata-image-\(UUID().uuidString)")
        for (folder, identifier, hidden) in [
            ("System Data Unpacked.app", "test.sysdata", false),
            ("SysDataMenu.app", "test.sysdata", true),
            ("Someone Else.app", "test.other", false),
        ] {
            let contents = root.appending(path: "\(folder)/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: contents.appending(path: "Info.plist"))
            if hidden {
                var values = URLResourceValues()
                values.isHidden = true
                var bundle = root.appending(path: folder)
                try bundle.setResourceValues(values)
            }
        }
        return root
    }

    @Test func findsTheVisibleAppByIdentifier() throws {
        let image = try makeImage()
        defer { try? FileManager.default.removeItem(at: image) }
        let found = try #require(Updater.app(in: image, identifier: "test.sysdata"))
        #expect(found.lastPathComponent == "System Data Unpacked.app")
    }

    /// The copy an old updater installs from the image arrives hidden, and the
    /// app unhides itself on launch rather than staying out of Finder.
    @Test func aHiddenInstallIsUnhidden() throws {
        let image = try makeImage()
        defer { try? FileManager.default.removeItem(at: image) }
        let legacy = image.appending(path: "SysDataMenu.app")
        #expect(Updater.unhide(legacy), "the hidden copy should have been changed")
        #expect(try legacy.resourceValues(forKeys: [.isHiddenKey]).isHidden == false)
        #expect(!Updater.unhide(legacy), "a visible bundle is left alone")
    }

    @Test func ignoresAppsFromAnotherIdentifier() throws {
        let image = try makeImage()
        defer { try? FileManager.default.removeItem(at: image) }
        #expect(Updater.app(in: image, identifier: "test.missing") == nil)
    }
}
