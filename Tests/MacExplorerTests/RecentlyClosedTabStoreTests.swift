import Foundation
import Testing
@testable import MacExplorer

@Suite("Recently closed tabs")
struct RecentlyClosedTabStoreTests {
    @Test("History is bounded and reopens newest tabs first")
    func boundedLIFOHistory() throws {
        let store = RecentlyClosedTabStore(capacity: 3)
        let locations: [BrowserLocation] = [
            .home,
            .folder(URL(fileURLWithPath: "/tmp/one")),
            .recents,
            .network
        ]
        locations.forEach {
            store.record(ClosedExplorerTab(location: $0, splitContext: nil))
        }

        #expect(store.count == 3)
        #expect(store.popLast()?.location == .network)
        #expect(store.popLast()?.location == .recents)
        #expect(store.popLast()?.location == .folder(URL(fileURLWithPath: "/tmp/one")))
        #expect(store.popLast() == nil)
        #expect(store.canReopen == false)
    }

    @Test("Split-side context survives closing and reopening history")
    func preservesSplitContext() throws {
        let store = RecentlyClosedTabStore(capacity: 6)
        let closed = ClosedExplorerTab(
            location: .folder(URL(fileURLWithPath: "/tmp/right")),
            splitContext: ClosedExplorerSplitContext(
                closedSide: .right,
                companionLocation: .folder(URL(fileURLWithPath: "/tmp/left"))
            )
        )

        store.record(closed)

        #expect(store.canReopen)
        #expect(store.popLast() == closed)
    }
}
