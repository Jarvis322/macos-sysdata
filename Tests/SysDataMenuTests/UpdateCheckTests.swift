import Foundation
import Testing
@testable import SysDataMenu

/// Version comparison is the one piece of this that can be quietly wrong: a
/// string comparison puts 0.3.10 before 0.3.9, and the mistake only shows up
/// on the tenth patch release, as an update nobody is offered.
@Suite struct UpdateCheckTests {
    @Test func laterPatchIsNewer() {
        #expect(UpdateCheck.isNewer("0.3.8", than: "0.3.7"))
        #expect(!UpdateCheck.isNewer("0.3.7", than: "0.3.8"))
    }

    @Test func doubleDigitsBeatSingle() {
        #expect(UpdateCheck.isNewer("0.3.10", than: "0.3.9"))
        #expect(!UpdateCheck.isNewer("0.3.9", than: "0.3.10"))
    }

    @Test func theSameVersionIsNotNewer() {
        #expect(!UpdateCheck.isNewer("0.3.7", than: "0.3.7"))
    }

    @Test func minorAndMajorOutrankPatch() {
        #expect(UpdateCheck.isNewer("0.4.0", than: "0.3.99"))
        #expect(UpdateCheck.isNewer("1.0.0", than: "0.99.99"))
    }

    /// A shorter version is padded with zeros rather than treated as smaller.
    @Test func missingComponentsCountAsZero() {
        #expect(UpdateCheck.isNewer("0.4", than: "0.3.9"))
        #expect(!UpdateCheck.isNewer("0.3", than: "0.3.1"))
        #expect(!UpdateCheck.isNewer("0.3.0", than: "0.3"))
    }
}
