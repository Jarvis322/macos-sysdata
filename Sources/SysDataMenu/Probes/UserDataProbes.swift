import Foundation

// MARK: - iOS device backups

struct BackupProbe: StorageProbe {
    func probe() async -> [StorageItem] {
        let root = URL.home("Library/Application Support/MobileSync/Backup")
        var items: [StorageItem] = []

        for backup in root.children() where backup.isDirectory {
            let info = NSDictionary(contentsOf: backup.appending(path: "Info.plist")) as? [String: Any]
            let device = info?["Device Name"] as? String ?? backup.lastPathComponent
            let version = info?["Product Version"] as? String ?? "unknown iOS"
            let date = (info?["Last Backup Date"] as? Date).map {
                $0.formatted(date: .abbreviated, time: .omitted)
            } ?? "unknown date"

            if let item = await ProbeSupport.directoryItem(
                id: "backup-\(backup.lastPathComponent)", category: .backups,
                name: device,
                detail: "\(version), last backup \(date). Your only local copy of this device unless it is also in iCloud.",
                url: backup, safety: .review, action: .removePaths([backup])
            ) {
                items.append(item)
            }
        }
        return items
    }
}

// MARK: - /Users/Shared and other accounts

struct SharedProbe: StorageProbe {
    func probe() async -> [StorageItem] {
        var items: [StorageItem] = []
        let shared = URL(fileURLWithPath: "/Users/Shared")
        let minimum = 20 * ProbeSupport.megabyte

        for entry in shared.children() where entry.isDirectory {
            // Apps such as BlueStacks keep their virtual disks under
            // Shared/Library/Application Support; list those individually.
            let appSupport = entry.appending(path: "Application Support")
            let candidates = entry.lastPathComponent == "Library" && appSupport.exists
                ? appSupport.children().filter(\.isDirectory)
                : [entry]

            for candidate in candidates {
                if let item = await ProbeSupport.directoryItem(
                    id: "shared-\(candidate.path)", category: .shared,
                    name: candidate.lastPathComponent,
                    detail: "In /Users/Shared, counted as \"Other Users & Shared\". Owned by the app that created it.",
                    url: candidate, safety: .review, action: .removePaths([candidate]), minimumBytes: minimum
                ) {
                    items.append(item)
                }
            }
        }

        let currentUser = URL.home.lastPathComponent
        for account in URL(fileURLWithPath: "/Users").children()
        where account.isDirectory && account.lastPathComponent != currentUser && account.lastPathComponent != "Shared" {
            let size = await DiskSize.allocated(at: account)
            items.append(StorageItem(
                id: "shared-user-\(account.lastPathComponent)", category: .shared,
                name: "Account: \(account.lastPathComponent)",
                detail: size > 0 ? "Another user's home folder." : "Another user's home folder (not readable from this account).",
                sizeBytes: size > 0 ? size : nil, safety: .manual,
                action: .manual("System Settings > Users & Groups > select the account > remove."),
                revealURL: account
            ))
        }

        return items.sorted { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
    }
}

// MARK: - Android

struct AndroidProbe: StorageProbe {
    func probe() async -> [StorageItem] {
        var items: [StorageItem] = []

        let avdRoot = URL.home(".android/avd")
        for avd in avdRoot.children() where avd.pathExtension == "avd" {
            let ini = avdRoot.appending(path: avd.deletingPathExtension().lastPathComponent + ".ini")
            if let item = await ProbeSupport.directoryItem(
                id: "android-avd-\(avd.lastPathComponent)", category: .android,
                name: "Emulator: \(avd.deletingPathExtension().lastPathComponent)",
                detail: "Android Virtual Device disk. Everything installed on this emulator is lost.",
                url: avd, safety: .review, action: .removePaths([avd, ini])
            ) {
                items.append(item)
            }
        }

        let sdkRoot = ProcessInfo.processInfo.environment["ANDROID_HOME"].map { URL(fileURLWithPath: $0) }
            ?? URL.home("Library/Android/sdk")
        let images = sdkRoot.appending(path: "system-images")
        for api in images.children() where api.isDirectory {
            if let item = await ProbeSupport.directoryItem(
                id: "android-image-\(api.lastPathComponent)", category: .android,
                name: "System image \(api.lastPathComponent)",
                detail: "Emulator OS image. Emulators using it stop booting; SDK Manager can reinstall it.",
                url: api, safety: .review, action: .removePaths([api])
            ) {
                items.append(item)
            }
        }

        // Remaining SDK components. Each is reinstallable from SDK Manager.
        let components: [(String, String)] = [
            ("platforms", "Platform"), ("build-tools", "Build tools"), ("ndk", "NDK"),
            ("cmake", "CMake"), ("sources", "Sources"),
        ]
        for (folder, label) in components {
            for version in sdkRoot.appending(path: folder).children() where version.isDirectory {
                if let item = await ProbeSupport.directoryItem(
                    id: "android-\(folder)-\(version.lastPathComponent)", category: .android,
                    name: "\(label) \(version.lastPathComponent)",
                    detail: "Android SDK component. SDK Manager can reinstall it.",
                    url: version, safety: .review, action: .removePaths([version]),
                    minimumBytes: 20 * ProbeSupport.megabyte
                ) {
                    items.append(item)
                }
            }
        }
        for folder in ["emulator", "cmdline-tools", "platform-tools", "extras", "skins", "licenses"] {
            let url = sdkRoot.appending(path: folder)
            if let item = await ProbeSupport.directoryItem(
                id: "android-\(folder)", category: .android, name: "SDK \(folder)",
                detail: "Android SDK component. SDK Manager can reinstall it.",
                url: url, safety: .review, action: .removePaths([url]), minimumBytes: 20 * ProbeSupport.megabyte
            ) {
                items.append(item)
            }
        }

        let googleCaches = URL.home("Library/Caches/Google")
        for cache in googleCaches.children() where cache.lastPathComponent.hasPrefix("AndroidStudio") {
            if let item = await ProbeSupport.directoryItem(
                id: "android-studio-cache-\(cache.lastPathComponent)", category: .android,
                name: "\(cache.lastPathComponent) caches", detail: "IDE indexes. Rebuilt on next launch.",
                url: cache, safety: .safe, action: .emptyDirectories([cache]), minimumBytes: 10 * ProbeSupport.megabyte
            ) {
                items.append(item)
            }
        }

        return items.sorted { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
    }
}

// MARK: - Large per-app data

/// Finds the folders under ~/Library that are large enough to matter and that
/// no other probe already covers. A few well-known heavy hitters get a proper
/// name and instructions.
struct AppDataProbe: StorageProbe {
    private static let threshold = 200 * ProbeSupport.megabyte
    private static let cacheThreshold = 100 * ProbeSupport.megabyte

