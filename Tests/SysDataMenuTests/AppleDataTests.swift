import Testing
@testable import SysDataMenu

/// Apple's containers hold the local copy of data that syncs with iCloud —
/// Notes, Reminders, Messages — and were offered for deletion with a Review
/// badge until a user noticed their iCloud data in the list. These pin which
/// names the app refuses to delete.
@Suite struct AppleDataTests {
    @Test func appleContainersAreProtected() {
        for name in [
            "com.apple.Notes", "com.apple.mediaanalysisd", "com.apple.CoreDevice.CoreDeviceService",
            "group.com.apple.notes", "group.com.apple.reminders", "group.com.apple.replicatord",
        ] {
            #expect(AppDataProbe.isAppleOwned(name), "\(name) must not be deletable")
        }
    }

    @Test func thirdPartyContainersStayDeletable() {
        for name in [
            "group.net.whatsapp.WhatsApp.shared", "com.microsoft.teams2", "com.tinyspeck.slackmacgap",
            "UBF8T346G9.Office", "com.applesauce.example",
        ] {
            #expect(!AppDataProbe.isAppleOwned(name), "\(name) is not Apple's")
        }
    }
}
