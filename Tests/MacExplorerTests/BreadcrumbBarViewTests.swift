import AppKit
import Testing
@testable import MacExplorer

@Suite("BreadcrumbBarView")
struct BreadcrumbBarViewTests {
    @Test("Narrow paths retain readable recent components and restore ancestors when widened")
    @MainActor
    func narrowPathComponents() throws {
        let bar = BreadcrumbBarView(frame: NSRect(x: 0, y: 0, width: 200, height: 32))
        bar.show(url: URL(fileURLWithPath: "/Volumes/Test/Parent/Current"))
        bar.layoutSubtreeIfNeeded()
        let crumbs = allSubviews(of: bar).compactMap { $0 as? NSButton }.filter {
            $0.identifier?.rawValue == "breadcrumbCrumb" && $0.tag >= 0
        }
        #expect(crumbs.filter { !$0.isHidden }.map(\.title) == ["Current"])
        bar.setFrameSize(NSSize(width: 700, height: 32))
        bar.layoutSubtreeIfNeeded()
        #expect(crumbs.allSatisfy { !$0.isHidden })
    }

    @Test("Address text enables Copy without a selected file")
    @MainActor
    func addressCopyValidation() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let bar = BreadcrumbBarView(frame: NSRect(x: 80, y: 200, width: 600, height: 34))
        window.contentView?.addSubview(bar)
        bar.show(url: URL(fileURLWithPath: "/Volumes/Demo Drive/Downloads"))
        window.contentView?.layoutSubtreeIfNeeded()
        bar.beginEditing()
        let editor = try #require(window.firstResponder as? NSTextView)
        let app = AppDelegate()
        let copy = NSMenuItem(title: "Copy", action: NSSelectorFromString("copyProxy:"), keyEquivalent: "c")
        let cut = NSMenuItem(title: "Cut", action: NSSelectorFromString("cutProxy:"), keyEquivalent: "x")
        #expect(app.validateMenuItem(copy, textEditor: editor))
        #expect(app.validateMenuItem(cut, textEditor: editor))
        #expect((editor.string as NSString).substring(with: editor.selectedRange()) == "/Volumes/Demo Drive/Downloads")
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(!app.validateMenuItem(copy, textEditor: editor))
    }

    @Test("Offset address bar blank space opens a live editable path")
    @MainActor
    func offsetAddressEditing() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let container = try #require(window.contentView)
        let bar = BreadcrumbBarView(frame: NSRect(x: 160, y: 180, width: 650, height: 34))
        container.addSubview(bar)
        bar.show(url: URL(fileURLWithPath: "/Users/Shared"))
        container.layoutSubtreeIfNeeded()
        let point = NSPoint(x: bar.frame.maxX - 12, y: bar.frame.midY)
        #expect(bar.hitTest(point) === bar)
        bar.beginEditing()
        #expect(bar.isEditingAddress)
        let editor = try #require(window.firstResponder as? NSTextView)
        #expect(editor.isEditable)
        editor.insertText("/tmp", replacementRange: editor.selectedRange())
        #expect(editor.string == "/tmp")
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(!bar.isEditingAddress)
        #expect(!(window.firstResponder is NSTextView))
        let crumb = try #require(allSubviews(of: bar).compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "breadcrumbCrumb" })
        let event = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        crumb.mouseEntered(with: event)
        #expect(crumb.layer?.borderWidth == 1)
        crumb.mouseExited(with: event)
        #expect(crumb.layer?.borderWidth == 0)
    }

    @Test("Child folder loader returns only visible direct folders in natural name order")
    func childFolderLoading() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacExplorerBreadcrumbTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let folder2 = root.appendingPathComponent("Folder 2", isDirectory: true)
        let folder10 = root.appendingPathComponent("Folder 10", isDirectory: true)
        try FileManager.default.createDirectory(at: folder10, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: folder2, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(
            at: folder2.appendingPathComponent("Nested", isDirectory: true),
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".Hidden folder", isDirectory: true),
            withIntermediateDirectories: false
        )
        _ = FileManager.default.createFile(
            atPath: root.appendingPathComponent("Document.txt").path,
            contents: Data()
        )

        let children = try BreadcrumbChildDirectoryLoader.load(from: root)

        #expect(children.map(\.title) == ["Folder 2", "Folder 10"])
        #expect(children.map(\.url.lastPathComponent) == ["Folder 2", "Folder 10"])
    }

    @Test("Child folder loader honors cancellation before filesystem enumeration")
    func childFolderLoadingCancellation() {
        #expect(throws: CancellationError.self) {
            try BreadcrumbChildDirectoryLoader.load(
                from: FileManager.default.temporaryDirectory,
                shouldContinue: { false }
            )
        }
    }

    @Test("Child menu finishes during nested menu tracking inside a dispatched click", arguments: ["folders", "empty", "missing"])
    @MainActor
    func childMenuLoadsDuringTracking(outcome: String) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacExplorerMenuTrackingTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        if outcome == "folders" {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Child"), withIntermediateDirectories: false)
        }
        let directory = outcome == "missing" ? root.appendingPathComponent("Missing") : root
        let expected = outcome == "folders" ? "Child"
            : L10n.text(outcome == "empty" ? "No subfolders" : "Unable to load subfolders")
        let bar = BreadcrumbBarView()

        // NavigationClickDispatcher opens the popup inside a main-queue block.
        // Its nested tracking loop must deliver the result before that block
        // returns, not only after the user dismisses the popup.
        let loaded: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let menu = bar.makeChildDirectoryMenu(for: directory)
                let keepAlive = Timer(timeInterval: 0.01, repeats: true) { _ in }
                RunLoop.main.add(keepAlive, forMode: .eventTracking)
                defer {
                    keepAlive.invalidate()
                    bar.menuDidClose(menu)
                }
                let deadline = Date().addingTimeInterval(2)
                while menu.items.first?.title != expected && Date() < deadline {
                    RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.02))
                }
                continuation.resume(returning: menu.items.first?.title == expected)
            }
        }
        #expect(loaded)
    }

    @Test("Breadcrumb separators are accessible keyboard-focusable menu buttons")
    @MainActor
    func accessibleChevronButtons() {
        let bar = BreadcrumbBarView()
        bar.show(url: URL(fileURLWithPath: "/Volumes/Archive/Photos", isDirectory: true))

        let chevrons = allSubviews(of: bar)
            .compactMap { $0 as? NSButton }
            .filter { $0.identifier?.rawValue == "breadcrumbChevron" }

        #expect(chevrons.count == 4)
        #expect(chevrons.allSatisfy { $0.action != nil })
        #expect(chevrons.allSatisfy { $0.acceptsFirstResponder })
        #expect(chevrons.allSatisfy { $0.accessibilityLabel()?.isEmpty == false })
    }

    @Test("Virtual breadcrumbs round-trip through direct address editing")
    @MainActor
    func virtualAddressEditing() throws {
        let bar = BreadcrumbBarView()

        bar.showHome()
        bar.beginEditing()
        let homeField = try #require(
            allSubviews(of: bar).compactMap { $0 as? NSTextField }.first { !$0.isHidden }
        )
        #expect(homeField.stringValue == "home://")

        bar.showTag("Work / Urgent")
        bar.beginEditing()
        let tagField = try #require(
            allSubviews(of: bar).compactMap { $0 as? NSTextField }.first { !$0.isHidden }
        )
        #expect(tagField.stringValue == "tag://Work%20%2F%20Urgent")
    }

    @MainActor
    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(allSubviews(of:))
    }
}