    /// Folder names other probes own, so they are not listed twice.
    private static let coveredCaches: Set<String> = [
        "Homebrew", "Yarn", "pip", "CocoaPods", "org.swift.swiftpm", "go-build", "Cypress",
        "ms-playwright", "com.apple.dt.Xcode", "Google", "Adobe", "com.apple.QuickLook.thumbnailcache",
    ]
    private static let coveredAppSupport: Set<String> = [
        "MobileSync", "Claude", "Google", "Slack", "discord", "zoom.us", "Spotify", "Adobe", "Steam", "Epic",
    ]
    private static let coveredContainers: Set<String> = [
        "com.microsoft.teams2", "com.apple.Safari", "com.apple.photolibraryd", "com.utmapp.UTM", "com.apple.mail",
    ]

    func probe() async -> [StorageItem] {
        var items: [StorageItem] = []

        let claudeVM = URL.home("Library/Application Support/Claude/vm_bundles")
        if let item = await ProbeSupport.directoryItem(
            id: "app-claude-vm", category: .apps, name: "Claude local VM bundles",
            detail: "Virtual machine images used by Claude's local sandbox. Downloaded again when the feature is used.",
            url: claudeVM, safety: .review, action: .removePaths([claudeVM]), minimumBytes: Self.threshold
        ) {
            items.append(item)
        }

        let chromeModel = URL.home("Library/Application Support/Google/Chrome/OptGuideOnDeviceModel")
        if let item = await ProbeSupport.directoryItem(
            id: "app-chrome-model", category: .apps, name: "Chrome on-device AI model",
            detail: "Gemini Nano. Set chrome://flags/#optimization-guide-on-device-model to Disabled first, or Chrome downloads it again.",
            url: chromeModel, safety: .review, action: .removePaths([chromeModel]), minimumBytes: Self.threshold
        ) {
            items.append(item)
        }

        items += await scan(
            URL.home("Library/Application Support"), prefix: "app-support", label: "App data",
            detail: "Deleting resets that app.", safety: .review,
            threshold: Self.threshold, skipping: Self.coveredAppSupport
        )
        // Reading another app's container is one TCC prompt per app. Until
        // Full Disk Access is granted these are left alone, so the launch is
        // one banner rather than a queue of dialogs naming Music, Photos and
        // everything else that happens to keep a container.
        if ProbeSupport.hasFullDiskAccess {
        items += await scan(
            URL.home("Library/Containers"), prefix: "app-container", label: "Sandboxed app data",
            detail: "Deleting resets that app.", safety: .review, threshold: Self.threshold,
            skipping: Self.coveredContainers, protectsAppleData: true
        )
        items += await scan(
            URL.home("Library/Group Containers"), prefix: "app-group", label: "App group data",
            detail: "Shared between an app and its extensions. Deleting resets them.", safety: .review,
            threshold: Self.threshold, skipping: [], protectsAppleData: true
        )
        }
        items += await scan(
            URL.home("Library/Caches"), prefix: "app-cache", label: "Cache",
            detail: "Regenerated by the app.", safety: .safe,
            threshold: Self.cacheThreshold, skipping: Self.coveredCaches
        )

        // Google nests Chrome and Android Studio caches one level down; the
        // Android probe owns the Android Studio ones.
        let googleCaches = URL.home("Library/Caches/Google")
        let androidStudio = Set(googleCaches.children().map(\.lastPathComponent).filter { $0.hasPrefix("AndroidStudio") })
        items += await scan(
            googleCaches, prefix: "app-cache-google", label: "Cache",
            detail: "Regenerated by the app.", safety: .safe,
            threshold: Self.cacheThreshold, skipping: androidStudio
        )

        return items.sorted { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
    }

    /// `protectsAppleData` lists Apple's own containers with their size but
    /// never offers to delete them: they hold the local copy of what syncs
    /// with iCloud — Notes, Reminders, Messages — and a delete there can take
    /// data that has not reached the cloud yet.
    private func scan(
        _ root: URL, prefix: String, label: String, detail: String, safety: Safety,
        threshold: Int64, skipping: Set<String>, protectsAppleData: Bool = false
    ) async -> [StorageItem] {
        var items: [StorageItem] = []
        for entry in root.children() where entry.isDirectory && !skipping.contains(entry.lastPathComponent) {
            let isProtected = protectsAppleData && Self.isAppleOwned(entry.lastPathComponent)
            if let item = await ProbeSupport.directoryItem(
                id: "\(prefix)-\(entry.lastPathComponent)", category: .apps,
                name: "\(label): \(entry.lastPathComponent)",
                detail: isProtected ? "Apple app data, some of it synced with iCloud. Not deleted by this app." : detail,
                url: entry,
                safety: isProtected ? .manual : safety,
                action: isProtected ? .manual(Self.appleDataInstructions) : .removePaths([entry]),
                minimumBytes: threshold
            ) {
                items.append(item)
            }
        }
        return items
    }

    /// Whether a container or group container belongs to Apple, by the bundle
    /// or group identifier macOS names it after.
    static func isAppleOwned(_ name: String) -> Bool {
        name.hasPrefix("com.apple.") || name.hasPrefix("group.com.apple.")
    }

    private static let appleDataInstructions = """
        This is Apple's own app data. Part of it is the local copy of what syncs \
        with iCloud, so this app will not delete it. Clear it from the app that \
        owns it, or see System Settings > General > Storage.
        """
}

// MARK: - Project build folders

/// node_modules, .build, Pods and DerivedData folders inside the usual project
/// locations. Finder files most of their contents under System Data.
struct ProjectProbe: StorageProbe {
    private static let roots = ["Desktop", "Documents", "Developer", "Projects", "Projeler"].map(URL.home)
    private static let targets: Set<String> = [
        "node_modules", ".build", "Pods", "DerivedData",
        // Build output of the web frameworks, all of them rebuilt by the
        // project's own build command and none of them worth keeping.
        ".next", ".nuxt", ".svelte-kit", ".astro", ".angular", ".turbo",
        ".parcel-cache", ".expo",
    ]
    private static let maxDepth = 4
    private static let threshold = 30 * ProbeSupport.megabyte

