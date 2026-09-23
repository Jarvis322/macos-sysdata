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
    /// the output pipe, and reading to the end of it waited the child's full
    /// thirty seconds. The bound is loose on purpose — it only has to tell
    /// "stopped at the timeout" from "waited for the child".
    @Test func aChildHoldingThePipeDoesNotOutliveTheTimeout() async throws {
        let started = ContinuousClock.now
        let result = try await Shell.run("/bin/sh", ["-c", "sleep 30; echo done"], timeout: .milliseconds(300))

        #expect(ContinuousClock.now - started < .seconds(15))
        #expect(!result.succeeded)
        #expect(!result.output.contains("done"))
    }

    @Test func aProgramThatFinishesInTimeIsUnaffected() async throws {
        let result = try await Shell.run("/bin/echo", ["hello"], timeout: .seconds(10))
        #expect(result.succeeded)
        #expect(result.output == "hello\n")
    }
}
