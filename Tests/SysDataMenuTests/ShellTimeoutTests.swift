import Foundation
import Testing

@testable import SysDataMenu

/// A scan asks other programs questions — docker, simctl, tmutil — and one
/// that never answered used to hold the whole scan on "Measuring…".
struct ShellTimeoutTests {
    /// Judged by how the program ended, not by a stopwatch: left alone,
    /// `sleep` exits 0 after thirty seconds, so a failed result can only mean
    /// it was terminated. A wall-clock check also counted the time the task
    /// spent waiting to start while the disk-walking tests ran alongside.
    @Test func aProgramThatHangsIsStoppedAtTheTimeout() async throws {
        let result = try await Shell.run("/bin/sleep", ["30"], timeout: .milliseconds(300))

        #expect(!result.succeeded)
        #expect(result.status == SIGTERM)
    }

    /// A shell that started a child: killing the shell left the child holding
    /// the output pipe, and reading to the end of it waited for the child.
    /// Judged by what reached the output, not by a stopwatch — a wall-clock
    /// bound failed the release run while the disk-walking tests loaded the
    /// machine. The child writes "late" twenty seconds in and only then lets
    /// go of the pipe, so a reader that waited for the pipe to close has it.
    @Test func aChildHoldingThePipeDoesNotOutliveTheTimeout() async throws {
        let result = try await Shell.run(
            "/bin/sh", ["-c", "(sleep 20; echo late) & sleep 60"], timeout: .milliseconds(300)
        )

        #expect(!result.succeeded)
        #expect(!result.output.contains("late"))
    }

    @Test func aProgramThatFinishesInTimeIsUnaffected() async throws {
        let result = try await Shell.run("/bin/echo", ["hello"], timeout: .seconds(10))
        #expect(result.succeeded)
        #expect(result.output == "hello\n")
    }
}
