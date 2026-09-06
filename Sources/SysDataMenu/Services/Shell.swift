import Foundation

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
    /// Runs a program and captures its output. `mergeStderr` folds stderr into
    /// the output; pass `false` when the output must be parsed as JSON.
    static func run(
        _ executable: String,
        _ arguments: [String],
        mergeStderr: Bool = true
    ) async throws -> CommandResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = environment

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = mergeStderr ? pipe : FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice

            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            return CommandResult(
                status: process.terminationStatus,
                output: String(decoding: data, as: UTF8.self)
            )
        }.value
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

    private static let searchPath: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var directories = [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
            "\(home)/.cargo/bin", "\(home)/.local/bin", "\(home)/Library/pnpm",
        ]
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
