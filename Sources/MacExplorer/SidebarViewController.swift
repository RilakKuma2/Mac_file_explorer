import AppKit

protocol SidebarViewControllerDelegate: AnyObject {
    func sidebar(_ sidebar: SidebarViewController, didSelect location: BrowserLocation)
}

final class SidebarNode: NSObject {
    let title: String
    let symbolName: String?
    let icon: NSImage?
    let location: BrowserLocation?
    var children: [SidebarNode]
    let isGroup: Bool
    let isPinned: Bool
    let isCustomPinned: Bool
    let isInitiallyExpanded: Bool
    let canEject: Bool

    init(
        title: String,
        symbolName: String? = nil,
        icon: NSImage? = nil,
        location: BrowserLocation? = nil,
        children: [SidebarNode] = [],
        isGroup: Bool = false,
        isPinned: Bool = false,
        isCustomPinned: Bool = false,
        isInitiallyExpanded: Bool = true,
        canEject: Bool = false
    ) {
        self.title = title
        self.canEject = canEject
        self.symbolName = symbolName
        self.icon = icon
        self.location = location
        self.children = children
        self.isGroup = isGroup
        self.isPinned = isPinned
        self.isCustomPinned = isCustomPinned
        self.isInitiallyExpanded = isInitiallyExpanded
    }
}

/// A value-only description of everything that can change in the sidebar.
/// Discovering Finder favorites, cloud providers, and mounted volumes can touch
/// slow file systems, so refreshes build this snapshot away from the main
/// thread. AppKit views and icons are only created after a changed snapshot is
/// delivered back to the main thread.
struct SidebarContentSnapshot: Equatable {
    let showsRecents: Bool
    let showsTrash: Bool
    let picturesURL: URL?
    let trashURL: URL
    let pinnedFolderURLs: [URL]
    let favorites: [FinderSidebarEntry]
    let iCloudLocations: [FinderSidebarEntry]
    let locations: [FinderSidebarEntry]
    let favoriteTags: [FinderTag]

    static func capture() -> SidebarContentSnapshot {
        let manager = FileManager.default
        let finderSidebar = FinderSidebarProvider()
        return SidebarContentSnapshot(
            showsRecents: ExplorerPreferences.showRecentsInSidebar,
            showsTrash: ExplorerPreferences.showTrashInSidebar,
            picturesURL: manager.urls(for: .picturesDirectory, in: .userDomainMask).first,
            trashURL: FileSystemService.shared.primaryTrashDirectory,
            pinnedFolderURLs: ExplorerPreferences.pinnedFolderURLs,
            favorites: finderSidebar.favorites(),
            iCloudLocations: finderSidebar.iCloudLocations(),
            locations: finderSidebar.locations(),
            favoriteTags: FinderTagPalette.favoriteTags
        )
    }
}

/// Keeps asynchronous sidebar discoveries ordered and suppresses publications
/// that would only reload an unchanged outline view. It is deliberately pure so
/// the stale-result and no-op behavior can be covered without AppKit timing.
struct SidebarRefreshGate<Snapshot: Equatable> {
    private(set) var snapshot: Snapshot?
    private(set) var generation = 0

    mutating func installInitial(_ snapshot: Snapshot) {
        self.snapshot = snapshot
    }

    mutating func beginRequest() -> Int {
        generation += 1
        return generation
    }

    mutating func accept(_ candidate: Snapshot, for requestGeneration: Int) -> Bool {
        guard requestGeneration == generation, candidate != snapshot else { return false }
        snapshot = candidate
        return true
    }
}

private final class WeakSidebarReference {
    weak var value: SidebarViewController?

    init(_ value: SidebarViewController) {
        self.value = value
    }
}

private final class SidebarCaptureCancellation {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// One coordinator serves every window. Previously each sidebar synchronously
/// rebuilt itself whenever the app became active, multiplying Finder/volume I/O
/// by the number of open windows. The coordinator coalesces external events,
/// performs one discovery, and only publishes an actually changed model.
private final class SidebarRefreshCoordinator {
    static let shared = SidebarRefreshCoordinator()

    private let captureQueue = DispatchQueue(
        label: "app.macexplorer.sidebar-snapshot",
        qos: .utility
    )
    private var gate = SidebarRefreshGate<SidebarContentSnapshot>()
    private var consumers: [WeakSidebarReference] = []
    private var pendingCapture: DispatchWorkItem?
    private var pendingCancellation: SidebarCaptureCancellation?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var appObserver: NSObjectProtocol?
    private var preferencesObserver: NSObjectProtocol?
    private var didStartBookmarkRefresh = false

