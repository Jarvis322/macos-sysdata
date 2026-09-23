import Foundation
import os

struct CommandResult: Sendable {
    let status: Int32
    let output: String

    var succeeded: Bool { status == 0 }
}

struct CommandError: LocalizedError {
    let command: String
    let result: CommandResult

    /// osascript reports a dismissed authorization dialog as -128. The message
    /// is localized by the system; the number is not, so match on the number.
    var wasCancelled: Bool { result.output.contains("(-128)") }

    var errorDescription: String? {
        // osascript prefixes shell failures with "12:345: execution error: ".
        let trimmed = result.output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^\d+:\d+: execution error: "#, with: "", options: .regularExpression)
        return trimmed.isEmpty ? "\(command) failed (exit \(result.status))" : trimmed
    }
}

enum Shell {
    /// How long a scan waits on another program before giving up on it. A
    /// scan is a list of questions, and one that never gets an answer —
    /// `docker info` while Docker Desktop is starting, `simctl` while
    /// CoreSimulator is wedged — used to leave the whole window on
    /// "Measuring…" for as long as that program chose to hang.
    static let probeTimeout: Duration = .seconds(20)

    /// Runs a program and captures its output. `mergeStderr` folds stderr into
    /// the output; pass `false` when the output must be parsed as JSON. With a
    /// `timeout`, a program still running when it expires is terminated and
    /// the result is a failure. Deletions pass none: an erase or a password
    /// prompt takes as long as it takes.
    static func run(
        _ executable: String,
        _ arguments: [String],
        mergeStderr: Bool = true,
        timeout: Duration? = nil
    ) async throws -> CommandResult {
        try await Task.detached(priority: .userInitiated) {
            try runBlocking(executable, arguments, mergeStderr: mergeStderr, timeout: timeout)
        }.value
    }

    /// The blocking half of `run`, kept synchronous because it waits on the
    /// pipe and the process; it only ever runs on the detached task above.
    private static func runBlocking(
        _ executable: String, _ arguments: [String], mergeStderr: Bool, timeout: Duration?
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = mergeStderr ? pipe : FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        // Read as it arrives rather than to the end of the pipe. A child
        // the program started — a version manager's shim runs the real
        // tool — keeps the pipe open after the program itself is killed,
        // and reading to the end then waited for that child, timeout or
        // not.
        let output = OSAllocatedUnfairLock(initialState: Data())
        let ended = DispatchSemaphore(value: 0)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                ended.signal()
            } else {
                output.withLock { $0.append(chunk) }
            }
        }

        try process.run()
        // The process identifier rather than the Process: the timer runs
        // on another queue, and a pid is a plain number to hand across.
        let pid = process.processIdentifier
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let deadline = timeout.map { limit in
            let item = DispatchWorkItem {
                timedOut.withLock { $0 = true }
                kill(pid, SIGTERM)
            }
            let seconds = Double(limit.components.seconds) + Double(limit.components.attoseconds) / 1e18
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: item)
            return item
        }
        process.waitUntilExit()
        deadline?.cancel()
        if timedOut.withLock({ $0 }) {
            // Whatever still holds the pipe is not waited for.
            pipe.fileHandleForReading.readabilityHandler = nil
        } else {
            ended.wait()
        }

        return CommandResult(
            status: process.terminationStatus,
            output: String(decoding: output.withLock { $0 }, as: UTF8.self)
        )
    }

    /// Runs a shell snippet as root through the system authorization dialog.
    static func runPrivileged(_ script: String) async throws -> CommandResult {
        let escaped = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        return try await run("/usr/bin/osascript", ["-e", source])
    }

    /// Finds a tool the way a login shell would, without depending on the
    /// (empty) PATH a GUI process inherits.
    static func which(_ name: String) -> String? {
        for directory in searchPath {
            let candidate = "\(directory)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Not private: which directories are searched decides whether a tool
    /// reads as absent, and for pnpm that decides whether its store is offered
    /// for deletion.
    static var searchPathForTesting: [String] { searchPath }

    private static let searchPath: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var directories = [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
            "\(home)/.cargo/bin", "\(home)/.local/bin", "\(home)/Library/pnpm",
            // Version managers put their shims outside the usual prefixes. A
            // GUI process inherits no PATH, so missing these does not mean
            // "not on this Mac" — it means "not looked for", and the app acts
            // on the difference: a tool it cannot find loses its own prune
            // command, and a pnpm it cannot find makes the store look
            // abandoned.
            "\(home)/.volta/bin",
            "\(home)/.asdf/shims",
            "\(home)/.local/share/mise/shims",
            "\(home)/Library/Application Support/fnm/aliases/default/bin",
            "\(home)/.bun/bin",
            "\(home)/.deno/bin",
        ]
        // nvm keeps one directory per Node version and a `default` alias
        // naming the current one.
        if let version = try? String(contentsOf: URL(fileURLWithPath: "\(home)/.nvm/alias/default"), encoding: .utf8) {
            let version = version.trimmingCharacters(in: .whitespacesAndNewlines)
            if !version.isEmpty {
                let prefix = version.hasPrefix("v") ? version : "v\(version)"
                directories.append("\(home)/.nvm/versions/node/\(prefix)/bin")
            }
        }
        if let inherited = ProcessInfo.processInfo.environment["PATH"] {
            directories += inherited.split(separator: ":").map(String.init)
        }
        return directories
    }()

    private static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath.joined(separator: ":")
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        return env
    }()
}
