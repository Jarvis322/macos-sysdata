import Foundation
import Testing
@testable import SysDataMenu

/// The README says the source is published so anyone can see what the app does
/// to their machine. This is that promise inside the app, at the one moment it
/// matters: before the administrator password is typed.
@Suite struct PlanTests {
    @Test func deletionsNameEveryPath() {
        let action = ReclaimAction.removePaths([
            URL(fileURLWithPath: "/tmp/one"), URL(fileURLWithPath: "/tmp/two"),
        ])
        #expect(action.plan.count == 2)
        #expect(action.plan.allSatisfy { $0.contains("/tmp/") })
        #expect(!action.needsAdministrator)
    }

    @Test func commandsAreShownAsTheyWillBeRun() {
        let action = ReclaimAction.command(executable: "/usr/bin/xcrun", arguments: ["simctl", "delete", "X"])
        #expect(action.plan == ["/usr/bin/xcrun simctl delete X"])
    }

    /// The one the disclosure exists for.
    @Test func aPrivilegedScriptIsShownVerbatimAndFlagged() {
        let action = ReclaimAction.privilegedScript("rm -rf '/Library/Caches/x'")
        #expect(action.needsAdministrator)
        let line = try! #require(action.plan.first)
        #expect(line.contains("rm -rf '/Library/Caches/x'"), "the command must not be summarised away")
    }

    @Test func aStepListShowsEveryStepAndInheritsTheFlag() {
        let action = ReclaimAction.steps([
            .shutdownSimulators,
            .removePaths([URL(fileURLWithPath: "/tmp/a")]),
            .privilegedScript("rm -rf /tmp/b"),
        ])
        #expect(action.plan.count == 3)
        #expect(action.needsAdministrator, "a batch that needs a password must say so")
    }

    @Test func aManualItemHasNothingToRun() {
        #expect(ReclaimAction.manual("Do it yourself").plan.isEmpty)
    }

    /// Turkish puts the folder before the day count, so its translation uses
    /// positional specifiers. If those were not honoured the line would come
    /// out with the number and the path swapped.
    @Test func theTurkishPruneLineKeepsItsArgumentsInTheRightPlaces() throws {
        // The catalogue value itself, not whatever the test host's locale
        // happens to be: in English the arguments are already in order, so
        // running that proves nothing about the reordered translation.
        let table = try #require(
            Bundle.module.url(forResource: "Localizable", withExtension: "strings", subdirectory: "tr.lproj")
        )
        let strings = try #require(
            NSDictionary(contentsOf: table) as? [String: String]
        )
        let format = try #require(strings["Delete files older than %lld days in %@"])
        #expect(format.contains("%2$@") && format.contains("%1$lld"),
                "Turkish puts the folder first, so the translation must be positional")

        let text = String(format: format, locale: Locale(identifier: "tr"), 3, "/tmp/logs")

        #expect(text.contains("3"))
        #expect(text.contains("/tmp/logs"))
        #expect(!text.contains("%"), "an unsubstituted specifier means the format did not match")
        #expect(text.range(of: "/tmp/logs")!.lowerBound < text.range(of: "3")!.lowerBound,
                "the folder comes before the number in Turkish")
    }
}
