import Darwin
import Foundation
import Testing

@testable import SysDataMenu

/// The temporary-folder item promised "only files older than 3 days are
/// removed", and removed every socket, pipe and link in $TMPDIR regardless of
/// age: anything that was not a regular file was treated as a directory and
/// deleted once empty, which a socket always is. On the Mac this was found on
/// that meant 48 live entries, VS Code's git sockets among them.
struct PruneTests {
    private let directory: URL

    init() throws {
        directory = URL.temporaryDirectory.appending(path: "prune-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func path(_ name: String) -> URL { directory.appending(path: name) }

    private func makeFile(_ name: String, daysOld: Double) throws {
        let url = path(name)
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-daysOld * 86_400)], ofItemAtPath: url.path
        )
    }

    private func makeSocket(_ name: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path(name).path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.prefix(buffer.count - 1).enumerated() {
                buffer[index] = UInt8(bitPattern: byte)
            }
        }
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return fd
    }

    private func exists(_ name: String) -> Bool {
        var info = stat()
        return lstat(path(name).path, &info) == 0
    }

    @Test func onlyOldRegularFilesAreRemoved() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try makeFile("old.log", daysOld: 10)
        try makeFile("new.log", daysOld: 0)
        try FileManager.default.createDirectory(at: path("lock.d"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: path("current"), withDestinationURL: URL(fileURLWithPath: "/tmp"))
        #expect(mkfifo(path("live.fifo").path, 0o600) == 0)
        let socket = makeSocket("live.sock")
        defer { close(socket) }
        #expect(exists("live.sock"), "the socket should exist before the prune")

        try await Reclaimer.perform(.pruneOlderThan(directory, days: 3))

        #expect(!exists("old.log"))
        #expect(exists("new.log"))
        #expect(exists("lock.d"), "an empty directory holds no data and may be in use")
        #expect(exists("current"), "a link holds no data")
        #expect(exists("live.fifo"))
        #expect(exists("live.sock"), "a live socket belongs to a running app")
    }
}