    private init() {
        observeChanges()
    }

    func register(_ sidebar: SidebarViewController) -> SidebarContentSnapshot {
        precondition(Thread.isMainThread)
        consumers.removeAll { $0.value == nil || $0.value === sidebar }
        consumers.append(WeakSidebarReference(sidebar))

        let snapshot: SidebarContentSnapshot
        if let cached = gate.snapshot {
            snapshot = cached
        } else {
            // The first window needs content immediately. Later windows reuse
            // this model and do not repeat the filesystem discovery.
            snapshot = SidebarContentSnapshot.capture()
            gate.installInitial(snapshot)
        }

        if !didStartBookmarkRefresh {
            didStartBookmarkRefresh = true
            ExplorerPreferences.refreshPinnedFolderBookmarks()
        }
        return snapshot
    }

    func unregister(_ sidebar: SidebarViewController) {
        consumers.removeAll { $0.value == nil || $0.value === sidebar }
    }

    private func observeChanges() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let workspaceNotifications: [Notification.Name] = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification
        ]
        workspaceObservers = workspaceNotifications.map { name in
            workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.requestRefresh(after: 0.12)
            }
        }
        appObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Bookmark resolution is already asynchronous and only notifies
            // when a pin actually moved. The snapshot check also picks up
            // Finder favorites/tags changed while the app was inactive.
            ExplorerPreferences.refreshPinnedFolderBookmarks()
            self?.requestRefresh(after: 0.15)
        }
        preferencesObserver = NotificationCenter.default.addObserver(
            forName: .explorerSidebarPreferencesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Pinning can emit a direct preference notification followed by a
            // bookmark-resolution notification. Treat the pair as one update.
            self?.requestRefresh(after: 0.04)
        }
    }

    private func requestRefresh(after delay: TimeInterval) {
        precondition(Thread.isMainThread)
        pendingCapture?.cancel()
        pendingCancellation?.cancel()
        let requestGeneration = gate.beginRequest()
        let cancellation = SidebarCaptureCancellation()
        let work = DispatchWorkItem { [weak self, cancellation] in
            guard let self else { return }
            guard !cancellation.isCancelled else { return }
            let snapshot = SidebarContentSnapshot.capture()
            guard !cancellation.isCancelled else { return }
            DispatchQueue.main.async { [weak self] in
                self?.publish(snapshot, requestGeneration: requestGeneration)
            }
        }
        pendingCancellation = cancellation
        pendingCapture = work
        captureQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func publish(_ snapshot: SidebarContentSnapshot, requestGeneration: Int) {
        precondition(Thread.isMainThread)
        guard requestGeneration == gate.generation else { return }
        pendingCancellation = nil
        pendingCapture = nil
        guard gate.accept(snapshot, for: requestGeneration) else { return }
        consumers.removeAll { $0.value == nil }
        for consumer in consumers {
            consumer.value?.applySidebarSnapshot(snapshot)
        }
    }
}

private final class SidebarEjectButton: NSButton {
    var volumeURL: URL?
}

private final class SidebarCellView: NSTableCellView {
    let pinImageView = NSImageView()
    let ejectButton = SidebarEjectButton()
    var labelToEjectConstraint: NSLayoutConstraint?
    var labelToPinConstraint: NSLayoutConstraint?
    var labelToEdgeConstraint: NSLayoutConstraint?

    func setPinned(_ pinned: Bool, ejectable: Bool) {
        pinImageView.isHidden = !pinned || ejectable
        ejectButton.isHidden = !ejectable
        labelToEjectConstraint?.isActive = false
        if ejectable {
            labelToEdgeConstraint?.isActive = false
            labelToPinConstraint?.isActive = false
            labelToEjectConstraint?.isActive = true
        } else if pinned {
            labelToEdgeConstraint?.isActive = false
            labelToPinConstraint?.isActive = true
        } else {
            labelToPinConstraint?.isActive = false
            labelToEdgeConstraint?.isActive = true
        }
    }
}

