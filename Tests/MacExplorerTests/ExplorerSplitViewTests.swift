import AppKit
import Testing
@testable import MacExplorer

@Suite("Independent split panes", .serialized)
@MainActor
struct ExplorerSplitViewTests {
    @Test("Render split layout for visual QA", .enabled(if: ProcessInfo.processInfo.environment["MAC_EXPLORER_SPLIT_SCREENSHOTS"] != nil))
    func renderSplitLayout() async throws {
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MAC_EXPLORER_SPLIT_SCREENSHOTS"]!)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SplitPreview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Notes.txt", "Photo list.csv", "Readme.md"] { try Data("Demo".utf8).write(to: root.appendingPathComponent(name)) }
        let (window, controller) = fixture()
        defer { window.contentViewController = nil }
        window.appearance = NSAppearance(named: .aqua)
        for browser in controller.children.compactMap({ $0 as? MainViewController }) { browser.navigate(to: root) }
        try await Task.sleep(nanoseconds: 300_000_000)
        for browser in controller.children.compactMap({ $0 as? MainViewController }) {
            browser.viewDidAppear()
            for list in browser.children.compactMap({ $0 as? FileListViewController }) { list.viewDidLayout() }
        }
        let split = try paneSplit(in: controller)
        for position: CGFloat in [600, 240, 960] {
            split.setPosition(position, ofDividerAt: 0)
            controller.view.layoutSubtreeIfNeeded()
            // Responsive controls update after receiving their new frame.
            for browser in controller.children.compactMap({ $0 as? MainViewController }) { browser.viewDidLayout() }
            controller.view.layoutSubtreeIfNeeded()
            controller.view.displayIfNeeded()
            for table in descendants(controller.view).compactMap({ $0 as? NSTableView }) {
                #expect(table.visibleRect.width > 0)
                #expect(table.visibleRect.height > 0)
            }
            let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
            controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("split-\(Int(position)).png"))
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    private func fixture() -> (NSWindow, ExplorerWindowViewController) {
        let controller = ExplorerWindowViewController(initialURL: FileManager.default.temporaryDirectory)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 720),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1200, height: 720))
        controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 720)
        controller.view.layoutSubtreeIfNeeded()
        controller.toggleSplitView()
        controller.view.layoutSubtreeIfNeeded()
        return (window, controller)
    }

    private func bar(_ side: String, in controller: ExplorerWindowViewController) throws -> ExplorerTabBarView {
        try #require(descendants(controller.view).compactMap { $0 as? ExplorerTabBarView }
            .first { $0.identifier?.rawValue == side + "PaneTabs" })
    }

    private func tabButtons(_ bar: ExplorerTabBarView) -> [NSButton] {
        let stack = bar.subviews.compactMap { $0 as? NSScrollView }.first?.documentView as? NSStackView
        return (stack?.arrangedSubviews.flatMap(descendants) ?? []).compactMap { $0 as? NSButton }.filter {
            $0.identifier.flatMap { UUID(uuidString: $0.rawValue) } != nil
        }
    }

    private func paneSplit(in controller: ExplorerWindowViewController) throws -> NSSplitView {
        try #require(descendants(controller.view).compactMap { $0 as? NSSplitView }
            .first { $0.identifier?.rawValue == "browserPaneSplit" })
    }

    @Test("Each pane owns its tabs and plus button; closing replaces only that pane")
    func independentTabs() throws {
        let (window, controller) = fixture()
        defer { window.contentViewController = nil }
        let left = try bar("left", in: controller)
        let right = try bar("right", in: controller)
        let originalLeft = try #require(tabButtons(left).first?.identifier)
        let originalRight = try #require(tabButtons(right).first?.identifier)
        #expect(tabButtons(left).count == 1)
        #expect(tabButtons(right).count == 1)
        // Operate the actual plus controls, including the inactive pane's plus.
        for (strip, expectedLeft, expectedRight) in [(right, 1, 2), (left, 2, 2)] {
            let plus = try #require(strip.subviews.compactMap { $0 as? NSButton }.first)
            plus.sendAction(plus.action, to: plus.target)
            controller.view.layoutSubtreeIfNeeded()
            #expect(tabButtons(left).count == expectedLeft)
            #expect(tabButtons(right).count == expectedRight)
        }
        controller.tabBar(right, didSelect: 0)
        #expect(tabButtons(right).first?.identifier == originalRight)
        controller.tabBar(left, didRequestClose: 1)
        #expect(controller.isCurrentTabSplit)
        #expect(tabButtons(left).map(\.identifier) == [originalLeft])
        #expect(tabButtons(right).count == 2)
        controller.tabBar(right, didRequestClose: 0)
        #expect(controller.isCurrentTabSplit)
        #expect(tabButtons(right).count == 1)
        // Closing the final right tab merges back to a normal single pane.
        controller.tabBar(right, didRequestClose: 0)
        #expect(!controller.isCurrentTabSplit)
        #expect(right.isHidden)
        #expect(tabButtons(left).count == 1)
        #expect(controller.reopenClosedTab())
        #expect(controller.isCurrentTabSplit)
        #expect(tabButtons(left).count == 1)
        #expect(tabButtons(right).count == 1)
    }

    @Test("Only the left sidebar is mounted, including after toggles and changing tabs")
    func singleSidebar() throws {
        let (window, controller) = fixture()
        defer { window.contentViewController = nil }
        let split = try paneSplit(in: controller)
        func sidebars(_ pane: NSView) -> [NSView] {
            descendants(pane).filter { $0.identifier?.rawValue == "browserSidebar" }
        }
        #expect(sidebars(split.arrangedSubviews[0]).count == 1)
        #expect(sidebars(split.arrangedSubviews[1]).isEmpty)
        controller.toggleSidebarVisibility()
        #expect(sidebars(split).isEmpty)
        controller.toggleSidebarVisibility()
        #expect(sidebars(split.arrangedSubviews[0]).count == 1)
        #expect(sidebars(split.arrangedSubviews[1]).isEmpty)
        let right = try bar("right", in: controller)
        controller.tabBarDidRequestNewTab(right)
        #expect(sidebars(split).count == 1)
        controller.toggleSplitView()
        #expect(sidebars(split).count == 1)
    }

    @Test("Divider can reach narrow panes and both tab bars follow the actual divider")
    func flexibleSizing() throws {
        let (window, controller) = fixture()
        defer { window.contentViewController = nil }
        let split = try paneSplit(in: controller)
        let left = try bar("left", in: controller)
        let right = try bar("right", in: controller)
        for position: CGFloat in [240, 960, 180, 600] {
            split.setPosition(position, ofDividerAt: 0)
            controller.view.layoutSubtreeIfNeeded()
            controller.viewDidLayout()
            #expect(abs(split.arrangedSubviews[0].frame.width - position) < 2)
            let rightFrame = controller.view.convert(split.arrangedSubviews[1].bounds, from: split.arrangedSubviews[1])
            let rightBarFrame = controller.view.convert(right.bounds, from: right)
            #expect(abs(rightFrame.minX - rightBarFrame.minX) < 2)
            #expect(abs(left.bounds.width - position) < 2)
        }
        // Switching a pane's tab must not reset a user-chosen divider ratio.
        split.setPosition(350, ofDividerAt: 0)
        controller.tabBarDidRequestNewTab(right)
        controller.view.layoutSubtreeIfNeeded()
        #expect(abs(split.arrangedSubviews[0].frame.width - 350) < 2)
    }

    @Test("Tabs can move between pane strips without losing either browser")
    func moveTabsBetweenPanes() throws {
        let (window, controller) = fixture()
        defer { window.contentViewController = nil }
        let left = try bar("left", in: controller)
        let right = try bar("right", in: controller)
        let leftID = try #require(tabButtons(left).first?.identifier.flatMap { UUID(uuidString: $0.rawValue) })
        let rightID = try #require(tabButtons(right).first?.identifier.flatMap { UUID(uuidString: $0.rawValue) })
        controller.tabBar(right, didRequestMove: leftID, to: 1)
        #expect(controller.isCurrentTabSplit)
        #expect(tabButtons(right).first?.identifier?.rawValue == leftID.uuidString)
        #expect(tabButtons(left).first?.identifier?.rawValue == rightID.uuidString)
        controller.tabBarDidRequestNewTab(left)
        let addedID = try #require(tabButtons(left).last?.identifier.flatMap { UUID(uuidString: $0.rawValue) })
        controller.tabBar(right, didRequestMove: addedID, to: 0)
        #expect(tabButtons(left).count == 1)
        #expect(tabButtons(right).count == 2)
        #expect(tabButtons(right).first?.identifier?.rawValue == addedID.uuidString)
    }

    @Test("Sidebar resizing is not capped at 360 points")
    func wideSidebar() throws {
        let previous = UserDefaults.standard.object(forKey: "ExplorerSidebarWidth")
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: "ExplorerSidebarWidth") }
            else { UserDefaults.standard.removeObject(forKey: "ExplorerSidebarWidth") }
        }
        let (window, controller) = fixture()
        defer { window.contentViewController = nil }
        let split = try paneSplit(in: controller)
        split.setPosition(800, ofDividerAt: 0)
        controller.view.layoutSubtreeIfNeeded()
        let sidebarSplit = try #require(descendants(split.arrangedSubviews[0]).compactMap { $0 as? NSSplitView }
            .first { $0.identifier?.rawValue == "browserSidebarSplit" })
        sidebarSplit.setPosition(450, ofDividerAt: 0)
        controller.view.layoutSubtreeIfNeeded()
        #expect(abs(sidebarSplit.arrangedSubviews[0].frame.width - 450) < 2)
    }
}
