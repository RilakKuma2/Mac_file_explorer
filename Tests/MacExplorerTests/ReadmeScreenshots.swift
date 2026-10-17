import AppKit
import Testing
@testable import MacExplorer

/// Opt-in rendering of real AppKit views with disposable example data.
/// No desktop/window capture or user files are used.
@Suite("README screenshots")
struct ReadmeScreenshots {
    @Test("Render privacy-safe examples", .enabled(if: ProcessInfo.processInfo.environment["MAC_EXPLORER_SCREENSHOTS"] != nil))
    @MainActor
    func renderExamples() async throws {
        let previousSidebarWidth = UserDefaults.standard.object(forKey: "ExplorerSidebarWidth")
        defer {
            if let previousSidebarWidth { UserDefaults.standard.set(previousSidebarWidth, forKey: "ExplorerSidebarWidth") }
            else { UserDefaults.standard.removeObject(forKey: "ExplorerSidebarWidth") }
        }
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MAC_EXPLORER_SCREENSHOTS"]!)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("Creative Studio")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Brand Assets", "Documents", "Photography", "Presentations", "Website"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: false)
        }
        for (index, name) in ["Project brief.txt", "Release notes.md", "Color palette.json", "Design checklist.txt", "Meeting notes.md", "Content plan.csv"].enumerated() {
            let url = folder.appendingPathComponent(name)
            try Data("Example content for the Mac Explorer demo.\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-Double(index / 2) * 86400 * 4)], ofItemAtPath: url.path)
        }
        let controller = ExplorerWindowViewController(initialURL: folder)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 680),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentViewController = controller
        controller.toggleSidebarVisibility()
        window.setContentSize(NSSize(width: 1120, height: 680))
        controller.view.frame = NSRect(x: 0, y: 0, width: 1120, height: 680)
        controller.view.layoutSubtreeIfNeeded()
        let browser = try #require(controller.currentBrowser)
        let list = try #require(browser.children.compactMap { $0 as? FileListViewController }.first)
        for _ in 0..<300 {
            if list.allItems.count == 11 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(list.allItems.count == 11)
        // Replace only the rendered breadcrumb: never expose the temp/user path.
        let breadcrumb = try #require(descendants(controller.view).compactMap { $0 as? BreadcrumbBarView }.first)
        breadcrumb.show(url: URL(fileURLWithPath: "/Demo/Creative Studio"))
        list.setDateGroupingMode(.enabled)
        list.setViewMode(.details)
        try capture(controller.view, to: output.appendingPathComponent("list.png"))
        list.setDateGroupingMode(.disabled)
        list.setViewMode(.icons)
        try capture(controller.view, to: output.appendingPathComponent("icons.png"))

        // Render the real split layout, with an entirely synthetic sidebar.
        // Never publish Finder favorites, mounted disks, or the user's home path.
        window.setContentSize(NSSize(width: 1440, height: 780))
        controller.view.frame.size = NSSize(width: 1440, height: 780)
        controller.toggleSidebarVisibility()
        controller.toggleSplitView()
        controller.view.layoutSubtreeIfNeeded()
        let right = try #require(controller.currentBrowser)
        let rightList = try #require(right.children.compactMap { $0 as? FileListViewController }.first)
        for name in ["Brand guidelines", "Drafts", "Exports", "Reference", "Reports", "Templates"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("Documents").appendingPathComponent(name), withIntermediateDirectories: false)
        }
        right.navigate(to: folder.appendingPathComponent("Documents"))
        for _ in 0..<300 {
            if rightList.allItems.count == 6 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(rightList.allItems.count == 6)
        list.setDateGroupingMode(.enabled)
        list.setViewMode(.details)
        rightList.setDateGroupingMode(.disabled)
        rightList.setViewMode(.icons)
        for pane in controller.children.compactMap({ $0 as? MainViewController }) {
            pane.viewDidAppear()
            pane.viewDidLayout()
            for files in pane.children.compactMap({ $0 as? FileListViewController }) { files.viewDidLayout() }
            for path in descendants(pane.view).compactMap({ $0 as? BreadcrumbBarView }) {
                path.show(url: URL(fileURLWithPath: pane === right ? "/Demo/Creative Studio/Documents" : "/Demo/Creative Studio"))
            }
        }
        let split = try #require(descendants(controller.view).compactMap { $0 as? NSSplitView }
            .first { $0.identifier?.rawValue == "browserPaneSplit" })
        split.setPosition(810, ofDividerAt: 0)
        controller.view.layoutSubtreeIfNeeded()
        let sidebarSplit = try #require(descendants(split.arrangedSubviews[0]).compactMap { $0 as? NSSplitView }
            .first { $0.identifier?.rawValue == "browserSidebarSplit" })
        sidebarSplit.setPosition(200, ofDividerAt: 0)
        for table in descendants(list.view).compactMap({ $0 as? NSTableView }) where !(table is NSOutlineView) {
            for (column, width) in zip(table.tableColumns, [230.0, 155.0, 130.0, 70.0]) {
                column.width = width
            }
        }
        controller.view.layoutSubtreeIfNeeded()
        list.viewDidLayout()
        try await Task.sleep(nanoseconds: 400_000_000)
        let sidebar = try #require(descendants(split.arrangedSubviews[0]).first { $0.identifier?.rawValue == "browserSidebar" })
        let outline = try #require(descendants(sidebar).compactMap { $0 as? NSOutlineView }.first)
        let examples = ExampleSidebarDataSource()
        outline.dataSource = examples
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
        outline.deselectAll(nil)
        #expect(descendants(split.arrangedSubviews[1]).allSatisfy { $0.identifier?.rawValue != "browserSidebar" })
        // Keep capture synchronous so no live sidebar refresh can intervene.
        try withExtendedLifetime(examples) {
            try capture(controller.view, to: output.appendingPathComponent("split-view.png"))
        }

        let map = DiskTreemapView(frame: NSRect(x: 0, y: 0, width: 1120, height: 680))
        map.appearance = NSAppearance(named: .aqua)
        let groups: [(String, [(String, Int64)])] = [
            ("Photography", [("Mountain.jpg", 180), ("Coast.jpg", 140), ("Forest.jpg", 100)]),
            ("Video", [("Studio tour.mov", 320), ("Product demo.mp4", 220)]),
            ("Design", [("Brand assets.zip", 150), ("Presentation.pdf", 70), ("Website.zip", 90)]),
            ("Documents", [("Research.pdf", 45), ("Archive.zip", 65)])
        ]
        let demoURL = URL(fileURLWithPath: "/Demo/Creative Studio")
        let nodes = groups.map { name, files in
            let url = demoURL.appendingPathComponent(name)
            let children = files.map { DiskUsageNode(url: url.appendingPathComponent($0.0), byteCount: $0.1 * 1_048_576, isDirectory: false, children: []) }
            return DiskUsageNode(url: url, byteCount: children.reduce(0) { $0 + $1.byteCount }, isDirectory: true, children: children)
        }
        map.display(rootNode: DiskUsageNode(url: demoURL, byteCount: nodes.reduce(0) { $0 + $1.byteCount }, isDirectory: true, children: nodes), preservingNavigation: false)
        try capture(map, to: output.appendingPathComponent("storage-map.png"))
        window.contentViewController = nil
    }

    @MainActor
    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    @MainActor
    private func capture(_ view: NSView, to url: URL) throws {
        // Capacity is host-specific too; keep the demo independent of the disk.
        for label in descendants(view).compactMap({ $0 as? NSTextField })
            where label.stringValue.contains("available") || label.stringValue.contains("사용 가능") {
            let count = label.stringValue.components(separatedBy: "·").first?.trimmingCharacters(in: .whitespaces) ?? "Demo"
            label.stringValue = "\(count) · Demo data"
        }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}

@MainActor
private final class ExampleSidebarDataSource: NSObject, NSOutlineViewDataSource {
    private let roots: [SidebarNode] = [
        SidebarNode(title: "Home", symbolName: "house"),
        SidebarNode(title: "Recents", symbolName: "clock"),
        SidebarNode(title: "Gallery", symbolName: "photo.on.rectangle"),
        SidebarNode(title: "Favorites", children: [
            SidebarNode(title: "Creative Studio", symbolName: "folder", isPinned: true),
            SidebarNode(title: "Documents", symbolName: "doc.text"),
            SidebarNode(title: "Photography", symbolName: "photo"),
            SidebarNode(title: "Downloads", symbolName: "arrow.down.circle"),
        ], isGroup: true),
        SidebarNode(title: "Locations", children: [
            SidebarNode(title: "Demo Disk", symbolName: "internaldrive"),
            SidebarNode(title: "Archive", symbolName: "externaldrive"),
        ], isGroup: true),
    ]

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SidebarNode)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? SidebarNode)?.children ?? roots)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? SidebarNode)?.children.isEmpty ?? true)
    }
}
