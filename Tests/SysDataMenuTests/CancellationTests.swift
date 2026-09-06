import Foundation
import Testing
@testable import SysDataMenu

/// A dismissed authorization dialog has to be told apart from a real failure,
/// because it is the difference between "leave the rest alone" and "carry on
/// deleting". osascript localizes the message, so only the number is reliable.
@Suite struct CancellationTests {
    private func error(_ output: String, status: Int32 = 1) -> CommandError {
        CommandError(command: "rm -rf /tmp/nothing",
                     result: CommandResult(status: status, output: output))
    }

    @Test func recognisesCancellationInEnglish() {
        #expect(error("0:34: execution error: User canceled. (-128)").wasCancelled)
    }

    @Test func recognisesCancellationInOtherLanguages() {
        #expect(error("0:34: execution error: Kullanıcı vazgeçti. (-128)").wasCancelled)
        #expect(error("0:34: execution error: Der Benutzer hat abgebrochen. (-128)").wasCancelled)
    }

    @Test func doesNotMistakeARealFailureForCancellation() {
        #expect(!error("rm: /System/x: Operation not permitted").wasCancelled)
        #expect(!error("0:34: execution error: Something went wrong. (-1728)").wasCancelled)
    }
}