final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    private static let pinnedFolderPasteboardType = NSPasteboard.PasteboardType("app.macexplorer.pinned-folder")
    private static let sidebarIconCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 128
        return cache
    }()

    weak var delegate: SidebarViewControllerDelegate?

    var hasKeyboardFocus: Bool { view.window?.firstResponder === outlineView }

    func focus() {
        view.window?.makeFirstResponder(outlineView)
    }

    private let outlineView = NSOutlineView()
    private let sidebarColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar"))
    private var roots: [SidebarNode] = []
    private var suppressSelectionCallback = false
    private var favoritesRootNode: SidebarNode?
    private var isRegisteredForSidebarRefresh = false
    private var ejectingVolumes = Set<URL>()

    override func loadView() {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor
        scrollView.borderType = .noBorder

        sidebarColumn.resizingMask = .autoresizingMask
        sidebarColumn.minWidth = 40
        outlineView.addTableColumn(sidebarColumn)
        outlineView.outlineTableColumn = sidebarColumn
        outlineView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outlineView.headerView = nil
        outlineView.rowSizeStyle = .medium
        outlineView.rowHeight = 31
        outlineView.indentationPerLevel = 13
        outlineView.style = .plain
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.selectionHighlightStyle = .regular
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.setAccessibilityLabel(L10n.text("Sidebar"))
        outlineView.registerForDraggedTypes([Self.pinnedFolderPasteboardType, .fileURL])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)
        let contextMenu = NSMenu()
        contextMenu.autoenablesItems = false
        contextMenu.delegate = self
        outlineView.menu = contextMenu
        scrollView.documentView = outlineView

        view = scrollView
        isRegisteredForSidebarRefresh = true
        let snapshot = SidebarRefreshCoordinator.shared.register(self)
        applySidebarSnapshot(snapshot)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let availableWidth = max(40, outlineView.enclosingScrollView?.contentView.bounds.width ?? view.bounds.width)
        if abs(sidebarColumn.width - availableWidth) > 0.5 {
            sidebarColumn.width = availableWidth
        }
    }

    func select(location: BrowserLocation) {
        select(location: location, scrollToVisible: true)
    }

    private func select(location: BrowserLocation, scrollToVisible: Bool) {
        let wasSuppressed = suppressSelectionCallback
        suppressSelectionCallback = true
        defer { suppressSelectionCallback = wasSuppressed }
        for row in 0..<outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: row) as? SidebarNode else { continue }
            if node.location == location {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                if scrollToVisible {
                    outlineView.scrollRowToVisible(row)
                }
                return
            }
        }
        outlineView.deselectAll(nil)
    }

    fileprivate func applySidebarSnapshot(_ snapshot: SidebarContentSnapshot) {
        precondition(Thread.isMainThread)
        let wasSuppressed = suppressSelectionCallback
        suppressSelectionCallback = true
        defer { suppressSelectionCallback = wasSuppressed }
        let previousLocation = (outlineView.item(atRow: outlineView.selectedRow) as? SidebarNode)?.location
        let previousExpansion = Dictionary(uniqueKeysWithValues: roots.filter(\.isGroup).map {
            ($0.title, outlineView.isItemExpanded($0))
        })
        let previousScrollOrigin = outlineView.enclosingScrollView?.contentView.bounds.origin

        var top: [SidebarNode] = [
            SidebarNode(title: L10n.text("Home"), symbolName: "house.fill", location: .home)
        ]
        if snapshot.showsRecents {
            top.append(SidebarNode(
                title: L10n.text("Recent"),
                symbolName: "clock.arrow.circlepath",
                location: .recents
            ))
        }
        if let picturesURL = snapshot.picturesURL {
            top.append(SidebarNode(
                title: L10n.text("Gallery"),
                symbolName: "photo.on.rectangle.angled",
                location: .folder(picturesURL)
            ))
        }

        func nodes(_ entries: [FinderSidebarEntry], pinned: Bool = false) -> [SidebarNode] {
            entries.map { entry in
                SidebarNode(
                    title: entry.title,
                    symbolName: entry.symbolName,
                    icon: sidebarIcon(for: entry.url),
                    location: .folder(entry.url),
                    isPinned: pinned,
                    canEject: entry.canEject
                )
            }
        }

        // Pins remain removable even while a network volume is offline. Their
        // labels and generic icon intentionally avoid probing the destination.
        let customPinnedNodes = snapshot.pinnedFolderURLs.map { url in
            SidebarNode(
                title: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
                icon: FileIconProvider.shared.folderIcon(),
                location: .folder(url),
                isPinned: true,
                isCustomPinned: true
            )
        }
        let customPaths = Set(customPinnedNodes.compactMap { $0.location?.folderURL?.standardizedFileURL.path })
        var favoriteNodes = customPinnedNodes + nodes(snapshot.favorites.filter {
            !customPaths.contains($0.url.standardizedFileURL.path)
        })
        if snapshot.showsTrash {
            favoriteNodes.append(SidebarNode(
                title: L10n.text("Trash"),
                symbolName: "trash",
                location: .folder(snapshot.trashURL)
            ))
        }

        let tagNodes = snapshot.favoriteTags.map { tag in
            SidebarNode(
                title: tag.name,
                icon: FinderTagPalette.menuImage(forColorAt: tag.colorIndex),
                location: .tag(tag)
            )
        }

        let favoritesRoot = SidebarNode(title: L10n.text("Favorites"), children: favoriteNodes, isGroup: true)
        favoritesRootNode = favoritesRoot
        roots = top + [
            favoritesRoot,
            SidebarNode(title: L10n.text("iCloud"), children: nodes(snapshot.iCloudLocations), isGroup: true),
            SidebarNode(
                title: L10n.text("Locations"),
                children: nodes(snapshot.locations) + [
                    SidebarNode(title: L10n.text("Network"), symbolName: "network", location: .network)
                ],
                isGroup: true
            ),
            SidebarNode(
                title: L10n.text("Tags"),
                children: tagNodes,
                isGroup: true,
                isInitiallyExpanded: false
            )
        ].filter { !$0.isGroup || !$0.children.isEmpty }
        outlineView.reloadData()
        for group in roots where group.isGroup {
            if previousExpansion[group.title] ?? group.isInitiallyExpanded {
                outlineView.expandItem(group)
            }
        }
        if let previousLocation {
            select(location: previousLocation, scrollToVisible: false)
        }
        if let previousScrollOrigin,
           let scrollView = outlineView.enclosingScrollView {
            scrollView.contentView.scroll(to: previousScrollOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    deinit {
        if isRegisteredForSidebarRefresh {
            SidebarRefreshCoordinator.shared.unregister(self)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let node = item as? SidebarNode { return node.children.count }
        return roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? SidebarNode { return node.children[index] }
        return roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? SidebarNode else { return false }
        return !node.children.isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? SidebarNode)?.isGroup == true
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? SidebarNode,
              node.isCustomPinned,
              let url = node.location?.folderURL else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(url.standardizedFileURL.path, forType: Self.pinnedFolderPasteboardType)
        return pasteboardItem
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard let parent = item as? SidebarNode, parent === favoritesRootNode else { return [] }
        let pasteboard = info.draggingPasteboard
        if pasteboard.string(forType: Self.pinnedFolderPasteboardType) != nil { return .move }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        return urls.isEmpty ? [] : .copy
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        guard let parent = item as? SidebarNode, parent === favoritesRootNode else { return false }
        let pinned = ExplorerPreferences.pinnedFolderURLs
        let proposedIndex = index < 0 ? pinned.count : min(index, pinned.count)
        let pasteboard = info.draggingPasteboard

        if let path = pasteboard.string(forType: Self.pinnedFolderPasteboardType) {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            guard let oldIndex = pinned.firstIndex(where: { $0.standardizedFileURL.path == url.standardizedFileURL.path }) else {
                return false
            }
            let finalIndex = oldIndex < proposedIndex ? proposedIndex - 1 : proposedIndex
            return ExplorerPreferences.movePinnedFolder(url, to: finalIndex)
        }

        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        let folders = urls.filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
        return ExplorerPreferences.pinFolders(folders, at: proposedIndex) > 0
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? SidebarNode)?.location != nil
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier(node.isGroup ? "group" : "location")
        let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? makeCell(identifier: identifier, group: node.isGroup)

        cell.textField?.stringValue = node.title
        cell.textField?.font = node.isGroup ? .systemFont(ofSize: 11, weight: .semibold) : .systemFont(ofSize: 13)
        cell.textField?.textColor = node.isGroup ? .secondaryLabelColor : .labelColor
        cell.imageView?.image = node.icon ?? node.symbolName.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: node.title)
        }
        cell.imageView?.contentTintColor = node.icon == nil
            ? (node.isGroup ? .secondaryLabelColor : .controlAccentColor)
            : nil
        if let cell = cell as? SidebarCellView {
            cell.setPinned(node.isPinned, ejectable: node.canEject)
            cell.ejectButton.volumeURL = node.canEject ? node.location?.folderURL : nil
            cell.ejectButton.isEnabled = cell.ejectButton.volumeURL.map { !ejectingVolumes.contains($0) } ?? false
            cell.ejectButton.toolTip = "\(L10n.text("Eject")) — \(node.title)"
            cell.ejectButton.setAccessibilityLabel(cell.ejectButton.toolTip)
        }
        return cell
    }

    private func sidebarIcon(for url: URL) -> NSImage {
        let key = url.standardizedFileURL.path as NSString
        if let cached = Self.sidebarIconCache.object(forKey: key) {
            return cached
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 18, height: 18)
        Self.sidebarIconCache.setObject(icon, forKey: key)
        return icon
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier, group: Bool) -> NSTableCellView {
        let cell = SidebarCellView()
        cell.identifier = identifier

        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyDown
        cell.imageView = imageView
        cell.addSubview(imageView)

        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        cell.textField = label
        cell.addSubview(label)

        let pin = cell.pinImageView
        pin.translatesAutoresizingMaskIntoConstraints = false
        pin.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)
        pin.contentTintColor = .tertiaryLabelColor
        pin.setAccessibilityElement(false)
        cell.addSubview(pin)

        let eject = cell.ejectButton
        eject.translatesAutoresizingMaskIntoConstraints = false
        eject.image = NSImage(systemSymbolName: "eject.fill", accessibilityDescription: L10n.text("Eject"))
        eject.isBordered = false
        eject.contentTintColor = .secondaryLabelColor
        eject.target = self
        eject.action = #selector(ejectVolumeButton(_:))
        cell.addSubview(eject)
        cell.labelToEjectConstraint = label.trailingAnchor.constraint(lessThanOrEqualTo: eject.leadingAnchor, constant: -5)

        let labelToPin = label.trailingAnchor.constraint(lessThanOrEqualTo: pin.leadingAnchor, constant: -5)
        let labelToEdge = label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6)
        cell.labelToPinConstraint = labelToPin
        cell.labelToEdgeConstraint = labelToEdge
        labelToEdge.isActive = true

        NSLayoutConstraint.activate([
            eject.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5),
            eject.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            eject.widthAnchor.constraint(equalToConstant: 24),
            eject.heightAnchor.constraint(equalToConstant: 24),
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: group ? 0 : 18),
            imageView.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: group ? 0 : 8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            pin.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            pin.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            pin.widthAnchor.constraint(equalToConstant: 11),
            pin.heightAnchor.constraint(equalToConstant: 11)
        ])
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionCallback else { return }
        let row = outlineView.selectedRow
        guard row >= 0,
              let node = outlineView.item(atRow: row) as? SidebarNode,
              let location = node.location else { return }
        delegate?.sidebar(self, didSelect: location)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outlineView.clickedRow
        guard row >= 0,
              let node = outlineView.item(atRow: row) as? SidebarNode,
              let url = node.location?.folderURL else { return }
        if node.canEject {
            let item = NSMenuItem(title: L10n.text("Eject"), action: #selector(ejectVolumeMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.image = NSImage(systemSymbolName: "eject", accessibilityDescription: nil)
            item.isEnabled = !ejectingVolumes.contains(url)
            menu.addItem(item)
        }
        guard node.isCustomPinned else { return }
        let item = NSMenuItem(
            title: L10n.text("Unpin from Quick access"),
            action: #selector(unpinFolder(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = url
        item.image = NSImage(systemSymbolName: "pin.slash", accessibilityDescription: nil)
        item.isEnabled = true
        menu.addItem(item)
    }

    @objc private func unpinFolder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        ExplorerPreferences.unpinFolder(url)
    }

    @objc private func ejectVolumeButton(_ sender: SidebarEjectButton) {
        guard let url = sender.volumeURL else { return }
        ejectVolume(url)
    }

    @objc private func ejectVolumeMenu(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        ejectVolume(url)
    }

    private func ejectVolume(_ url: URL) {
        guard url.isFileURL, url.standardizedFileURL.path != "/",
              ejectingVolumes.insert(url).inserted else { return }
        outlineView.reloadData()
        // The system may wait for open files. Never block AppKit or force eject.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let error: Error?
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                error = nil
            } catch let failure { error = failure }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.ejectingVolumes.remove(url)
                self.outlineView.reloadData()
                if let error {
                    let alert = NSAlert(error: error)
                    if let window = self.view.window { alert.beginSheetModal(for: window) }
                    else { alert.runModal() }
                }
                // didUnmountNotification refreshes the shared sidebar snapshot.
            }
        }
    }
}
