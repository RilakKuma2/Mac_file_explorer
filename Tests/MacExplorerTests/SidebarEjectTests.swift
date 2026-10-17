import AppKit
import Testing
@testable import MacExplorer

struct SidebarEjectTests {
    @Test func volumeEligibility() {
        let disk = URL(fileURLWithPath: "/Volumes/Demo")
        #expect(FinderSidebarEntry.canEjectVolume(at: disk, removable: true, ejectable: false, local: true))
        #expect(FinderSidebarEntry.canEjectVolume(at: disk, removable: false, ejectable: true, local: true))
        #expect(FinderSidebarEntry.canEjectVolume(at: disk, removable: false, ejectable: false, local: false))
        #expect(!FinderSidebarEntry.canEjectVolume(at: disk, removable: false, ejectable: false, local: true))
        #expect(!FinderSidebarEntry.canEjectVolume(at: disk, removable: false, ejectable: false, local: nil))
        #expect(!FinderSidebarEntry.canEjectVolume(at: URL(fileURLWithPath: "/"), removable: true, ejectable: true, local: false))
        #expect(!FinderSidebarEntry(title: "Cloud", url: disk, symbolName: "folder").canEject)
    }

    @Test @MainActor func ejectButtonOnlyOnVolumes() throws {
        let sidebar = SidebarViewController()
        _ = sidebar.view
        let outline = NSOutlineView()
        let volume = SidebarNode(title: "Demo Disk", location: .folder(URL(fileURLWithPath: "/Volumes/Demo")), canEject: true)
        let folder = SidebarNode(title: "Documents", location: .folder(URL(fileURLWithPath: "/Demo/Documents")))
        for (node, expected) in [(volume, true), (folder, false)] {
            let cell = try #require(sidebar.outlineView(outline, viewFor: nil, item: node))
            let button = try #require(cell.subviews.compactMap { $0 as? NSButton }.first)
            #expect(button.isHidden == !expected)
            #expect(button.isEnabled == expected)
            #expect(button.target === sidebar)
        }
    }
}
