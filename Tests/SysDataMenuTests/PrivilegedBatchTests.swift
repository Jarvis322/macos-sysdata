import Foundation
import Testing

@testable import SysDataMenu

/// Scripts that need root run as one, under one password prompt. Joined with
/// ` ; `, a shell reports only the last one's status: a failure in the middle
/// went unreported, and a failure at the end was blamed on every item.
struct PrivilegedBatchTests {
    /// The combined script run for real, without root: `false` stands in for
    /// a step that fails.
    private func run(_ scripts: [String]) async throws -> CommandResult {
        try await Shell.run("/bin/sh", ["-c", ScanModel.combinedPrivilegedScript(scripts)])
    }

    @Test func aBatchThatSucceedsReportsNothing() async throws {
        let result = try await run(["true", "true", "true"])
        #expect(result.succeeded)
        #expect(ScanModel.failedIndices(in: result.output) == nil)
    }

    @Test func aFailureInTheMiddleIsNoLongerHidden() async throws {
        let result = try await run(["true", "false", "true"])
        #expect(!result.succeeded, "the last step succeeding used to make the batch look fine")
        #expect(ScanModel.failedIndices(in: result.output) == [1])
    }

    @Test func onlyTheStepsThatFailedAreBlamed() async throws {
        let result = try await run(["true", "false", "true", "exit 3"])
        #expect(ScanModel.failedIndices(in: result.output) == [1, 3])
    }

    /// A step with its own `;` keeps its own meaning inside its subshell.
    @Test func aStepWithItsOwnSemicolonStaysOneStep() async throws {
        let result = try await run(["false ; true", "true"])
        #expect(result.succeeded)
    }

    /// What osascript actually hands back: lines separated by \r, the step's
    /// own error first, and the exit status appended in brackets.
    @Test func theMarkerIsReadFromOsascriptOutput() {
        let output = "rm: /Library/Caches/com.apple.aned: Operation not permitted\rSYSDATA_FAILED: 3 (1)"
        #expect(ScanModel.failedIndices(in: output) == [3])
        #expect(ScanModel.withoutFailureMarker(output) == "rm: /Library/Caches/com.apple.aned: Operation not permitted")
    }

    @Test func noMarkerMeansTheBatchNeverFinished() {
        #expect(ScanModel.failedIndices(in: "User canceled. (-128)") == nil)
    }
}
