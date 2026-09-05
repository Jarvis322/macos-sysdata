import Foundation

/// Looks up interface strings in the package's string catalog. SwiftUI's
/// implicit lookup only searches `Bundle.main`, which for a SwiftPM
/// executable is not where the catalog lives.
func L(_ key: String.LocalizationValue, _ arguments: CVarArg...) -> String {
    let format = String(localized: key, bundle: .module)
    return arguments.isEmpty ? format : String(format: format, locale: .current, arguments: arguments)
}
