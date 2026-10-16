import AppKit
import Testing
@testable import MacExplorer

@Suite("Storage map memory lifecycle")
struct DiskUsageTests {
    @Test("Compact scan paths preserve nested Unicode names and sorted totals")
    func compactPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("한글 # 폴더")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = folder.appendingPathComponent("file 10.txt")
        try Data(repeating: 1, count: 8192).write(to: file)
        let result = try DiskUsageScanner.scan(root) { _, _ in }
        let child = try #require(result.children.first)
        let leaf = try #require(child.children.first)
        #expect(child.name == "한글 # 폴더")
        #expect(leaf.url == file)
        #expect(leaf.name == "file 10.txt")
        #expect(result.byteCount >= leaf.byteCount)
        #expect(leaf.byteCount >= 8192)
    }

    @Test("Scanner cancellation stops a running scan")
    func cancelledScan() async {
        let worker = Task.detached {
            try DiskUsageScanner.scan(FileManager.default.temporaryDirectory) { _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do {
            _ = try await worker.value
            Issue.record("Cancelled scanner unexpectedly completed")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test("Large skewed maps can layout, resize, and release repeatedly")
    @MainActor
    func largeMapLayout() {
        let rootURL = URL(fileURLWithPath: "/tmp/map-layout")
        let children = (0..<20_000).map { index in
            DiskUsageNode(url: rootURL.appendingPathComponent("\(index).txt"),
                byteCount: index == 0 ? 1_000_000_000 : 4096, isDirectory: false, children: [])
        }
        let root = DiskUsageNode(url: rootURL, byteCount: children.reduce(0) { $0 + $1.byteCount },
                                 isDirectory: true, children: children)
        let view = DiskTreemapView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        for _ in 0..<3 {
            view.display(rootNode: root, preservingNavigation: false)
            view.frame.size = NSSize(width: 900, height: 600)
            view.layoutSubtreeIfNeeded()
            view.clear()
            #expect(!view.canNavigateBack)
        }
    }

    @Test("Scanning keeps complete results and bounds intermediate snapshots")
    func boundedProgress() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<2_100 {
            try Data([1]).write(to: root.appendingPathComponent("\(index).txt"))
        }
        @Sendable func count(_ node: DiskUsageNode) -> Int { 1 + node.children.reduce(0) { $0 + count($1) } }
        for _ in 0..<2 {
            let result = try DiskUsageScanner.scan(root) { node, _ in
                #expect(count(node) <= DiskUsageScanner.maximumProgressNodes)
            }
            #expect(result.children.count == 2_100)
            #expect(result.byteCount > 0)
        }
    }

    @Test("Closing a storage map releases its controller during scanning")
    @MainActor
    func closedControllerIsReleased() async {
        weak var released: DiskUsageViewController?
        autoreleasepool {
            let controller = DiskUsageViewController(rootURL: FileManager.default.temporaryDirectory)
            released = controller
            _ = controller.view
            controller.stopAndReleaseScan()
        }
        await Task.yield()
        #expect(released == nil)
    }

    @Test("Extension confirmation defaults to Enter and does not warn for ordinary renames")
    @MainActor
    func extensionWarning() throws {
        let url = URL(fileURLWithPath: "/tmp/before.txt")
        #expect(FileRenameWarning.makeAlert(for: url, proposedName: "after.txt", isDirectory: false) == nil)
        #expect(FileRenameWarning.makeAlert(for: url, proposedName: "after.jpg", isDirectory: true) == nil)
        for name in ["after.jpg", "after"] {
            let alert = try #require(FileRenameWarning.makeAlert(for: url, proposedName: name, isDirectory: false))
            #expect(alert.buttons[0].keyEquivalent == "\r")
            #expect(alert.buttons[1].keyEquivalent == "\u{1b}")
        }
    }
}
