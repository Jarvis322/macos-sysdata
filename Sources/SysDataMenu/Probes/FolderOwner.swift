import Foundation

/// The apps on this Mac, by bundle identifier and by name, read from their
/// Info.plist files. Enough to say who a folder belongs to, and — the more
/// useful answer — when the app that made it is gone.
struct InstalledApps: Sendable {
    let namesByIdentifier: [String: String]
    let names: [String]

    private static let locations = [
        URL(fileURLWithPath: "/Applications"),
        URL(fileURLWithPath: "/Applications/Utilities"),
        URL(fileURLWithPath: "/System/Applications"),
        URL(fileURLWithPath: "/System/Applications/Utilities"),
        URL.home("Applications"),
    ]

    static func current() -> InstalledApps {
        var byIdentifier: [String: String] = [:]
        var names: [String] = []
        for location in locations {
            for app in location.children() where app.pathExtension == "app" {
                let name = app.deletingPathExtension().lastPathComponent
                names.append(name)
                let plist = app.appending(path: "Contents/Info.plist")
                if let info = NSDictionary(contentsOf: plist),
                   let identifier = info["CFBundleIdentifier"] as? String {
                    byIdentifier[identifier.lowercased()] = name
                }
            }
        }
        return InstalledApps(namesByIdentifier: byIdentifier, names: names)
    }
}

/// Says who made a folder the app otherwise cannot explain.
///
/// "Other large folders" was the biggest category nobody could act on: 19 GB
/// on the Mac this was written on, every row saying only that it was not
/// recognised. Most of those folders carry their owner in their path — a
/// bundle identifier under Containers or Caches, an app's own name under
/// Application Support — and the answer that matters most is the one where
/// that app is no longer installed, because nothing else will ever clean up
/// after it.
enum FolderOwner {
    /// A sentence ending in a full stop, or nil when the path does not say.
    /// English, like every other row's detail and the `--json` output.
    static func describe(_ url: URL, apps: InstalledApps) -> String? {
        let components = url.standardizedFileURL.pathComponents
        if let known = known(components) { return known }

        // ~/Library/<parent>/<owner>/…
        guard let libraryIndex = components.lastIndex(of: "Library"),
              components.count > libraryIndex + 2 else { return nil }
        let parent = components[libraryIndex + 1]
        let owner = components[libraryIndex + 2]
        guard ["Application Support", "Containers", "Group Containers", "Caches", "Logs", "HTTPStorages",
               "WebKit", "Saved Application State"].contains(parent) else { return nil }

        if looksLikeBundleIdentifier(owner) {
            let identifier = strippedTeamPrefix(owner).lowercased()
            if let name = apps.namesByIdentifier[identifier] {
                return "Belongs to \(name)."
            }
            return "Left by \(owner), which is no longer installed on this Mac."
        }
        if let name = apps.names.first(where: { $0 == owner })
            ?? apps.names.first(where: { $0.hasPrefix(owner + " ") }) {
            return "Belongs to \(name)."
        }
        return nil
    }

    /// Folders macOS itself keeps, which no bundle identifier gives away.
    private static func known(_ components: [String]) -> String? {
        guard let libraryIndex = components.lastIndex(of: "Library"),
              components.count > libraryIndex + 1 else { return nil }
        if components[libraryIndex + 1] == "Metadata" {
            return "Spotlight's index of this Mac's files and app content. macOS maintains it; excluding folders in System Settings > Spotlight makes it smaller."
        }
        return nil
    }

    /// `com.example.app`, `group.com.example`, or a team-prefixed
    /// `ABCDE12345.com.example.shared`.
    static func looksLikeBundleIdentifier(_ name: String) -> Bool {
        let parts = name.split(separator: ".")
        return parts.count >= 3 && !name.contains(" ")
    }

    /// Group containers are named after the team, not the app:
    /// `UBF8T346G9.Office` or `group.com.apple.notes`.
    private static func strippedTeamPrefix(_ name: String) -> String {
        let parts = name.split(separator: ".")
        if let first = parts.first, first.count == 10, first.allSatisfy({ $0.isUppercase || $0.isNumber }) {
            return parts.dropFirst().joined(separator: ".")
        }
        if parts.first == "group" { return parts.dropFirst().joined(separator: ".") }
        return name
    }
}
