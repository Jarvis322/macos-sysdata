import Darwin
import Foundation

/// Shrinks a folder without deleting anything in it, using the compression
/// macOS applies to its own files: the data stays where it is, the kernel
/// decompresses it on read, and no app can tell the difference.
///
/// Measured on a developer Mac: node_modules 586 → 319 MB, DerivedData
/// 413 → 214 MB, Xcode archives 20 → 13 MB, Apple's own SDKs 0%, since they
/// ship compressed already.
///
/// There is no public API that compresses a file in place, so the folder is
/// copied with `ditto --hfsCompression` beside itself, the copy is checked
/// against the original, and the two are swapped in one atomic rename. A
/// failure at any step leaves the original exactly as it was.
enum FolderCompression {
    struct Outcome: Equatable, Sendable {
        /// Allocated bytes on disk before and after.
        let before: Int64
        let after: Int64

        var saved: Int64 { max(before - after, 0) }
    }

    enum Refusal: LocalizedError, Equatable {
        /// Hard links and APFS clones share their blocks with another file.
        /// A compressed copy of one stops sharing, and the disk fills up by
        /// what the two had in common — the opposite of what was asked. A
        /// pnpm `node_modules` is made of hard links into the store.
        case sharesBlocks(name: String)
        case alreadyCompressed(name: String)
        case notEnoughSpace(name: String)
        case changedDuringCopy(name: String)
        case unsupportedVolume
        case copyFailed(name: String, reason: String)

        var errorDescription: String? {
            switch self {
            case .sharesBlocks(let name):
                L("%@ shares files with other folders, so compressing it could take more space. It was left as it was.", name)
            case .alreadyCompressed(let name):
                L("%@ is already stored compressed.", name)
            case .notEnoughSpace(let name):
                L("There is not enough free space to shrink %@ safely. It needs room for a compressed copy first.", name)
            case .changedDuringCopy(let name):
                L("%@ changed while it was being shrunk, so it was left as it was.", name)
            case .unsupportedVolume:
                L("This drive cannot store compressed files.")
            case .copyFailed(let name, let reason):
                L("%1$@ could not be shrunk: %2$@", name, reason)
            }
        }
    }

    /// What one walk of a folder found.
    struct Survey: Equatable, Sendable {
        var files = 0
        var logicalBytes: Int64 = 0
        var allocatedBytes: Int64 = 0
        /// Logical bytes in files the file system already stores compressed.
        var compressedLogicalBytes: Int64 = 0
        /// Logical bytes in files with more than one hard link.
        var hardLinkedBytes: Int64 = 0
        /// A file whose blocks are, right now, all shared with another: a
        /// clone nobody has modified.
        var hasLiveClone = false
        var newestModification: Date?

        /// Whether a compressed copy would stop sharing enough to make the
        /// disk fuller. A few stray hard links cost next to nothing; a pnpm
        /// tree made of them would cost the whole store again.
        var sharesBlocks: Bool {
            hasLiveClone || Double(hardLinkedBytes) > Double(logicalBytes) * 0.01
        }
    }

    /// Below this share of compressed data a folder is worth the copy.
    static let alreadyCompressedShare = 0.8
    /// Room kept free beyond the copy itself, so shrinking never brings the
    /// disk to the edge it is meant to move it away from.
    static let freeSpaceMargin: Int64 = 1_073_741_824

