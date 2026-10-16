import Foundation
import Testing
@testable import MacExplorer

@Suite("Browser location addresses")
struct BrowserLocationTests {
    @Test("Virtual locations expose addresses accepted by the address bar")
    func virtualAddresses() {
        #expect(BrowserLocation.home.addressDescription == "home://")
        #expect(BrowserLocation.recents.addressDescription == "recent://")
        #expect(BrowserLocation.network.addressDescription == "network://")
        #expect(
            BrowserLocation.tag(FinderTag(name: "Work / Urgent", colorIndex: 1)).addressDescription
                == "tag://Work%20%2F%20Urgent"
        )
    }

    @Test("Folder locations expose a standardized full path")
    func folderAddress() {
        let location = BrowserLocation.folder(URL(fileURLWithPath: "/tmp/one/../two"))
        #expect(location.addressDescription == "/tmp/two")
    }
}
