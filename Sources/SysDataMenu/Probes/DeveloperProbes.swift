import Foundation

private let xcrun = "/usr/bin/xcrun"

// MARK: - Time Machine local snapshots

/// APFS keeps hourly Time Machine snapshots on the boot volume. Finder counts
/// their blocks as System Data and APFS refuses to report their size.
struct SnapshotProbe: StorageProbe {
    func probe() async -> [StorageItem] {
        guard let result = try? await Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: Shell.probeTimeout) else { return [] }
        let count = result.output
            .split(separator: "\n")
            .filter { $0.contains("com.apple.TimeMachine") }
            .count
        guard count > 0 else { return [] }

        return [StorageItem(
            id: "snapshots",
            category: .snapshots,
            name: "\(count) local snapshot\(count == 1 ? "" : "s")",
            detail: "Hidden APFS snapshots kept between Time Machine runs. Size is not reported by APFS; the next backup recreates one.",
            sizeBytes: nil,
            safety: .safe,
            action: .privilegedScript("tmutil deletelocalsnapshots / ; tmutil thinlocalsnapshots / 9999999999999 4")
        )]
    }
}

// MARK: - Simulator devices

struct SimulatorProbe: StorageProbe {
    private let root = URL.home("Library/Developer/CoreSimulator")

    func probe() async -> [StorageItem] {
        var items: [StorageItem] = []
        var cacheDirectories: [URL] = []
        var cacheBytes: Int64 = 0
        var deviceCount = 0

        if let json = await ProbeSupport.json(xcrun, ["simctl", "list", "devices", "-j"]),
           let byRuntime = json["devices"] as? [String: [[String: Any]]] {
            for (runtime, devices) in byRuntime {
                for device in devices {
                    guard let name = device["name"] as? String,
                          let udid = device["udid"] as? String,
                          let dataPath = device["dataPath"] as? String else { continue }
                    let dataSize = (device["dataPathSize"] as? NSNumber)?.int64Value
                    let available = device["isAvailable"] as? Bool ?? false
                    let runtimeName = runtime.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")

                    if !available {
                        items.append(StorageItem(
                            id: "sim-unavailable-\(udid)",
                            category: .simulators,
                            name: "Unavailable: \(name)",
                            detail: "Its runtime (\(runtimeName)) is no longer installed, so this device can never boot.",
                            sizeBytes: dataSize,
                            safety: .safe,
                            action: .command(executable: xcrun, arguments: ["simctl", "delete", udid]),
                            revealURL: URL(fileURLWithPath: dataPath)
                        ))
                        continue
                    }

                    deviceCount += 1
                    let data = URL(fileURLWithPath: dataPath)
                    let deviceCaches = [data.appending(path: "Library/Caches"), data.appending(path: "tmp")]
                        .filter(\.exists)
                    cacheDirectories += deviceCaches
                    var deviceCacheBytes: Int64 = 0
                    for directory in deviceCaches { deviceCacheBytes += await DiskSize.allocated(at: directory) }
                    cacheBytes += deviceCacheBytes
                    // The device's caches are their own row above; counted in
                    // the erase row as well, the total said the same bytes twice.
                    let eraseBytes = dataSize.map { max($0 - deviceCacheBytes, 0) }

                    // Erasing keeps the device, so an erased one comes back on
                    // the next scan at a few megabytes and reads as a delete
                    // that did not happen. Below this there is nothing to reset.
                    if let eraseBytes, eraseBytes < 100 * ProbeSupport.megabyte { continue }

                    items.append(StorageItem(
                        id: "sim-erase-\(udid)",
                        category: .simulators,
                        name: "Erase \(name)",
                        detail: "Resets this \(runtimeName) simulator to factory state. Installed apps and their data are lost.",
                        sizeBytes: eraseBytes,
                        safety: .review,
                        action: .eraseSimulator(udid: udid),
                        revealURL: data
                    ))
                }
            }
        }

        let sharedDyld = root.appending(path: "Caches/dyld")
        if sharedDyld.exists {
            cacheDirectories.append(sharedDyld)
            cacheBytes += await DiskSize.allocated(at: sharedDyld)
        }

        if !cacheDirectories.isEmpty {
            let total = cacheBytes
            if total > 0 {
                items.insert(StorageItem(
                    id: "sim-caches",
                    category: .simulators,
                    name: "Device caches (\(deviceCount) devices)",
                    detail: "Per-device Caches and tmp plus the shared dyld cache. Rebuilt on the next boot.",
                    sizeBytes: total,
                    safety: .safe,
                    action: .steps([.shutdownSimulators, .emptyDirectories(cacheDirectories)]),
                    revealURL: root.appending(path: "Devices")
                ), at: 0)
            }
        }

        // macOS refuses to unlink anything under this folder, even for root
        // (verified on macOS 26: rm as uid 0 returns EPERM on an empty
        // subdirectory). Only CoreSimulator's own daemon can remove it, which
        // happens when the runtime it belongs to is deleted.
        let systemDyld = URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Caches/dyld")
        if let item = await ProbeSupport.directoryItem(
            id: "sim-system-dyld",
            category: .simulators,
            name: "System dyld cache",
            detail: "One shared cache per installed runtime, built by CoreSimulator. Protected by macOS: it goes away with its runtime, not on its own.",
            url: systemDyld,
            safety: .manual,
            action: .manual("Delete the runtime it belongs to (Simulator runtimes above), or:\nxcrun simctl runtime delete <UUID>\nThe cache is rebuilt when the runtime is installed again."),
            minimumBytes: 50 * ProbeSupport.megabyte
        ) {
            items.append(item)
        }

        return items
    }
}

