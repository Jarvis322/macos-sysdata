import Foundation
import Testing

@testable import SysDataMenu

/// Deleting a file does not always free its space: a local snapshot that still
/// refers to it keeps it, and macOS books it as purgeable. Someone deleted
/// 1.4 GB and watched free space fall by 4 GB; the app said nothing.
struct ShortfallNoticeTests {
    private let gigabyte = Int64(1_073_741_824)

    @Test func nothingIsSaidWhenTheDiskGivesBackWhatWasDeleted() {
        #expect(ScanModel.shortfallNotice(
            askedToFree: 4 * gigabyte, gained: 4 * gigabyte, hasLocalSnapshots: true
        ) == nil)
    }

    @Test func aLittleBackgroundWritingIsNotWorthANotice() {
        #expect(ScanModel.shortfallNotice(
            askedToFree: 4 * gigabyte, gained: 3 * gigabyte, hasLocalSnapshots: false
        ) == nil)
        #expect(ScanModel.shortfallNotice(
            askedToFree: 600 * 1_048_576, gained: 200 * 1_048_576, hasLocalSnapshots: false
        ) == nil, "half a gigabyte short is within the noise")
    }

    @Test func aDiskThatGivesBackNothingIsReported() {
        let notice = ScanModel.shortfallNotice(
            askedToFree: 4 * gigabyte, gained: 0, hasLocalSnapshots: false
        )
        #expect(notice?.contains("purgeable") == true)
    }

    /// Free space going down during a delete reads as a negative gain, and the
    /// notice must not offer "−4 GB more free".
    @Test func aDiskThatShrankIsReportedAsNoSpaceGained() {
        let notice = ScanModel.shortfallNotice(
            askedToFree: Int64(1.4 * 1_073_741_824), gained: -4 * gigabyte, hasLocalSnapshots: true
        )
        #expect(notice?.contains("-") == false && notice?.contains("−") == false)
        #expect(notice?.contains("snapshots") == true)
    }
}
