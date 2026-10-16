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
            label.stringValue = "11 items · Demo data"
        }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
