import AppKit
import Testing
@testable import MacExplorer

@Suite("Sidebar refresh")
struct SidebarViewControllerTests {
    @Test("Programmatic sidebar selection does not start another navigation")
    @MainActor
    func programmaticSelectionIsSilent() throws {
        let sidebar = SidebarViewController()
        let delegate = SidebarSelectionRecorder()
        sidebar.delegate = delegate
        let outline = try #require((sidebar.view as? NSScrollView)?.documentView as? NSOutlineView)
        sidebar.select(location: .home)
        sidebar.select(location: .network)
        #expect(delegate.locations.isEmpty)
        let homeRow = try #require((0..<outline.numberOfRows).first {
            (outline.item(atRow: $0) as? SidebarNode)?.location == .home
        })
        outline.selectRowIndexes(IndexSet(integer: homeRow), byExtendingSelection: false)
        #expect(delegate.locations == [.home])
    }

    @Test("Unchanged snapshots do not publish a redundant outline reload")
    func unchangedSnapshotIsSuppressed() {
        var gate = SidebarRefreshGate<[String]>()
        gate.installInitial(["Home", "Downloads"])

        let request = gate.beginRequest()
        let didPublish = gate.accept(["Home", "Downloads"], for: request)

        #expect(!didPublish)
        #expect(gate.snapshot == ["Home", "Downloads"])
    }

    @Test("Only the newest coalesced discovery can update the sidebar")
    func staleSnapshotIsSuppressed() {
        var gate = SidebarRefreshGate<[String]>()
        gate.installInitial(["Home"])
        let activationRequest = gate.beginRequest()
        let volumeRequest = gate.beginRequest()
        let staleDidPublish = gate.accept(["Home", "Old volume"], for: activationRequest)
        let newestDidPublish = gate.accept(["Home", "New volume"], for: volumeRequest)

        #expect(!staleDidPublish)
        #expect(newestDidPublish)
        #expect(gate.snapshot == ["Home", "New volume"])
    }

    @Test("A real content change publishes exactly once")
    func changedSnapshotPublishesOnce() {
        var gate = SidebarRefreshGate<[String]>()
        gate.installInitial(["Home"])
        let firstRequest = gate.beginRequest()
        let firstDidPublish = gate.accept(["Home", "USB"], for: firstRequest)

        #expect(firstDidPublish)

        let confirmationRequest = gate.beginRequest()
        let confirmationDidPublish = gate.accept(["Home", "USB"], for: confirmationRequest)
        #expect(!confirmationDidPublish)
        #expect(gate.snapshot == ["Home", "USB"])
    }
}

private final class SidebarSelectionRecorder: SidebarViewControllerDelegate {
    var locations: [BrowserLocation] = []
    func sidebar(_ sidebar: SidebarViewController, didSelect location: BrowserLocation) {
        locations.append(location)
    }
}
