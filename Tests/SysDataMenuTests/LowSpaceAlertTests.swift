import Foundation
import Testing
@testable import SysDataMenu

/// A daily scan on a disk that sits just under the line would post the same
/// warning every day, which is how a useful alert becomes one people switch
/// off. It has to fire on the crossing and then stay quiet.
/// Serialized: these read and write the shared UserDefaults, so running them
/// at the same time makes one test's setup another's surprise.
@Suite(.serialized) struct LowSpaceAlertTests {
    private let stateKey = "lowSpaceWasBelow"

    private func wasBelow() -> Bool { UserDefaults.standard.bool(forKey: stateKey) }
    private func setWasBelow(_ value: Bool) { UserDefaults.standard.set(value, forKey: stateKey) }

    /// The tests run unbundled, where `check` must not touch
    /// UNUserNotificationCenter at all — it raises rather than failing.
    @Test func notificationsAreKnownToBeUnavailableOutsideAnAppBundle() {
        #expect(!LowSpaceAlert.isAvailable, "swift test has no .app around it")
    }

    @Test func checkIsInertWhenNotificationsCannotBeUsed() async {
        LowSpaceAlert.isEnabled = true
        defer { LowSpaceAlert.isEnabled = false }
        setWasBelow(false)

        // Would crash rather than fail if the availability guard were missing.
        await LowSpaceAlert.check(freeBytes: 1, reclaimable: 1)

        #expect(!wasBelow(), "an alert that cannot be posted must not claim it was")
    }

    @Test func itFiresOnTheWayDownAndThenStaysQuiet() {
        let line = 20 * LowSpaceAlert.gigabyte

        // Crossing below for the first time.
        #expect(LowSpaceAlert.shouldPost(freeBytes: line - 1, threshold: line, wasBelow: false))
        // Still below the next day: already said.
        #expect(!LowSpaceAlert.shouldPost(freeBytes: line - 1, threshold: line, wasBelow: true))
        // Back above: nothing to say.
        #expect(!LowSpaceAlert.shouldPost(freeBytes: line + 1, threshold: line, wasBelow: true))
        #expect(!LowSpaceAlert.shouldPost(freeBytes: line + 1, threshold: line, wasBelow: false))
        // Exactly on the line is not below it.
        #expect(!LowSpaceAlert.shouldPost(freeBytes: line, threshold: line, wasBelow: false))
    }

    @Test func spaceFreedAndLostAgainWarnsAgain() {
        let line = 20 * LowSpaceAlert.gigabyte
        #expect(LowSpaceAlert.shouldPost(freeBytes: line - 1, threshold: line, wasBelow: false))
        // ... the person cleans up, the recorded state goes back to false ...
        #expect(LowSpaceAlert.shouldPost(freeBytes: line - 1, threshold: line, wasBelow: false),
                "a second slide down deserves a second warning")
    }

    @Test func theOfferedThresholdsAreWholeGigabytes() {
        #expect(LowSpaceAlert.choices == [10, 20, 50, 100].map { $0 * LowSpaceAlert.gigabyte })
        #expect(LowSpaceAlert.choices.allSatisfy { $0 % LowSpaceAlert.gigabyte == 0 })
    }

    @Test func theThresholdRoundTripsThroughDefaults() {
        let original = LowSpaceAlert.threshold
        defer { LowSpaceAlert.threshold = original }

        LowSpaceAlert.threshold = 50 * LowSpaceAlert.gigabyte
        #expect(LowSpaceAlert.threshold == 50 * LowSpaceAlert.gigabyte)
    }

    @Test func theDefaultIsOff() {
        let original = LowSpaceAlert.isEnabled
        defer { LowSpaceAlert.isEnabled = original }
        UserDefaults.standard.removeObject(forKey: "warnsAboutLowSpace")
        #expect(!LowSpaceAlert.isEnabled,
                "asking for notification permission is the person's choice, not the app's")
    }
}
