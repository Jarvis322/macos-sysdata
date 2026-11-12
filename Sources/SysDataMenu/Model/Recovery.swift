import Foundation

/// What it takes to get an item back after it is deleted.
///
/// Asked for by someone about to work offline: the gigabytes on the
/// confirmation say what a delete frees, and this says which of them would
/// need a network to come back. Where a row could go either way it is put in
/// the less hopeful group. Telling someone on a plane that a folder will
/// rebuild when it needs a download is the mistake to avoid; the opposite
/// costs nothing.
enum Recovery: Sendable, CaseIterable {
    /// Recreated on this Mac by the tool that made it: build products,
    /// indexes, thumbnails.
    case rebuilds
    /// Comes back, but only with a network: package caches, SDKs, models,
    /// dependencies.
    case downloads
    /// Nothing will ask for it again: logs, temporary files, swap.
    case notNeeded
    /// Nothing recreates it: backups, virtual machines, app data, anything
    /// this app cannot name.
    case gone

    var label: String {
        switch self {
        case .rebuilds: L("Rebuilds on this Mac")
        case .downloads: L("Downloads again")
        case .notNeeded: L("Not needed again")
        case .gone: L("Doesn't come back")
        }
    }

    var symbol: String {
        switch self {
        case .rebuilds: "arrow.triangle.2.circlepath"
        case .downloads: "arrow.down.circle"
        case .notNeeded: "checkmark.circle"
        case .gone: "exclamationmark.circle"
        }
    }
}

extension StorageItem {
    var recovery: Recovery { Recovery.of(self) }
}

extension Recovery {
    /// Folders inside a project that its own build recreates without a
    /// download. node_modules, Pods and .build are not among them: each holds
    /// fetched dependencies.
    private static let localBuildOutput: Set<String> = [
        ".next", ".nuxt", ".svelte-kit", ".astro", ".angular", ".turbo", ".parcel-cache", ".expo", "DerivedData",
    ]

    /// Caches an app fills from the network as it is used.
    private static let networkCaches: Set<String> = [
        "cache-slack", "cache-slack-sw", "cache-discord", "cache-teams", "cache-spotify", "cache-safari",
        "cache-steam", "cache-epic", "cache-zoom", "cache-adobe-cc",
    ]

    /// Caches built from files already on this Mac.
    private static let localCaches: Set<String> = [
        "cache-quicklook", "cache-photos-cache", "cache-adobe-media", "cache-adobe-caches", "cache-xcode-device-logs",
        "sim-caches", "sim-system-dyld", "sys-library-caches", "sys-spotlight", "xcode-caches",
    ]

    /// Toolchains, SDKs and caches a version manager or package manager
    /// downloads again on request.
    private static let downloadedTools: Set<String> = [
        "tool-.lmstudio", "tool-.nvm/versions", "tool-.rustup/toolchains", "tool-.pyenv/versions",
        "tool-.rbenv/versions", "tool-.sdkman/candidates", "tool-.conda/pkgs", "tool-.m2/repository",
        "tool-.ivy2", "tool-.cocoapods/repos", "tool-.gradle/wrapper/dists", "tool-.android/cache",
        "tool-go/pkg/mod", "tool-.bun/install/cache", "tool-.npm/_npx", "tool-.deno", "tool-.vscode/extensions",
        "tool-.cursor/extensions", "tool-.antigravity-ide/extensions", "tool-.cache/torch",
    ]

    static func of(_ item: StorageItem) -> Recovery {
        let id = item.id

        // Logs, temporary files and memory images: nothing reads them back.
        if id.hasPrefix("log-") || id.hasPrefix("temp-") || id == "sys-vm" || id.hasPrefix("sim-unavailable-") {
            return .notNeeded
        }

        if localCaches.contains(id) || id.hasPrefix("jetbrains-caches-") || id.hasPrefix("android-studio-cache-")
            || id.hasPrefix("fcp-renders-") || id.hasPrefix("xcode-deriveddata-") || id == "xcode-DerivedData"
            || id == "docker-build-cache" || id.hasSuffix("DeviceSupport")
            || id == "xcode-UserData/Previews/Simulator Devices" {
            return .rebuilds
        }

        if id.hasPrefix("project-"), let folder = item.revealURL?.lastPathComponent {
            return localBuildOutput.contains(folder) ? .rebuilds : .downloads
        }

        if networkCaches.contains(id) || downloadedTools.contains(id) || id.hasPrefix("pkg-")
            || id.hasPrefix("runtime-") || id.hasPrefix("ai-") || id == "app-claude-vm" || id == "app-chrome-model"
            || id.hasPrefix("android-image-") || id.hasPrefix("android-platforms-") || id.hasPrefix("android-build-tools-")
            || id.hasPrefix("android-ndk-") || id.hasPrefix("android-cmake-") || id.hasPrefix("android-sources-")
            || ["android-emulator", "android-cmdline-tools", "android-platform-tools", "android-extras", "android-skins"].contains(id)
            || id.hasPrefix("unity-cache") || id.hasPrefix("unity-Asset Store") || id.hasPrefix("xcode-app-")
            || id == "docker-images" || id.hasPrefix("docker-project-images-")
            || id.hasPrefix("sys-ipsw-") || id.hasPrefix("sys-installer-") || id == "sys-clt"
            || id == "sys-icloud" || id == "sys-mail-downloads"
            // Generic caches are mostly downloads, and a cache that turns out
            // to be local only costs the person a needless warning.
            || id.hasPrefix("tool-cache-") || id.hasPrefix("app-cache-") {
            return .downloads
        }

        // Backups, virtual machines, simulator data, app data, volumes, the
        // Trash, old IDE settings and everything the catch-all found.
        return .gone
    }
}
