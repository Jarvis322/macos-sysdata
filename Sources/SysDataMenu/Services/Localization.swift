import Foundation

/// Looks up interface strings in the package's string catalog.
func L(_ key: String.LocalizationValue, _ arguments: CVarArg...) -> String {
    let format = String(localized: key, bundle: .resources)
    return arguments.isEmpty ? format : String(format: format, locale: .current, arguments: arguments)
}

extension Bundle {
    /// The SwiftPM resource bundle, wherever this build keeps it.
    ///
    /// SwiftPM's generated `Bundle.module` only looks next to the executable
    /// and at the absolute build path of the machine that compiled the app,
    /// so a shipped .app crashes on every other Mac. The app bundle keeps the
    /// resources under Contents/Resources; look there first, then fall back
    /// to `Bundle.module` for `swift run` and tests.
    nonisolated static let resources: Bundle = {
        let name = "SysDataMenu_SysDataMenu.bundle"
        let candidates = [Bundle.main.resourceURL, Bundle.main.bundleURL]
        for candidate in candidates {
            if let url = candidate?.appending(path: name), let bundle = Bundle(url: url) {
                return bundle
            }
        }
        return .module
    }()
}
