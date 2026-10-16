import AppKit
import Testing
@testable import MacExplorer

@Suite("ExplorerTabBarView")
struct ExplorerTabBarViewTests {
    @Test("Loading updates preserve close buttons and their current tab targets")
    @MainActor
    func closeButtonsSurviveLoading() throws {
        let delegate = Delegate()
        let bar = ExplorerTabBarView(frame: NSRect(x: 0, y: 0, width: 900, height: 48))
        bar.delegate = delegate
        let first = ExplorerTabBarItem(id: UUID(), title: "First")
        let second = ExplorerTabBarItem(id: UUID(), title: "Loading")
        bar.update(items: [first, second], activeTabID: second.id, visibleTabIDs: [second.id])
        let close = try #require(allSubviews(of: bar).compactMap { $0 as? NSButton }.first {
            $0.action == NSSelectorFromString("closeTab:") && $0.tag == 1
        })
        let container = close.superview
        for count in 0..<20 {
            let loaded = ExplorerTabBarItem(id: second.id, title: "Loaded \(count)")
            bar.update(items: [first, loaded], activeTabID: second.id, visibleTabIDs: [second.id])
            #expect(close.superview === container)
            #expect(close.isDescendant(of: bar))
        }
        close.sendAction(try #require(close.action), to: close.target)
        #expect(delegate.closedIndices == [1])
        bar.update(items: [second, first], activeTabID: second.id, visibleTabIDs: [second.id])
        close.sendAction(try #require(close.action), to: close.target)
        #expect(delegate.closedIndices == [1, 0])
    }

    @Test("New tab button follows the last tab when the strip has spare room")
    @MainActor
    func newTabButtonFollowsTabs() throws {
        let bar = ExplorerTabBarView(frame: NSRect(x: 0, y: 0, width: 1200, height: 48))
        bar.leadingInset = 20
        for count in [1, 2, 1] {
            let items = (0..<count).map { ExplorerTabBarItem(id: UUID(), title: "Tab \($0)") }
            bar.update(items: items, activeTabID: items[0].id, visibleTabIDs: [items[0].id])
            bar.layoutSubtreeIfNeeded()
            let scroll = try #require(bar.subviews.compactMap { $0 as? NSScrollView }.first)
            let last = try #require((scroll.documentView as? NSStackView)?.arrangedSubviews.last)
            let plus = try #require(bar.subviews.compactMap { $0 as? NSButton }.first)
            let lastFrame = bar.convert(last.bounds, from: last)
            #expect(abs(plus.frame.minX - lastFrame.maxX - 8) < 1)
            #expect(plus.frame.maxX < bar.bounds.maxX - 100)
        }
    }

    @Test("Narrow tab strips scroll instead of creating conflicting minimum widths")
    @MainActor
    func narrowTabsRemainReachable() throws {
        let bar = ExplorerTabBarView(frame: NSRect(x: 0, y: 0, width: 360, height: 48))
        bar.leadingInset = 20
        bar.availableWindowWidth = 360
        let items = (0..<8).map {
            ExplorerTabBarItem(id: UUID(), title: "Folder \($0)")
        }

        bar.update(items: items, activeTabID: items.last?.id, visibleTabIDs: [items.last!.id])
        bar.layoutSubtreeIfNeeded()

        let scrollView = try #require(allSubviews(of: bar).compactMap { $0 as? NSScrollView }.first)
        let documentView = try #require(scrollView.documentView)
        let tabViews = documentView.subviews
        let lastTab = try #require(tabViews.last)

        #expect(scrollView.hasHorizontalScroller)
        #expect(documentView.frame.width > scrollView.contentView.bounds.width)
        #expect(tabViews.count == items.count)
        #expect(tabViews.allSatisfy { tab in
            !tab.constraints.contains {
                $0.firstAttribute == .width
                    && $0.relation == .greaterThanOrEqual
                    && $0.priority == .required
            }
        })
        #expect(scrollView.documentVisibleRect.intersects(lastTab.frame))
    }

    @Test("Focused tabs activate with Return and Space")
    @MainActor
    func keyboardActivation() throws {
        let delegate = Delegate()
        let bar = ExplorerTabBarView(frame: NSRect(x: 0, y: 0, width: 700, height: 48))
        bar.delegate = delegate
        let items = (0..<3).map { ExplorerTabBarItem(id: UUID(), title: "Tab \($0)") }
        bar.update(items: items, activeTabID: items[0].id, visibleTabIDs: [items[0].id])
        bar.layoutSubtreeIfNeeded()
        let buttons = tabButtons(in: bar)

        #expect(buttons.count == 3)
        #expect(buttons.allSatisfy { $0.acceptsFirstResponder })
        buttons[1].keyDown(with: try keyEvent(character: "\r", keyCode: 36))
        buttons[2].keyDown(with: try keyEvent(character: " ", keyCode: 49))

        #expect(delegate.selectedIndices == [1, 2])
    }

    @Test("Tabs expose selection and location to accessibility and tooltips")
    @MainActor
    func accessibilityAndLocationTooltip() throws {
        let first = ExplorerTabBarItem(
            id: UUID(),
            title: "Photos",
            locationDescription: "/Volumes/Archive/Family/Photos"
        )
        let second = ExplorerTabBarItem(
            id: UUID(),
            title: "Documents",
            locationDescription: "/Users/test/Documents"
        )
        let bar = ExplorerTabBarView(frame: NSRect(x: 0, y: 0, width: 700, height: 48))
        bar.update(items: [first, second], activeTabID: second.id, visibleTabIDs: [second.id])
        bar.layoutSubtreeIfNeeded()
        let buttons = tabButtons(in: bar)

        #expect(buttons.count == 2)
        #expect(buttons[0].accessibilityRole() == .radioButton)
        #expect(!buttons[0].isAccessibilitySelected())
        #expect(buttons[1].isAccessibilitySelected())
        #expect(buttons[0].accessibilityHelp() == first.locationDescription)
        #expect(buttons[0].toolTip?.contains(first.locationDescription) == true)
        #expect(buttons[0].toolTip?.contains(L10n.text("Drag outside the window to open in a new window")) == true)
    }

    @MainActor
    private func tabButtons(in view: NSView) -> [NSButton] {
        allSubviews(of: view)
            .compactMap { $0 as? NSButton }
            .filter { !$0.title.isEmpty }
    }

    @MainActor
    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(allSubviews(of:))
    }

    @MainActor
    private func keyEvent(character: String, keyCode: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 1,
            windowNumber: 0,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: keyCode
        ))
    }
}

private final class Delegate: ExplorerTabBarViewDelegate {
    var selectedIndices: [Int] = []
    var closedIndices: [Int] = []

    func tabBar(_ tabBar: ExplorerTabBarView, didSelect index: Int) {
        selectedIndices.append(index)
    }

    func tabBar(_ tabBar: ExplorerTabBarView, didRequestClose index: Int) {
        closedIndices.append(index)
    }
    func tabBar(_ tabBar: ExplorerTabBarView, didRequestMove tabID: UUID, to insertionIndex: Int) {}
    func tabBar(
        _ tabBar: ExplorerTabBarView,
        didFinishDragging tabID: UUID,
        at screenPoint: NSPoint,
        operation: NSDragOperation
    ) {}
    func tabBarDidRequestNewTab(_ tabBar: ExplorerTabBarView) {}
}