    func probe() async -> [StorageItem] {
        var found: [URL] = []
        // Desktop and Documents are behind TCC; walking them before Full Disk
        // Access exists asks for each one by name. The build folders under
        // them are worth finding, but not at the price of two dialogs during
        // the first ten seconds of the app's life.
        let readable = ProbeSupport.hasFullDiskAccess
            ? Self.roots
            : Self.roots.filter { root in
                !ProbeSupport.protectedLocations.contains { $0.path == root.path }
            }
        for root in readable where root.exists {
            collect(root, depth: 0, into: &found)
        }

        var items: [StorageItem] = []
        for folder in found {
            let project = folder.deletingLastPathComponent()
            let tool: String = switch folder.lastPathComponent {
            case "node_modules": "npm install"
            case ".build": "swift build"
            case "Pods": "pod install"
            case ".next": "next build"
            case ".nuxt": "nuxt build"
            case ".svelte-kit": "vite build"
            case ".astro": "astro build"
            case ".angular", ".turbo", ".parcel-cache", ".expo": "the next build"
            default: "the next build"
            }
            if let item = await ProbeSupport.directoryItem(
                id: "project-\(folder.path)", category: .projects,
                name: "\(project.lastPathComponent)/\(folder.lastPathComponent)",
                detail: "\(project.abbreviatedPath). Recreated by \(tool).",
                url: folder, safety: .review, action: .removePaths([folder]), minimumBytes: Self.threshold
            ) {
                items.append(item)
            }
        }
        return items.sorted { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
    }

    private func collect(_ directory: URL, depth: Int, into found: inout [URL]) {
        guard depth <= Self.maxDepth else { return }
        for child in directory.children(includeHidden: true) where child.isDirectory {
            let name = child.lastPathComponent
            if Self.targets.contains(name) {
                found.append(child)
            } else if !name.hasPrefix(".") && name != "Library" {
                collect(child, depth: depth + 1, into: &found)
            }
        }
    }
}
