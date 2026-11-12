import AppKit
import Testing
@testable import MacExplorer

@Suite("Refresh stability")
struct RefreshStabilityTests {
    @Test("Reporting the same folder again keeps the breadcrumb buttons in place")
    @MainActor
    func breadcrumbIsNotRebuiltForTheSameLocation() throws {
        let bar = BreadcrumbBarView(frame: NSRect(x: 0, y: 0, width: 700, height: 32))
        let url = URL(fileURLWithPath: "/Volumes/Test/Parent/Current")
        bar.show(url: url)
        let before = crumbs(in: bar)
        #expect(before.map(\.title).suffix(2) == ["Parent", "Current"])

        // A watcher refresh reports the unchanged location.
        bar.show(url: url)
        let afterRefresh = crumbs(in: bar)
        #expect(afterRefresh.count == before.count)
        #expect(zip(before, afterRefresh).allSatisfy { $0 === $1 })

        bar.show(url: url.deletingLastPathComponent())
        #expect(crumbs(in: bar).map(\.title).last == "Parent")
        bar.showHome()
        bar.show(url: url)
        #expect(crumbs(in: bar).map(\.title).last == "Current")
    }

    @Test("An unchanged refresh is recognised and loaded tags survive a re-enumeration")
    @MainActor
    func unchangedRefreshKeepsRowsAndTags() throws {
        let fixture = try makeFileFixture(names: ["a.txt", "b.txt", "c.txt"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let controller = FileListViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        controller.display(items: fixture.items, in: fixture.directory)
        #expect(controller.isDisplaying(fixture.items, in: fixture.directory))
        #expect(!controller.isDisplaying(Array(fixture.items.dropLast()), in: fixture.directory))
        #expect(!controller.isDisplaying(fixture.items, in: fixture.directory.appendingPathComponent("other")))

        // Tags are hydrated after the listing; the next plain enumeration has none.
        let tagged = fixture.items[1].replacingTagMetadata(tagNames: ["Red"], labelNumber: 6)
        controller.updateTagMetadata(items: [tagged], in: fixture.directory)
        #expect(!controller.isDisplaying(fixture.items, in: fixture.directory))
        let merged = controller.carryingOverTagMetadata(fixture.items, in: fixture.directory)
        #expect(merged[1].tagNames == ["Red"])
        #expect(merged[1].labelNumber == 6)
        #expect(controller.isDisplaying(merged, in: fixture.directory))
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(allSubviews(of:))
    }

    private func makeFileFixture(names: [String]) throws -> (directory: URL, items: [FileItem]) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacExplorerRefreshTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey,
            .contentModificationDateKey, .fileSizeKey, .localizedTypeDescriptionKey, .contentTypeKey
        ]
        let items = try names.map { name -> FileItem in
            let url = directory.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: Data())
            return FileItem(url: url, resourceValues: try url.resourceValues(forKeys: keys))
        }
        return (directory, FileSortDescriptor().sort(items))
    }

    @MainActor
    private func crumbs(in bar: BreadcrumbBarView) -> [NSButton] {
        allSubviews(of: bar).compactMap { $0 as? NSButton }.filter {
            $0.identifier?.rawValue == "breadcrumbCrumb" && $0.tag >= 0
        }
    }
}
