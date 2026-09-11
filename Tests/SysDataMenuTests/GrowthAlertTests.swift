import Testing
@testable import SysDataMenu

@Suite struct GrowthAlertTests {
    @Test func postsOnceThenWaitsForAnotherMeaningfulIncrease() {
        let gigabyte: Int64 = 1_073_741_824

        #expect(GrowthAlert.shouldPost(currentBytes: 8 * gigabyte, lastNotifiedBytes: nil))
        #expect(!GrowthAlert.shouldPost(currentBytes: 9 * gigabyte, lastNotifiedBytes: 8 * gigabyte))
        #expect(GrowthAlert.shouldPost(currentBytes: 10 * gigabyte, lastNotifiedBytes: 8 * gigabyte))
        #expect(!GrowthAlert.shouldPost(currentBytes: 7 * gigabyte, lastNotifiedBytes: 8 * gigabyte))
    }
}
