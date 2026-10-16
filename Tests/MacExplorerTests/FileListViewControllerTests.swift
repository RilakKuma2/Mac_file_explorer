import AppKit
import Testing
@testable import MacExplorer

private final class RenameRecorder: FileListViewControllerDelegate {
    var names: [String] = []
    func fileList(_ fileList: FileListViewController, didRequestRename item: FileItem, to newName: String) {
        names.append(newName)
    }
    func fileList(_ fileList: FileListViewController, didActivate item: FileItem) {}
    func fileListSelectionDidChange(_ fileList: FileListViewController) {}
    func fileListDidRequestRename(_ fileList: FileListViewController) {}
    func fileListDidRequestTrash(_ fileList: FileListViewController) {}
    func fileListDidRequestQuickLook(_ fileList: FileListViewController) {}
    func fileListDidRequestBack(_ fileList: FileListViewController) {}
    func fileListDidRequestForward(_ fileList: FileListViewController) {}
    func fileList(_ fileList: FileListViewController, didRequestImport urls: [URL], destination: URL, move: Bool) {}
    func fileList(_ fileList: FileListViewController, didChangeViewMode mode: FileViewMode) {}
}

@Suite("FileListViewController")
struct FileListViewControllerTests {
    @Test("Folder changes reset to the inset-aware top and layout preserves it")
    @MainActor
    func folderNavigationWithHeaderInsets() throws {
        let fixture = try makeFileFixture(names: (0..<120).map { "file-\($0).txt" })
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        for mode in [FileViewMode.details, .icons] {
            let controller = FileListViewController()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 500),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentViewController = controller
            controller.display(items: fixture.items, in: fixture.directory)
            controller.setViewMode(mode)
            controller.view.layoutSubtreeIfNeeded()
            let scroll = try #require(allSubviews(of: controller.view)
                .compactMap { $0 as? NSScrollView }.first { !$0.isHidden })
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentInsets = NSEdgeInsets(top: 28, left: 0, bottom: 0, right: 0)
            scroll.contentView.automaticallyAdjustsContentInsets = false
            scroll.contentView.contentInsets = scroll.contentInsets
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
            controller.display(items: fixture.items, in: fixture.directory.appendingPathComponent("other"))
            controller.view.layoutSubtreeIfNeeded()
            controller.viewDidLayout()
            #expect(abs(scroll.contentView.bounds.minY + scroll.contentView.contentInsets.top) < 0.5)
        }
    }

    @Test("Shrinking a folder clamps stale vertical scrolling in both views")
    @MainActor
    func shrinkingFolderScroll() throws {
        let fixture = try makeFileFixture(names: (0..<120).map { "file-\($0).txt" })
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        for mode in [FileViewMode.details, .icons] {
            let controller = FileListViewController()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 500),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentViewController = controller
            controller.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 500)
            controller.display(items: fixture.items, in: fixture.directory)
            controller.setViewMode(mode)
            controller.view.layoutSubtreeIfNeeded()
            let scroll = try #require(allSubviews(of: controller.view)
                .compactMap { $0 as? NSScrollView }.first { !$0.isHidden })
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 500))
            scroll.reflectScrolledClipView(scroll.contentView)
            #expect(scroll.contentView.bounds.origin.y > 0)
            controller.display(items: Array(fixture.items.prefix(2)), in: fixture.directory)
            controller.view.layoutSubtreeIfNeeded()
            #expect(scroll.contentView.bounds.origin.y <= 0)
        }
    }

    @Test("Inline rename obtains a field editor in both view modes")
    @MainActor
    func inlineRenameEditor() async throws {
        let fixture = try makeFileFixture(names: ["before.txt"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        for mode in [FileViewMode.details, .icons] {
            let controller = FileListViewController()
            let recorder = RenameRecorder()
            controller.delegate = recorder
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 500),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentViewController = controller
            controller.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 500)
            controller.view.layoutSubtreeIfNeeded()
            controller.display(items: fixture.items, in: fixture.directory)
            controller.setViewMode(mode)
            controller.view.layoutSubtreeIfNeeded()
            controller.select(url: fixture.items[0].url)
            controller.beginInlineRename()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            let editor = try #require(window.firstResponder as? NSTextView)
            #expect(editor.string == "before.txt")
            #expect(editor.selectedRange() == NSRange(location: 0, length: 6))
            #expect(editor.isEditable)
            #expect(editor.drawsBackground)
            #expect(editor.backgroundColor == NSColor.textBackgroundColor)
            editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
            let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber,
                context: nil, characters: "a", charactersIgnoringModifiers: "a",
                isARepeat: false, keyCode: 0))
            editor.keyDown(with: key)
            #expect(editor.string == "a")
            editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
            editor.insertText("after", replacementRange: editor.selectedRange())
            controller.updateTagMetadata(items: fixture.items, in: fixture.directory)
            #expect(editor.string == "after")
            let editingField = try #require(allSubviews(of: controller.view)
                .compactMap { $0 as? NSTextField }.first { $0.isEditable })
            #expect(editingField.stringValue == "after")
            #expect(editingField.isBezeled)
            #expect(editingField.focusRingType == .exterior)
            if mode == .details {
                let row = try #require(allSubviews(of: controller.view)
                    .compactMap { $0 as? FileTableRowView }.first { $0.isSelected })
                #expect(row.isRenaming)
                #expect(row.interiorBackgroundStyle == .normal)
            }
            controller.display(items: fixture.items, in: fixture.directory,
                               preservingSelection: [fixture.items[0].url])
            #expect(window.firstResponder === editor)
            #expect(editor.string == "after")
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            #expect(!(window.firstResponder is NSTextView))
            #expect(recorder.names == ["after"])
            controller.select(url: fixture.items[0].url)
            controller.beginInlineRename()
            let cancelEditor = try #require(window.firstResponder as? NSTextView)
            cancelEditor.string = "cancelled"
            cancelEditor.didChangeText()
            cancelEditor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            #expect(recorder.names == ["after"])
            #expect(!(window.firstResponder is NSTextView))
        }
    }

    @Test("List background and group context menus clear file selection")
    @MainActor
    func backgroundContextMenu() throws {
        let fixture = try makeFileFixture(names: ["alpha.txt", "beta.txt"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let controller = FileListViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1800, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        controller.view.frame = NSRect(x: 0, y: 0, width: 1800, height: 500)
        controller.display(items: fixture.items, in: fixture.directory)
        controller.view.layoutSubtreeIfNeeded()
        let table = try #require(allSubviews(of: controller.view).compactMap { $0 as? FileTableView }.first)
        func context(at point: NSPoint) throws -> NSMenu {
            let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown,
                location: table.convert(point, to: nil), modifierFlags: [], timestamp: 1,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            let menu = try #require(table.menu(for: event))
            controller.menuNeedsUpdate(menu)
            return menu
        }
        controller.select(urls: fixture.items.map(\.url))
        let fileMenu = try context(at: NSPoint(x: 60, y: table.rect(ofRow: 0).midY))
        #expect(controller.selectedItems.count == 2)
        #expect(fileMenu.items.contains { $0.action == #selector(MainViewController.rename(_:)) })
        let blankMenu = try context(at: NSPoint(x: table.selectionContentTrailingEdge + 15,
                                               y: table.rect(ofRow: 0).midY))
        #expect(controller.selectedItems.isEmpty)
        #expect(!blankMenu.items.contains { $0.action == #selector(MainViewController.rename(_:)) })
        #expect(blankMenu.items.contains { $0.action == #selector(MainViewController.newFolder(_:)) })
        controller.setDateGroupingMode(.enabled)
        controller.select(urls: fixture.items.map(\.url))
        _ = try context(at: NSPoint(x: 60, y: table.rect(ofRow: 0).midY))
        #expect(controller.selectedItems.isEmpty)
    }

    @Test("Small precise wheel notches zoom symmetrically in both directions")
    func preciseWheelZoomDirections() {
        var resolver = ZoomScrollStepResolver()

        #expect(resolver.consume(delta: 0.1, precise: true, timestamp: 1.0) == 1)
        #expect(resolver.consume(delta: -0.1, precise: true, timestamp: 1.01) == -1)

        var accumulatingResolver = ZoomScrollStepResolver()
        #expect(accumulatingResolver.consume(delta: 0.04, precise: true, timestamp: 2.0) == nil)
        #expect(accumulatingResolver.consume(delta: 0.04, precise: true, timestamp: 2.01) == 1)
    }

    @Test("Small non-precise mouse notches zoom in either direction")
    func mouseWheelZoomDirections() {
        var resolver = ZoomScrollStepResolver()

        #expect(resolver.consume(delta: 0.01, precise: false, timestamp: 1.0) == 1)
        #expect(resolver.consume(delta: -0.01, precise: false, timestamp: 1.01) == -1)
        #expect(resolver.consume(delta: 0.01, precise: false, timestamp: 1.02) == 1)
        #expect(resolver.consume(delta: 0.01, precise: false, timestamp: 1.03) == nil)
        #expect(resolver.consume(delta: 0.01, precise: false, timestamp: 1.08) == 1)
    }

    @Test("Address bar can switch directly to path editing")
    @MainActor
    func addressBarEditing() {
        let addressBar = BreadcrumbBarView()
        addressBar.show(url: URL(fileURLWithPath: "/Users"))

        let addressButton = allSubviews(of: addressBar)
            .compactMap { $0 as? NSButton }
            .first { $0.toolTip?.contains("⌘L") == true }
        addressButton?.performClick(nil)

        let visibleTextFields = addressBar.subviews.compactMap { $0 as? NSTextField }.filter { !$0.isHidden }
        #expect(addressButton != nil)
        #expect(visibleTextFields.count == 1)
        #expect(visibleTextFields.first?.stringValue == "/Users")
    }

    @Test("Breadcrumb components navigate without entering address editing")
    @MainActor
    func breadcrumbComponentNavigation() {
        final class Delegate: BreadcrumbBarViewDelegate {
            var selectedURL: URL?
            func breadcrumbBarDidRequestHome(_ breadcrumbBar: BreadcrumbBarView) {}
            func breadcrumbBar(_ breadcrumbBar: BreadcrumbBarView, didSelect url: URL) { selectedURL = url }
            func breadcrumbBar(_ breadcrumbBar: BreadcrumbBarView, didSubmitPath path: String) {}
        }

        let delegate = Delegate()
        let addressBar = BreadcrumbBarView()
        addressBar.delegate = delegate
        addressBar.show(url: URL(fileURLWithPath: "/Volumes/Demo Drive/miniatures"))

        let volumeButton = allSubviews(of: addressBar)
            .compactMap { $0 as? NSButton }
            .first { $0.title == "Demo Drive" }
        volumeButton?.performClick(nil)

        let addressEditorIsHidden = addressBar.subviews
            .compactMap { $0 as? NSTextField }
            .allSatisfy { $0.isHidden }
        #expect(delegate.selectedURL?.path == "/Volumes/Demo Drive")
        #expect(addressEditorIsHidden)
    }

    @Test("Large icon view scales the artwork with its cell")
    @MainActor
    func largeIconActuallyScalesImage() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacExplorerIconTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        let item = FileItem(url: directory, resourceValues: values)
        let collectionItem = FileCollectionItem()
        _ = collectionItem.view

        collectionItem.configure(item: item, iconSize: 160)

        let imageView = allSubviews(of: collectionItem.view).compactMap { $0 as? NSImageView }.first
        #expect(imageView?.imageScaling == .scaleProportionallyUpOrDown)
        #expect(imageView?.constraints.contains(where: { $0.firstAttribute == .width && $0.constant == 160 }) == true)
        #expect(imageView?.constraints.contains(where: { $0.firstAttribute == .height && $0.constant == 160 }) == true)
    }

    @MainActor
    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(allSubviews(of:))
    }

    @Test("Zoom steps cross between details and icon views")
    @MainActor
    func zoomChangesViewMode() {
        let controller = FileListViewController()
        _ = controller.view

        #expect(controller.zoomLevel == 1)
        #expect(controller.viewMode == .details)

        controller.adjustZoomStep(1)
        #expect(controller.zoomLevel == 2)
        #expect(controller.viewMode == .icons)

        controller.adjustZoomStep(-1)
        #expect(controller.zoomLevel == 1)
        #expect(controller.viewMode == .details)
    }

    @Test("Zoom levels are clamped")
    @MainActor
    func zoomClampsAtBounds() {
        let controller = FileListViewController()
        _ = controller.view
        for _ in 0..<10 { controller.adjustZoomStep(1) }
        #expect(controller.zoomLevel == 5)
        for _ in 0..<10 { controller.adjustZoomStep(-1) }
        #expect(controller.zoomLevel == 0)
    }

    @Test("Choosing the active view mode preserves its current zoom")
    @MainActor
    func activeViewModePreservesZoom() {
        let controller = FileListViewController()
        _ = controller.view

        controller.adjustZoomStep(-1)
        #expect(controller.viewMode == .details)
        #expect(controller.zoomLevel == 0)
        controller.setViewMode(.details)
        #expect(controller.zoomLevel == 0)

        controller.setViewMode(.icons)
        controller.adjustZoomStep(1)
        let iconZoom = controller.zoomLevel
        #expect(iconZoom > 2)
        controller.setViewMode(.icons)
        #expect(controller.zoomLevel == iconZoom)
    }

    @Test("Folder loading and empty results expose distinct content states")
    @MainActor
    func loadingAndEmptyContentStates() {
        let controller = FileListViewController()
        _ = controller.view

        controller.showLoading(title: "Loading…", clearCurrentItems: true)
        #expect(controller.contentState == .loading("Loading…"))
        #expect(controller.visibleItems.isEmpty)

        let directory = URL(fileURLWithPath: "/tmp/empty-state", isDirectory: true)
        controller.display(items: [], in: directory)
        #expect(controller.contentState == .empty(
            title: L10n.text("This folder is empty."),
            detail: nil
        ))

        controller.display(
            items: [],
            in: directory,
            emptyTitle: L10n.text("No items match your search."),
            emptyDetail: L10n.text("Try a different name or filter.")
        )
        #expect(controller.contentState == .empty(
            title: L10n.text("No items match your search."),
            detail: L10n.text("Try a different name or filter.")
        ))
    }

    @Test("Typing selects the first filename with that prefix")
    @MainActor
    func typeToSelect() throws {
        let fixture = try makeFileFixture(names: ["alpha.txt", "beta.txt", "bravo.txt", "charlie.txt"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let controller = FileListViewController()
        _ = controller.view
        controller.display(items: fixture.items, in: fixture.directory)
        let table = try #require(allSubviews(of: controller.view).compactMap { $0 as? FileTableView }.first)

        table.keyDown(with: try keyEvent(character: "b", keyCode: 11, timestamp: 1.0))
        #expect(controller.selectedItems.first?.url.lastPathComponent == "beta.txt")

        table.keyDown(with: try keyEvent(character: "r", keyCode: 15, timestamp: 1.1))
        #expect(controller.selectedItems.first?.url.lastPathComponent == "bravo.txt")
    }

    @Test("Shift and arrow keys extend a contiguous selection")
    @MainActor
    func shiftRangeSelection() throws {
        let fixture = try makeFileFixture(names: ["alpha.txt", "beta.txt", "bravo.txt", "charlie.txt"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let controller = FileListViewController()
        _ = controller.view
        controller.display(items: fixture.items, in: fixture.directory)
        let table = try #require(allSubviews(of: controller.view).compactMap { $0 as? FileTableView }.first)
        controller.select(url: fixture.items[0].url)

        table.keyDown(with: try keyEvent(character: "", keyCode: 125, modifiers: .shift, timestamp: 1.0))
        table.keyDown(with: try keyEvent(character: "", keyCode: 125, modifiers: .shift, timestamp: 1.1))

        #expect(Set(controller.selectedItems.map { $0.url.lastPathComponent }) == [
            "alpha.txt", "beta.txt", "bravo.txt"
        ])
    }

    @Test("Plain-clicking one of several selected rows focuses it immediately")
    @MainActor
    func plainClickCollapsesMultipleSelection() throws {
        let fixture = try makeFileFixture(names: ["alpha.txt", "beta.txt", "charlie.txt"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let controller = FileListViewController()
        _ = controller.view
        controller.display(items: fixture.items, in: fixture.directory)
        let table = try #require(allSubviews(of: controller.view).compactMap { $0 as? FileTableView }.first)
        table.selectRowIndexes(IndexSet([0, 1, 2]), byExtendingSelection: false)

        table.collapseMultipleSelectionForPlainClick(at: 1, modifiers: [])

        #expect(table.selectedRowIndexes == IndexSet(integer: 1))
        #expect(table.tableColumns.last?.identifier == FileTableView.spacerColumnIdentifier)
        let rowView = try #require(controller.tableView(table, rowViewForRow: 1) as? FileTableRowView)
        let sizeColumn = table.column(withIdentifier: NSUserInterfaceItemIdentifier("size"))
        #expect(rowView.selectionTrailingEdgeProvider?() == table.rect(ofColumn: sizeColumn).maxX)
    }

    @Test("Cut items are shown translucently in list view")
    @MainActor
    func cutItemAppearance() throws {
        let fixture = try makeFileFixture(names: ["cut-me.txt", "keep-me.txt"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let controller = FileListViewController()
        _ = controller.view
        controller.display(items: fixture.items, in: fixture.directory)
        controller.setCutItems([fixture.items[0].url])
        let table = try #require(allSubviews(of: controller.view).compactMap { $0 as? FileTableView }.first)
        let nameColumn = try #require(table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("name")))
        let cutRow = try #require(fixture.items.firstIndex { $0.url.lastPathComponent == "cut-me.txt" })
        let normalRow = try #require(fixture.items.firstIndex { $0.url.lastPathComponent == "keep-me.txt" })

        let cutCell = try #require(controller.tableView(table, viewFor: nameColumn, row: cutRow) as? NSTableCellView)
        let cutAlpha = cutCell.alphaValue
        let normalCell = try #require(controller.tableView(table, viewFor: nameColumn, row: normalRow) as? NSTableCellView)
        #expect(cutAlpha < normalCell.alphaValue)
    }

    @Test("Selecting multiple result URLs keeps every item selected")
    @MainActor
    func selectMultipleURLs() throws {
        let fixture = try makeFileFixture(names: ["one.txt", "three.txt", "two.txt"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let controller = FileListViewController()
        _ = controller.view
        controller.display(items: fixture.items, in: fixture.directory)

        controller.select(urls: [fixture.items[0].url, fixture.items[2].url])

        #expect(Set(controller.selectedItems.map(\.url)) == Set([fixture.items[0].url, fixture.items[2].url]))
    }

    @Test("Icon selections are returned in visible order")
    @MainActor
    func iconSelectionOrder() throws {
        let fixture = try makeFileFixture(names: ["charlie.txt", "alpha.txt", "bravo.txt"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let controller = FileListViewController()
        _ = controller.view
        controller.display(items: fixture.items, in: fixture.directory)
        controller.setViewMode(.icons)

        controller.select(urls: Array(fixture.items.map(\.url).reversed()))

        #expect(controller.selectedItems.map { $0.url.lastPathComponent } == [
            "alpha.txt", "bravo.txt", "charlie.txt"
        ])
    }

    @Test("A context-menu selection becomes the next Shift-selection anchor")
    @MainActor
    func contextSelectionUpdatesRangeAnchor() throws {
        let fixture = try makeFileFixture(names: ["alpha.txt", "bravo.txt", "charlie.txt", "delta.txt"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let controller = FileListViewController()
        _ = controller.view
        controller.display(items: fixture.items, in: fixture.directory)
        let table = try #require(allSubviews(of: controller.view).compactMap { $0 as? FileTableView }.first)
        controller.select(url: fixture.items[0].url)

        // FileTableView performs this selection immediately before opening its
        // contextual menu. The menu callback must not leave the old anchor behind.
        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        controller.menuWillOpen(try #require(table.menu))
        table.keyDown(with: try keyEvent(
            character: "",
            keyCode: 125,
            modifiers: .shift,
            timestamp: 1.0
        ))

        #expect(controller.selectedItems.map { $0.url.lastPathComponent } == [
            "charlie.txt", "delta.txt"
        ])
    }

    @Test("Folder size calculation totals nested files and honors cancellation")
    func folderSizeCalculation() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacExplorerFolderSizeTest-\(UUID().uuidString)", isDirectory: true)
        let nested = folder.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(repeating: 1, count: 7).write(to: folder.appendingPathComponent("first.bin"))
        try Data(repeating: 2, count: 11).write(to: nested.appendingPathComponent("second.bin"))

        #expect(FolderSizeCalculator.logicalSize(of: folder) == 18)
        #expect(FolderSizeCalculator.logicalSize(of: folder, isCancelled: { true }) == nil)
    }

    @Test("Folder sizes stay blank until the list option is enabled")
    @MainActor
    func folderSizeToggle() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacExplorerFolderSizeToggleTest-\(UUID().uuidString)", isDirectory: true)
        let childFolder = folder.appendingPathComponent("Visible Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: childFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(repeating: 3, count: 23).write(to: childFolder.appendingPathComponent("item.bin"))
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey,
            .contentModificationDateKey, .fileSizeKey, .localizedTypeDescriptionKey, .contentTypeKey,
            .volumeIsLocalKey
        ]
        let item = FileItem(url: childFolder, resourceValues: try childFolder.resourceValues(forKeys: keys))
        let controller = FileListViewController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 240)
        controller.view.layoutSubtreeIfNeeded()
        controller.display(items: [item], in: folder)
        let table = try #require(allSubviews(of: controller.view).compactMap { $0 as? FileTableView }.first)
        let sizeColumn = try #require(table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("size")))

        let disabledCell = try #require(controller.tableView(table, viewFor: sizeColumn, row: 0) as? NSTableCellView)
        #expect(disabledCell.textField?.stringValue == "")

        controller.setShowsFolderSizes(true)
        let calculatingCell = try #require(controller.tableView(table, viewFor: sizeColumn, row: 0) as? NSTableCellView)
        #expect(controller.showsFolderSizes)
        #expect(calculatingCell.textField?.stringValue == L10n.text("Calculating") + "…")
        for _ in 0..<100 where controller.cachedFolderSize(for: childFolder) == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(controller.cachedFolderSize(for: childFolder) == 23)

        controller.setShowsFolderSizes(false)
        let disabledAgain = try #require(controller.tableView(table, viewFor: sizeColumn, row: 0) as? NSTableCellView)
        #expect(!controller.showsFolderSizes)
        #expect(disabledAgain.textField?.stringValue == "")
    }

    @Test("Hidden tabs do not keep calculating folder sizes")
    @MainActor
    func hiddenFolderSizeWorkIsSuspended() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacExplorerHiddenFolderSizeTest-\(UUID().uuidString)", isDirectory: true)
        let childFolder = folder.appendingPathComponent("Visible Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: childFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(repeating: 1, count: 31).write(to: childFolder.appendingPathComponent("item.bin"))
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey,
            .contentModificationDateKey, .fileSizeKey, .localizedTypeDescriptionKey, .contentTypeKey,
            .volumeIsLocalKey
        ]
        let item = FileItem(url: childFolder, resourceValues: try childFolder.resourceValues(forKeys: keys))
        let controller = FileListViewController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 240)
        controller.view.layoutSubtreeIfNeeded()
        controller.display(items: [item], in: folder)
        controller.view.layoutSubtreeIfNeeded()
        controller.setShowsFolderSizes(true)
        controller.setContentVisible(false)

        try await Task.sleep(nanoseconds: 80_000_000)
        #expect(controller.cachedFolderSize(for: childFolder) == nil)

        controller.setContentVisible(true)
        for _ in 0..<100 where controller.cachedFolderSize(for: childFolder) == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(controller.cachedFolderSize(for: childFolder) == 31)
    }

    @Test("Date grouping is automatic and persists an explicit folder override")
    @MainActor
    func perFolderDateGrouping() throws {
        let names = (0..<50).map { String(format: "item-%02d.txt", $0) }
        let fixture = try makeFileFixture(names: names) { index in
            Calendar.current.date(byAdding: .day, value: index < 25 ? 0 : -10, to: Date())
        }
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let automaticController = FileListViewController()
        _ = automaticController.view
        automaticController.display(items: fixture.items, in: fixture.directory)
        #expect(automaticController.dateGroupingMode == .automatic)
        #expect(automaticController.isDateGroupingEnabled)

        let table = try #require(allSubviews(of: automaticController.view)
            .compactMap { $0 as? FileTableView }
            .first)
        let groupHeader = try #require(automaticController.tableView(table, viewFor: nil, row: 0) as? NSTableCellView)
        #expect(groupHeader.textField?.stringValue == L10n.text("Today"))
        #expect(groupHeader.imageView?.image != nil)
        let disclosure = try #require(allSubviews(of: groupHeader)
            .compactMap { $0 as? NSControl }
            .first { $0.accessibilityRole() == .disclosureTriangle })
        #expect(disclosure.accessibilityLabel() == L10n.text("Today"))
        #expect(disclosure.isAccessibilityExpanded())
        let expandedRowCount = automaticController.numberOfRows(in: table)

        #expect(disclosure.accessibilityPerformPress())
        #expect(automaticController.numberOfRows(in: table) == expandedRowCount - 25)
        let collapsedHeader = try #require(automaticController.tableView(
            table,
            viewFor: nil,
            row: 0
        ) as? NSTableCellView)
        let collapsedDisclosure = try #require(allSubviews(of: collapsedHeader)
            .compactMap { $0 as? NSControl }
            .first { $0.accessibilityRole() == .disclosureTriangle })
        #expect(!collapsedDisclosure.isAccessibilityExpanded())
        collapsedDisclosure.keyDown(with: try keyEvent(
            character: "",
            keyCode: 124,
            timestamp: 1.0
        ))
        #expect(automaticController.numberOfRows(in: table) == expandedRowCount)

        automaticController.select(url: fixture.items[0].url)
        #expect(!automaticController.selectedItems.isEmpty)
        #expect(table.onNonItemClick?(0) == true)
        #expect(automaticController.selectedItems.isEmpty)
        #expect(automaticController.numberOfRows(in: table) == expandedRowCount - 25)

        let collapsedController = FileListViewController()
        _ = collapsedController.view
        collapsedController.display(items: fixture.items, in: fixture.directory)
        let collapsedTable = try #require(allSubviews(of: collapsedController.view)
            .compactMap { $0 as? FileTableView }
            .first)
        #expect(collapsedController.numberOfRows(in: collapsedTable) == expandedRowCount - 25)
        collapsedController.select(urls: [fixture.items[0].url, fixture.items[1].url])
        #expect(collapsedController.selectedItems.count == 2)
        #expect(collapsedController.numberOfRows(in: collapsedTable) == expandedRowCount)
        #expect(collapsedTable.onNonItemClick?(0) == true)
        #expect(collapsedController.numberOfRows(in: collapsedTable) == expandedRowCount - 25)
        #expect(collapsedTable.onNonItemClick?(0) == true)
        #expect(collapsedController.numberOfRows(in: collapsedTable) == expandedRowCount)

        automaticController.setDateGroupingMode(.disabled)
        let restoredController = FileListViewController()
        _ = restoredController.view
        restoredController.display(items: fixture.items, in: fixture.directory)
        #expect(restoredController.dateGroupingMode == .disabled)
        #expect(!restoredController.isDateGroupingEnabled)

        restoredController.setDateGroupingMode(.automatic)
    }

    @Test("Automatic date grouping starts at fifty items")
    func automaticDateGroupingThreshold() throws {
        let fixture49 = try makeFileFixture(names: (0..<49).map { "under-\($0).txt" }) { index in
            Calendar.current.date(byAdding: .day, value: index.isMultiple(of: 2) ? 0 : -10, to: Date())
        }
        let fixture50 = try makeFileFixture(names: (0..<50).map { "at-\($0).txt" }) { index in
            Calendar.current.date(byAdding: .day, value: index.isMultiple(of: 2) ? 0 : -10, to: Date())
        }
        defer {
            try? FileManager.default.removeItem(at: fixture49.directory)
            try? FileManager.default.removeItem(at: fixture50.directory)
        }

        #expect(!FileDateGroupingPolicy.shouldEnable(for: fixture49.items))
        #expect(FileDateGroupingPolicy.shouldEnable(for: fixture50.items))
    }

    @Test("Icon date-group headers are accessible disclosure groups")
    @MainActor
    func iconDateGroupDisclosure() throws {
        let fixture = try makeFileFixture(names: (0..<50).map { "item-\($0).txt" }) { index in
            Calendar.current.date(byAdding: .day, value: index < 25 ? 0 : -10, to: Date())
        }
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let controller = FileListViewController()
        _ = controller.view
        controller.display(items: fixture.items, in: fixture.directory)
        controller.setViewMode(.icons)
        let collection = try #require(allSubviews(of: controller.view)
            .compactMap { $0 as? NSCollectionView }
            .first)
        let firstSectionCount = controller.collectionView(collection, numberOfItemsInSection: 0)
        #expect(firstSectionCount == 25)

        let header = controller.collectionView(
            collection,
            viewForSupplementaryElementOfKind: NSCollectionView.elementKindSectionHeader,
            at: IndexPath(item: 0, section: 0)
        )
        #expect(header.accessibilityRole() == .group)
        let disclosure = try #require(allSubviews(of: header)
            .compactMap { $0 as? NSControl }
            .first { $0.accessibilityRole() == .disclosureTriangle })
        #expect(disclosure.acceptsFirstResponder)
        #expect(disclosure.accessibilityPerformPress())
        #expect(controller.collectionView(collection, numberOfItemsInSection: 0) == 0)
        controller.selectAllItems()
        #expect(controller.selectedItems.count == 25)
        #expect(collection.selectionIndexPaths.allSatisfy { $0.section != 0 })
    }

    @Test("Menu sorting stays synchronized with the list header indicator")
    @MainActor
    func sortHeaderSynchronization() throws {
        let fixture = try makeFileFixture(names: ["b.txt", "a.txt"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let controller = FileListViewController()
        _ = controller.view
        controller.display(items: fixture.items, in: fixture.directory)

        controller.setSort(key: .kind)
        controller.setSort(ascending: false)

        let table = try #require(allSubviews(of: controller.view)
            .compactMap { $0 as? NSTableView }
            .first)
        let descriptor = try #require(table.sortDescriptors.first)
        #expect(descriptor.key == "kind")
        #expect(!descriptor.ascending)

        let preloadedController = FileListViewController()
        preloadedController.setSort(key: .modifiedAt)
        preloadedController.setSort(ascending: false)
        _ = preloadedController.view
        let preloadedTable = try #require(allSubviews(of: preloadedController.view)
            .compactMap { $0 as? NSTableView }
            .first)
        #expect(preloadedTable.sortDescriptors.first?.key == "modified")
        #expect(preloadedTable.sortDescriptors.first?.ascending == false)
    }

    @MainActor
    private func keyEvent(
        character: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
        timestamp: TimeInterval
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: timestamp,
            windowNumber: 0,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    private func makeFileFixture(
        names: [String],
        modifiedAt: (Int) -> Date? = { _ in nil }
    ) throws -> (directory: URL, items: [FileItem]) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacExplorerListTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey,
            .contentModificationDateKey, .fileSizeKey, .localizedTypeDescriptionKey, .contentTypeKey
        ]
        let items = try names.enumerated().map { index, name -> FileItem in
            let url = directory.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: Data())
            if let date = modifiedAt(index) {
                try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            }
            return FileItem(url: url, resourceValues: try url.resourceValues(forKeys: keys))
        }
        return (directory, FileSortDescriptor().sort(items))
    }
}