    /// Shrinks `folder` and returns what it took before and after. Runs off
    /// the main actor; throws a `Refusal` without touching the folder when
    /// it is not safe or not worth doing.
    static func shrink(
        _ folder: URL, freeSpace: Int64 = DiskSize.freeSpace(), journal: UserDefaults = .standard
    ) async throws -> Outcome {
        let name = folder.lastPathComponent
        let values = try? folder.resourceValues(forKeys: [.volumeSupportsCompressionKey])
        guard values?.volumeSupportsCompression == true else { throw Refusal.unsupportedVolume }

        let original = await Task.detached(priority: .utility) { survey(folder) }.value
        if original.sharesBlocks { throw Refusal.sharesBlocks(name: name) }
        if original.logicalBytes == 0
            || Double(original.compressedLogicalBytes) / Double(original.logicalBytes) >= alreadyCompressedShare {
            throw Refusal.alreadyCompressed(name: name)
        }
        guard freeSpace >= original.allocatedBytes + freeSpaceMargin else {
            throw Refusal.notEnoughSpace(name: name)
        }

        // Hidden and beside the original, so the swap is a rename on one
        // volume and Finder never shows the copy.
        let copy = folder.deletingLastPathComponent()
            .appending(path: ".\(name).sysdata-shrink-\(UUID().uuidString)")
        // Written down before the copy exists, so a crash at any point
        // leaves a note of what to clean up at the next launch.
        record(copy, inProgress: true, in: journal)
        defer {
            try? FileManager.default.removeItem(at: copy)
            if !FileManager.default.fileExists(atPath: copy.path) {
                record(copy, inProgress: false, in: journal)
            }
        }

        // `--noclone` is what makes this work: on APFS, ditto otherwise clones
        // each file and the compression step never runs.
        let result = try await Shell.run(
            "/usr/bin/ditto", ["--noclone", "--hfsCompression", folder.path, copy.path],
            timeout: .seconds(3600)
        )
        guard result.succeeded, !result.timedOut else {
            throw Refusal.copyFailed(name: name, reason: result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let (copied, now) = await Task.detached(priority: .utility) { (survey(copy), survey(folder)) }.value
        // The copy has to hold exactly what the original holds, and the
        // original must not have moved on while it was being copied.
        guard now == original else { throw Refusal.changedDuringCopy(name: name) }
        guard copied.files == original.files, copied.logicalBytes == original.logicalBytes else {
            throw Refusal.copyFailed(name: name, reason: L("The compressed copy did not match the original."))
        }
        // Not worth a swap: the data was already dense (media, archives).
        guard Double(copied.allocatedBytes) < Double(original.allocatedBytes) * 0.95 else {
            throw Refusal.alreadyCompressed(name: name)
        }

        guard renamex_np(folder.path, copy.path, UInt32(RENAME_SWAP)) == 0 else {
            throw Refusal.copyFailed(name: name, reason: String(cString: strerror(errno)))
        }
        // The deferred removal now deletes the original, uncompressed tree.
        return Outcome(before: original.allocatedBytes, after: copied.allocatedBytes)
    }

    // MARK: Leftovers

    /// Copies being written or swapped right now. A shrink cut short — the
    /// app quit, crashed or the Mac lost power — leaves its copy beside the
    /// folder: a partial compressed copy before the swap, the old original
    /// after it. The folder itself is whole either way, because the swap is
    /// one rename, so the copy is always safe to delete.
    static let journalKey = "shrinkCopiesInProgress"
    private static let journalLock = NSLock()

    private static func record(_ copy: URL, inProgress: Bool, in defaults: UserDefaults) {
        journalLock.withLock {
            var paths = Set(defaults.stringArray(forKey: journalKey) ?? [])
            if inProgress { paths.insert(copy.path) } else { paths.remove(copy.path) }
            defaults.set(paths.sorted(), forKey: journalKey)
        }
    }

    /// Whether a path is named the way `shrink` names its copies. Nothing
    /// else is ever deleted from the journal, whatever it says.
    static func isShrinkCopy(_ url: URL) -> Bool {
        url.lastPathComponent.wholeMatch(of: /\..+\.sysdata-shrink-[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}/) != nil
    }

    /// Deletes the copies an interrupted shrink left behind. Called once at
    /// launch. Returns what it removed.
    @discardableResult
    static func removeLeftovers(in defaults: UserDefaults = .standard) -> [URL] {
        let paths = journalLock.withLock { defaults.stringArray(forKey: journalKey) ?? [] }
        var removed: [URL] = []
        for path in paths {
            let copy = URL(fileURLWithPath: path)
            // Called at launch, before this app can have started a shrink of
            // its own, so nothing on the list is still being written.
            if isShrinkCopy(copy), FileManager.default.fileExists(atPath: copy.path) {
                guard (try? FileManager.default.removeItem(at: copy)) != nil else { continue }
                removed.append(copy)
            }
            record(copy, inProgress: false, in: defaults)
        }
        return removed
    }

    /// Walks `folder` without following links, the way `DiskSize` does.
    static func survey(_ folder: URL) -> Survey {
        var survey = Survey()
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }
        ) else { return survey }

        for case let url as URL in enumerator {
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
            survey.files += 1
            survey.logicalBytes += Int64(info.st_size)
            survey.allocatedBytes += Int64(info.st_blocks) * 512
            if info.st_flags & UInt32(UF_COMPRESSED) != 0 {
                survey.compressedLogicalBytes += Int64(info.st_size)
            }
            if info.st_nlink > 1 {
                survey.hardLinkedBytes += Int64(info.st_size)
            }
            if !survey.hasLiveClone, sharesAllBlocks(url.path) {
                survey.hasLiveClone = true
            }
            let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            if modified > (survey.newestModification ?? .distantPast) {
                survey.newestModification = modified
            }
        }
        return survey
    }

    /// Whether APFS says every block of the file is shared with another.
    ///
    /// Not `EF_MAY_SHARE_BLOCKS`: that stays set on every file that was ever
    /// cloned, long after the other copy is gone. Measured on one Mac, all
    /// 35,368 files of a node_modules and all 11,163 of an Android SDK carried
    /// it, and not one of them still shared a block.
    private static func sharesAllBlocks(_ path: String) -> Bool {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        request.forkattr = attrgroup_t(ATTR_CMNEXT_EXT_FLAGS)
        // length, returned-attributes set, then the 64-bit flags.
        var buffer = [UInt8](repeating: 0, count: 64)
        let options = UInt32(FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED)
        guard getattrlist(path, &request, &buffer, buffer.count, options) == 0 else { return false }
        let flags = buffer.withUnsafeBytes { bytes in
            bytes.loadUnaligned(fromByteOffset: MemoryLayout<UInt32>.size + MemoryLayout<attribute_set_t>.size,
                                as: UInt64.self)
        }
        return flags & UInt64(EF_SHARES_ALL_BLOCKS) != 0
    }
}
