import Foundation
import Testing
@testable import SysDataMenu

/// Every probe runs against the real machine, so only invariants are checked:
/// probes must not throw or hang, and what they return must be well-formed.
@Suite struct ProbeTests {
    private let probes: [(String, any StorageProbe)] = [
        ("snapshots", SnapshotProbe()), ("simulators", SimulatorProbe()), ("runtimes", RuntimeProbe()),
        ("xcode", XcodeProbe()), ("packages", PackageProbe()), ("tools", DeveloperToolProbe()),
        ("logs", LogProbe()), ("temp", TempProbe()), ("docker", DockerProbe()), ("trash", TrashProbe()),
        ("backups", BackupProbe()), ("shared", SharedProbe()), ("android", AndroidProbe()),
        ("apps", AppDataProbe()), ("projects", ProjectProbe()), ("system", SystemProbe()),
    ]

    @Test func itemsAreWellFormed() async {
        var seen: Set<String> = []
        var all: [StorageItem] = []
        for (label, probe) in probes {
            let items = await probe.probe()
            all += items
            check(items, label: label, seen: &seen)
        }
        let catchAll = await LargeFolderProbe(claimed: all.flatMap(\.claimedURLs)).probe()
        check(catchAll, label: "other", seen: &seen)
        all += catchAll

        // Inventory of this machine, for whoever reads the test log.
        let total = all.reduce(0) { $0 + ($1.sizeBytes ?? 0) }
        print("Inventory: \(all.count) items, \(total.byteString)")
        for item in all.sorted(by: { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }) {
            print("  \(item.sizeBytes?.byteString ?? "?")\t\(item.category.rawValue)\t\(item.name)")
        }
    }

    private func check(_ items: [StorageItem], label: String, seen: inout Set<String>) {
        for item in items {
                #expect(!item.id.isEmpty, "\(label): empty id")
                #expect(!item.name.isEmpty, "\(label): empty name")
                #expect(!item.detail.isEmpty, "\(label): empty detail for \(item.name)")
                #expect(seen.insert(item.id).inserted, "\(label): duplicate id \(item.id)")
                if let size = item.sizeBytes {
                    #expect(size > 0, "\(label): zero-size item \(item.name) should have been dropped")
                }
                #expect(item.action.isManual == (item.safety == .manual),
                        "\(label): \(item.name) mixes manual safety with a runnable action")
                if let url = item.revealURL {
                    #expect(url.isFileURL, "\(label): reveal URL is not a file URL")
                }
        }
    }

    @Test func directorySizeMatchesWrittenBytes() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "sysdata-size-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "nested"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data(count: 10_000).write(to: root.appending(path: "a.bin"))
        try Data(count: 20_000).write(to: root.appending(path: "nested/b.bin"))

        let measured = DiskSize.allocatedSync(at: root)
        // Allocated size rounds up to filesystem blocks, so allow one block per file.
        #expect(measured >= 30_000 && measured <= 30_000 + 2 * 4096)
    }

    @Test func shellQuotingSurvivesSingleQuotes() {
        #expect(Shell.shellQuote("/tmp/it's here") == "'/tmp/it'\\''s here'")
    }

    @Test func whichFindsSystemTools() {
        #expect(Shell.which("tmutil") == "/usr/bin/tmutil")
        #expect(Shell.which("definitely-not-a-tool") == nil)
    }
}
