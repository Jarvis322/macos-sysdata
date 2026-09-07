import Foundation
import Testing
@testable import SysDataMenu

/// A key nothing calls is either a string that was dropped by mistake or one
/// that outlived its screen. Both are worth noticing: moving the preferences
/// into a menu silently took the explanation off four of them, including the
/// one saying the update check is the only request this app makes, and nothing
/// failed.
@Suite struct CatalogueTests {
    @Test func everyKeyInTheCatalogueIsUsedInTheCode() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appending(path: "Sources")

        let catalogue = try #require(
            JSONSerialization.jsonObject(
                with: try Data(contentsOf: sources.appending(path: "SysDataMenu/Resources/Localizable.xcstrings"))
            ) as? [String: Any]
        )
        let keys = try #require(catalogue["strings"] as? [String: Any]).keys

        var code = ""
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift" else { continue }
            code += (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        }

        let orphans = keys.filter { !code.contains("\"\($0)\"") }.sorted()
        #expect(orphans.isEmpty, "in the catalogue but not in the interface: \(orphans)")
    }
}