// MARK: - Simulator runtimes

struct RuntimeProbe: StorageProbe {
    func probe() async -> [StorageItem] {
        guard let json = await ProbeSupport.json(xcrun, ["simctl", "runtime", "list", "-j"]) else { return [] }
        // Which runtime each installed SDK builds against, and which runtimes
        // still have a simulator on them. Either answer missing means nothing
        // is claimed about use at all: "unused" has to be known, not guessed.
        let chosenBuilds = await ProbeSupport.json(xcrun, ["simctl", "runtime", "match", "list", "-j"])
            .map(Self.chosenBuilds)
        let devices = await ProbeSupport.json(xcrun, ["simctl", "list", "devices", "-j"])?["devices"] as? [String: [Any]]

        return json.compactMap { identifier, value -> StorageItem? in
            guard let runtime = value as? [String: Any],
                  runtime["deletable"] as? Bool ?? false,
                  let version = runtime["version"] as? String,
                  let build = runtime["build"] as? String else { return nil }
            let platform = platformName(runtime["platformIdentifier"] as? String ?? "")
            let size = (runtime["sizeBytes"] as? NSNumber)?.int64Value
            // simctl knows when a runtime was last booted, which is a truer
            // answer than any file date under the image: mounting it for a
            // build touches nothing the way running a simulator does.
            let lastUsedAt = (runtime["lastUsedAt"] as? String).flatMap(Self.parseTimestamp)
            let lastUsed = (runtime["lastUsedAt"] as? String).map { "Last used \($0.prefix(10)). " } ?? ""
            let unused = chosenBuilds.map { chosen in
                Self.isUnused(
                    build: build, runtimeIdentifier: runtime["runtimeIdentifier"] as? String,
                    chosenBuilds: chosen, devices: devices
                )
            } ?? false
            let detail = unused
                ? "\(lastUsed)No installed Xcode builds against this runtime, and no simulator is on it. Xcode > Settings > Components downloads it again if you ever need it."
                : "\(lastUsed)Simulators on this runtime stop working. Xcode > Settings > Components downloads it again."

            return StorageItem(
                id: "runtime-\(identifier)",
                category: .runtimes,
                name: unused ? "\(platform) \(version) (\(build)) · unused" : "\(platform) \(version) (\(build))",
                detail: detail,
                sizeBytes: size,
                safety: .review,
                action: .command(executable: xcrun, arguments: ["simctl", "runtime", "delete", identifier]),
                revealURL: (runtime["path"] as? String).map { URL(fileURLWithPath: $0) },
                lastModified: lastUsedAt
            )
        }
        .sorted { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
    }

    /// The runtime builds the installed SDKs are matched to, from
    /// `simctl runtime match list -j`.
    static func chosenBuilds(from match: [String: Any]) -> Set<String> {
        Set(match.values.compactMap { ($0 as? [String: Any])?["chosenRuntimeBuild"] as? String })
    }

    /// A runtime no installed SDK is matched to, with no simulator on it, is
    /// one nothing on this Mac can reach: building for the platform picks a
    /// different one, and there is no device to boot. Several gigabytes each,
    /// and they pile up — every Xcode update downloads a new one and leaves
    /// the old one where it was.
    ///
    /// Without the device list, nothing is claimed: a runtime whose devices
    /// could not be counted might have some.
    static func isUnused(
        build: String, runtimeIdentifier: String?,
        chosenBuilds: Set<String>, devices: [String: [Any]]?
    ) -> Bool {
        guard !chosenBuilds.contains(build), let devices, let runtimeIdentifier else { return false }
        return devices[runtimeIdentifier]?.isEmpty ?? true
    }

    /// simctl reports ISO-8601 in UTC, today without fractional seconds.
    /// Both spellings are accepted so a future Xcode adding them does not
    /// silently drop the date.
    static func parseTimestamp(_ text: String) -> Date? {
        (try? Date(text, strategy: .iso8601))
            ?? (try? Date(text, strategy: .iso8601.time(includingFractionalSeconds: true)))
    }

    private func platformName(_ identifier: String) -> String {
        switch identifier {
        case "com.apple.platform.iphonesimulator": "iOS"
        case "com.apple.platform.watchsimulator": "watchOS"
        case "com.apple.platform.appletvsimulator": "tvOS"
        case "com.apple.platform.xrsimulator": "visionOS"
        default: identifier.components(separatedBy: ".").last ?? identifier
        }
    }
}

// MARK: - Xcode

struct XcodeProbe: StorageProbe {
    private let root = URL.home("Library/Developer/Xcode")

