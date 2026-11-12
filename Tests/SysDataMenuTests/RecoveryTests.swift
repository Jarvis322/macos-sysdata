import Foundation
import Testing
@testable import SysDataMenu

/// Whether a deleted item comes back, and whether that needs a network.
/// The one mistake that matters is promising a local rebuild for something
/// that needs a download, to someone who is about to go offline.
@Suite struct RecoveryTests {
    private func item(_ id: String, _ category: StorageCategory, folder: String = "x") -> StorageItem {
        let url = URL(fileURLWithPath: "/tmp/project/\(folder)")
        return StorageItem(id: id, category: category, name: id, detail: "", sizeBytes: 1,
                           safety: .review, action: .removePaths([url]), revealURL: url)
    }

    @Test func buildOutputRebuildsButDependenciesNeedTheNetwork() {
        #expect(item("project-a", .projects, folder: ".next").recovery == .rebuilds)
        #expect(item("xcode-deriveddata-App-abc", .xcode).recovery == .rebuilds)
        #expect(item("project-b", .projects, folder: "node_modules").recovery == .downloads)
        #expect(item("project-c", .projects, folder: "Pods").recovery == .downloads)
        // .build holds the package checkouts SwiftPM fetched.
        #expect(item("project-d", .projects, folder: ".build").recovery == .downloads)
    }

    @Test func sdksModelsAndPackageCachesNeedTheNetwork() {
        for id in ["pkg-npm", "pkg-brew", "runtime-iOS-27-2", "ai-ollama-llama3:latest", "android-ndk-29.0",
                   "android-image-android-35", "tool-.nvm/versions", "xcode-app-Xcode-16.app", "docker-images"] {
            #expect(item(id, .packages).recovery == .downloads, "\(id)")
        }
    }

    @Test func whatNothingRecreatesIsNeverPromisedBack() {
        for id in ["backup-0000", "vm-/Users/x/Parallels/Win.pvm", "sim-erase-ABCD", "docker-volumes",
                   "trash", "app-support-Notion", "app-group-group.x", "tool-hidden-.foo", "other-/Users/x/big",
                   "tool-.claude", "xcode-Archives", "jetbrains-old-PyCharm2023.2", "chat-group.net.whatsapp"] {
            #expect(item(id, .apps).recovery == .gone, "\(id)")
        }
    }

    @Test func logsAndTemporaryFilesAreNotNeeded() {
        for id in ["log-user", "log-unified", "temp-tmp", "temp-cache", "sys-vm", "sim-unavailable-ABCD"] {
            #expect(item(id, .logs).recovery == .notNeeded, "\(id)")
        }
    }

    /// An unrecognised cache is assumed to be a download: a needless warning
    /// costs less than a false promise.
    @Test func unknownCachesAreTreatedAsDownloads() {
        #expect(item("app-cache-com.example.app", .apps).recovery == .downloads)
        #expect(item("tool-cache-something", .tools).recovery == .downloads)
    }
}
