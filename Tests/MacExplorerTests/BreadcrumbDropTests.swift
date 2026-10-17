import AppKit
import Testing
@testable import MacExplorer

@MainActor
private final class TestFileDrag: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation = [.copy, .move]
    var draggingLocation: NSPoint = .zero
    var draggedImageLocation: NSPoint { draggingLocation }
    nonisolated var draggedImage: NSImage? { nil }
    let draggingPasteboard = NSPasteboard.withUniqueName()
    var draggingSource: Any? = NSObject()
    let draggingSequenceNumber = Int.random(in: 1...Int.max)
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(urls: [URL]) {
        super.init()
        draggingPasteboard.writeObjects(urls as [NSURL])
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

private final class BreadcrumbDropRecorder: BreadcrumbBarViewDelegate, FileListViewControllerDelegate {
    let list = FileListViewController()
    var imports: [(urls: [URL], destination: URL, move: Bool)] = []
    var navigations = 0
    init() { list.delegate = self }
    func breadcrumbBarDidRequestHome(_ breadcrumbBar: BreadcrumbBarView) { navigations += 1 }
    func breadcrumbBar(_ breadcrumbBar: BreadcrumbBarView, didSelect url: URL) { navigations += 1 }
    func breadcrumbBar(_ breadcrumbBar: BreadcrumbBarView, didSubmitPath path: String) { navigations += 1 }
    func breadcrumbBar(_ breadcrumbBar: BreadcrumbBarView, validateDrop info: NSDraggingInfo, into directory: URL) -> NSDragOperation {
        list.fileDropDecision(for: info, target: .folder(directory, isPackage: false))?.decision.operation ?? []
    }
    func breadcrumbBar(_ breadcrumbBar: BreadcrumbBarView, acceptDrop info: NSDraggingInfo, into directory: URL) -> Bool {
        list.acceptFileDrop(info, target: .folder(directory, isPackage: false))
    }
    func fileList(_ fileList: FileListViewController, didRequestImport urls: [URL], destination: URL, move: Bool) {
        imports.append((urls, destination, move))
    }
    func fileList(_ fileList: FileListViewController, didActivate item: FileItem) {}
    func fileListSelectionDidChange(_ fileList: FileListViewController) {}
    func fileListDidRequestRename(_ fileList: FileListViewController) {}
    func fileList(_ fileList: FileListViewController, didRequestRename item: FileItem, to newName: String) {}
    func fileListDidRequestTrash(_ fileList: FileListViewController) {}
    func fileListDidRequestQuickLook(_ fileList: FileListViewController) {}
    func fileListDidRequestBack(_ fileList: FileListViewController) {}
    func fileListDidRequestForward(_ fileList: FileListViewController) {}
    func fileList(_ fileList: FileListViewController, didChangeViewMode mode: FileViewMode) {}
}

@Suite("Breadcrumb file drops")
@MainActor
struct BreadcrumbDropTests {
    private func fixture(path: String = "/Volumes/Test/Parent/Current") -> (NSWindow, BreadcrumbBarView, BreadcrumbDropRecorder) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let bar = BreadcrumbBarView(frame: NSRect(x: 80, y: 190, width: 880, height: 34))
        window.contentView?.addSubview(bar)
        bar.show(url: URL(fileURLWithPath: path, isDirectory: true))
        window.contentView?.layoutSubtreeIfNeeded()
        let recorder = BreadcrumbDropRecorder()
        bar.delegate = recorder
        return (window, bar, recorder)
    }

    private func buttons(_ view: NSView) -> [NSButton] {
        view.subviews.compactMap { $0 as? NSButton } + view.subviews.flatMap(buttons)
    }

    private func center(_ button: NSButton) -> NSPoint {
        button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
    }

    @Test("Every ancestor has the right target; arrows, whitespace and virtual locations reject files")
    func targets() throws {
        let (window, bar, _) = fixture()
        defer { window.contentView = nil }
        #expect(bar.registeredDraggedTypes.contains(.fileURL))
        for button in buttons(bar) {
            let destination = bar.dropDestination(atWindowPoint: center(button))
            if button.identifier?.rawValue == "breadcrumbCrumb", button.tag >= 0 {
                let paths = ["/", "/Volumes", "/Volumes/Test", "/Volumes/Test/Parent", "/Volumes/Test/Parent/Current"]
                #expect(destination?.path == paths[button.tag])
            } else {
                #expect(destination == nil)
            }
        }
        bar.beginEditing()
        #expect(bar.dropDestination(atWindowPoint: NSPoint(x: 100, y: 207)) == nil)
        for show in [bar.showHome, bar.showNetwork, bar.showRecents] {
            show()
            bar.layoutSubtreeIfNeeded()
            #expect(buttons(bar).allSatisfy { bar.dropDestination(atWindowPoint: center($0)) == nil })
        }
    }

    @Test("The abbreviated home ancestor accepts files only while browsing inside home")
    func homeAncestor() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let (window, bar, _) = fixture(path: home.appendingPathComponent("Downloads/Child").path)
        defer { window.contentView = nil }
        let homeButton = try #require(buttons(bar).first { $0.identifier?.rawValue == "breadcrumbCrumb" && $0.tag == -1 })
        #expect(bar.dropDestination(atWindowPoint: center(homeButton)) == home)
    }

    @Test("Dragging a batch to a parent highlights, moves all URLs and does not navigate")
    func moveBatch() throws {
        let (window, bar, recorder) = fixture()
        defer { window.contentView = nil }
        let parent = try #require(buttons(bar).first { $0.title == "Parent" })
        let grandparent = try #require(buttons(bar).first { $0.title == "Test" })
        let urls = ["a.txt", "b.txt", "folder"].map { URL(fileURLWithPath: "/Volumes/Test/Parent/Current/" + $0) }
        let info = TestFileDrag(urls: urls)
        defer { info.draggingPasteboard.releaseGlobally() }
        info.draggingDestinationWindow = window
        info.draggingLocation = center(parent)
        #expect(bar.draggingEntered(info) == .move)
        #expect(parent.layer?.borderWidth == 1)
        info.draggingLocation = center(grandparent)
        #expect(bar.draggingUpdated(info) == .move)
        #expect(parent.layer?.borderWidth == 0)
        #expect(grandparent.layer?.borderWidth == 1)
        #expect(bar.prepareForDragOperation(info))
        #expect(bar.performDragOperation(info))
        #expect(recorder.imports.count == 1)
        #expect(recorder.imports.first?.urls == urls)
        #expect(recorder.imports.first?.destination.path == "/Volumes/Test")
        #expect(recorder.imports.first?.move == true)
        #expect(grandparent.layer?.borderWidth == 0)
        #expect(!bar.isEditingAddress)
        #expect(recorder.navigations == 0)
    }

    @Test("External drops copy; exit, cancel and path changes clear highlighting")
    func copyAndCleanup() throws {
        let (window, bar, recorder) = fixture()
        defer { window.contentView = nil }
        let parent = try #require(buttons(bar).first { $0.title == "Parent" })
        let info = TestFileDrag(urls: [URL(fileURLWithPath: "/unmounted/Other/file.txt")])
        defer { info.draggingPasteboard.releaseGlobally() }
        info.draggingSource = nil
        info.draggingLocation = center(parent)
        #expect(bar.draggingEntered(info) == .copy)
        bar.draggingExited(info)
        #expect(parent.layer?.borderWidth == 0)
        #expect(bar.draggingEntered(info) == .copy)
        bar.draggingEnded(info)
        #expect(parent.layer?.borderWidth == 0)
        #expect(recorder.imports.isEmpty)
        #expect(bar.draggingEntered(info) == .copy)
        #expect(bar.performDragOperation(info))
        #expect(recorder.imports.first?.move == false)
        #expect(bar.draggingEntered(info) == .copy)
        bar.showRecents()
        #expect(parent.layer?.borderWidth == 0)
        #expect(!bar.prepareForDragOperation(info))
        #expect(!bar.performDragOperation(info))
        #expect(recorder.imports.count == 1)
    }

    @Test("Unknown source directories reject self/descendant drops without metadata IO")
    func rejectRecursiveDrop() throws {
        let (window, bar, recorder) = fixture()
        defer { window.contentView = nil }
        let parent = try #require(buttons(bar).first { $0.title == "Parent" })
        let current = try #require(buttons(bar).first { $0.title == "Current" })
        let info = TestFileDrag(urls: [URL(fileURLWithPath: "/Volumes/Test/Parent", isDirectory: true)])
        defer { info.draggingPasteboard.releaseGlobally() }
        for button in [parent, current] {
            info.draggingLocation = center(button)
            #expect(bar.draggingEntered(info).isEmpty)
            #expect(!bar.prepareForDragOperation(info))
            #expect(!bar.performDragOperation(info))
            #expect(button.layer?.borderWidth == 0)
        }
        #expect(recorder.imports.isEmpty)
    }

    @Test("Move to an ancestor uses the transfer journal and restores every file on undo")
    func transferAndUndo() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BreadcrumbTransfer-\(UUID().uuidString)", isDirectory: true)
        let current = root.appendingPathComponent("Parent/Current", isDirectory: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = ["a.txt", "b.txt"].map { current.appendingPathComponent($0) }
        for (index, url) in sources.enumerated() { try Data("contents \(index)".utf8).write(to: url) }
        let info = TestFileDrag(urls: sources)
        defer { info.draggingPasteboard.releaseGlobally() }
        let list = FileListViewController()
        let request = try #require(list.fileDropDecision(for: info, target: .folder(root, isPackage: false)))
        let destination = try #require(request.decision.destination)
        let result = try FileTransferTask(kind: request.decision.shouldMove ? .move : .copy,
                                          sources: request.urls, destinationDirectory: destination).run()
        #expect(result.completedMoves.count == 2)
        #expect(sources.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        try FileSystemService().undoMoves(result.completedMoves.map { (current: $0.destination, original: $0.source) })
        for (index, url) in sources.enumerated() {
            #expect(try String(contentsOf: url, encoding: .utf8) == "contents \(index)")
        }
    }
}