    func probe() async -> [StorageItem] {
        var items: [StorageItem] = []

        let entries: [(String, String, String, Safety)] = [
            ("DerivedData", "DerivedData", "Build products and indexes. Rebuilt on the next build.", .safe),
            ("iOS DeviceSupport", "iOS DeviceSupport", "Symbols copied from connected iPhones and iPads. Copied again on the next connection.", .safe),
            ("watchOS DeviceSupport", "watchOS DeviceSupport", "Symbols copied from connected watches.", .safe),
            ("tvOS DeviceSupport", "tvOS DeviceSupport", "Symbols copied from connected Apple TVs.", .safe),
            ("visionOS DeviceSupport", "visionOS DeviceSupport", "Symbols copied from connected Vision Pro devices.", .safe),
            ("Preview simulators", "UserData/Previews/Simulator Devices", "Devices SwiftUI previews spin up. Recreated on demand.", .safe),
            ("Archives", "Archives", "Release archives with dSYMs. Keep any build you still need to symbolicate crashes for.", .review),
        ]

        for (name, relative, detail, safety) in entries {
            let url = root.appending(path: relative)
            if let item = await ProbeSupport.directoryItem(
                id: "xcode-\(relative)", category: .xcode, name: name, detail: detail,
                url: url, safety: safety, action: .emptyDirectories([url])
            ) {
                items.append(item)
            }
        }

        let caches = URL.home("Library/Caches/com.apple.dt.Xcode")
        if let item = await ProbeSupport.directoryItem(
            id: "xcode-caches", category: .xcode, name: "Xcode caches",
            detail: "Documentation and download caches.", url: caches,
            safety: .safe, action: .emptyDirectories([caches]), minimumBytes: ProbeSupport.megabyte
        ) {
            items.append(item)
        }

        // Without an answer there is no telling which Xcode is in use, and
        // offering the active one for deletion is the mistake to avoid.
        guard let active = await ProbeSupport.activeDeveloperDirectory() else { return items }
        for app in URL(fileURLWithPath: "/Applications").children()
        where app.lastPathComponent.hasPrefix("Xcode") && app.pathExtension == "app" && !active.hasPrefix(app.path) {
            if let item = await ProbeSupport.directoryItem(
                id: "xcode-app-\(app.lastPathComponent)", category: .xcode,
                name: "Inactive \(app.lastPathComponent)",
                detail: "Not the selected developer directory (\(active)).",
                url: app, safety: .review, action: .removePaths([app])
            ) {
                items.append(item)
            }
        }

        return items
    }
}
