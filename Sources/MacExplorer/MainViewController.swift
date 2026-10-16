import AppKit
import QuickLookUI

private final class ExplorerRootView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

private enum ServerEditorMode {
    case connect
    case add
    case edit(originalAddress: String)
}

private final class DirectoryMetadataLoadToken {
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

final class CreatedItemsHistoryState {
    private struct StashedItem {
        let original: URL
        let stashed: URL
        let container: URL
    }

    private let originalURLs: [URL]
    private var stashedItems: [StashedItem] = []
    private let manager = FileManager.default

    init(urls: [URL]) {
        originalURLs = urls
    }

    func undo() throws {
        guard stashedItems.isEmpty else { return }
        var moved: [StashedItem] = []
        do {
            for original in originalURLs {
                guard manager.fileExists(atPath: original.path) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                // Keep the undo stash on the item's own volume. For a large
                // paste this stays an atomic rename instead of becoming a full
                // copy to the system temporary directory.
                let container = try manager.url(
                    for: .itemReplacementDirectory,
                    in: .userDomainMask,
                    appropriateFor: original,
                    create: true
                )
                let stashed = container.appendingPathComponent(
                    UUID().uuidString + "-" + original.lastPathComponent,
                    isDirectory: original.hasDirectoryPath
                )
                do {
                    try manager.moveItem(at: original, to: stashed)
                } catch {
                    try? manager.removeItem(at: container)
                    throw error
                }
                moved.append(StashedItem(original: original, stashed: stashed, container: container))
            }
            stashedItems = moved
        } catch {
            for item in moved.reversed() {
                try? manager.moveItem(at: item.stashed, to: item.original)
                try? manager.removeItem(at: item.container)
            }
            throw error
        }
    }

    func redo() throws {
        guard !stashedItems.isEmpty else { return }
        let items = stashedItems
        var restored: [StashedItem] = []
        do {
            for item in items {
                guard !manager.fileExists(atPath: item.original.path) else {
                    throw FileSystemServiceError.nameConflict
                }
                try manager.moveItem(at: item.stashed, to: item.original)
                restored.append(item)
            }
            stashedItems.removeAll(keepingCapacity: true)
            for item in items { try? manager.removeItem(at: item.container) }
        } catch {
            for item in restored.reversed() {
                try? manager.moveItem(at: item.original, to: item.stashed)
            }
            throw error
        }
    }

    deinit {
        for item in stashedItems { try? manager.removeItem(at: item.container) }
    }
}

private struct ExplorerFileUndoAction {
    let undo: () throws -> Void
    let redo: () throws -> Void
}

private struct BrowserHistoryEntry: Equatable {
    var location: BrowserLocation
    var query = ""
    var selectionURLs: [URL] = []
}

protocol MainViewControllerDelegate: AnyObject {
    func browser(_ browser: MainViewController, didChangeTitle title: String)
    func browserDidBecomeActive(_ browser: MainViewController)
}

final class MainViewController: NSViewController,
    SidebarViewControllerDelegate,
    FileListViewControllerDelegate,
    HomeViewControllerDelegate,
    NetworkViewControllerDelegate,
    BreadcrumbBarViewDelegate,
    NSSearchFieldDelegate,
    NSSplitViewDelegate,
    NSMenuItemValidation,
    NSServicesMenuRequestor,
    QLPreviewPanelDataSource,
    QLPreviewPanelDelegate {

    private static let operationPasteboardType = NSPasteboard.PasteboardType("app.macexplorer.file-operation")

    weak var browserDelegate: MainViewControllerDelegate?

    private let sidebarController = SidebarViewController()
    private let fileListController = FileListViewController()
    private let homeController = HomeViewController()
    private let networkController = NetworkViewController()
    private let detailsController = DetailsPaneViewController()
    private let fileSystem = FileSystemService.shared
    private let watcher = DirectoryWatcher()

    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let upButton = NSButton()
    private let refreshButton = NSButton()
    private let breadcrumbBar = BreadcrumbBarView()
    private let searchField = NSSearchField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let zoomSlider = NSSlider()
    private let zoomOutButton = NSButton()
    private let zoomInButton = NSButton()
    private let contentHost = NSView()
    private let contentSplit = NSSplitView()
    private let mainSplit = NSSplitView()
    private weak var statusBarView: NSView?

    private let newButton = NSButton()
    private let cutButton = NSButton()
    private let copyButton = NSButton()
    private let pasteButton = NSButton()
    private let renameButton = NSButton()
    private let shareButton = NSButton()
    private let trashButton = NSButton()
    private let sortButton = NSButton()
    private let viewButton = NSButton()
    private let filterButton = NSButton()
    private let moreButton = NSButton()
    private let splitButton = NSButton()
    private let diskUsageButton = NSButton()
    private let shelfButton = ShelfDropButton()
    private let detailsButton = NSButton()

    private(set) var currentLocation: BrowserLocation
    private var history: [BrowserHistoryEntry]
    private var historyIndex = 0
    private var showHiddenFiles = UserDefaults.standard.bool(forKey: "ExplorerShowHiddenFiles")
    private var detailsVisible = false
    private var forceSearchVisible = false
    private var searchWorkItem: DispatchWorkItem?
    private var searchLoadToken: DirectoryMetadataLoadToken?
    private var searchGeneration = 0
    private var isSearching = false
    private var directoryLoadGeneration = 0
    private var navigationLoadToken: DirectoryMetadataLoadToken?
    private var locationGeneration = 0
    private var directoryLoadInProgressPath: String?
    private var pendingDirectoryReload = false
    private var availableCapacityPath: String?
    private var availableCapacity: Int64?
    private var availableCapacityGeneration = 0
    private var selectionPresentationWorkItem: DispatchWorkItem?
    private let tagMetadataQueue = DispatchQueue(label: "app.macexplorer.tag-metadata", qos: .utility)
    private var tagMetadataLoadToken: DirectoryMetadataLoadToken?
    private var tagMetadataViewportToken: DirectoryMetadataLoadToken?
    private var tagMetadataLoadedPaths: Set<String> = []
    private var tagMetadataPendingPaths: Set<String> = []
    private var tagMetadataDesiredPaths: Set<String> = []
    private var tagQuery: NSMetadataQuery?
    private var tagQueryObservers: [NSObjectProtocol] = []
    private var sidebarWidthInitialized = false
    private var isNetworkViewMounted = false
    private var lastCutPasteboardChangeCount = -1
    private var fileUndoActions: [ExplorerFileUndoAction] = []
    private var fileRedoActions: [ExplorerFileUndoAction] = []
    private var isPerformingFileUndo = false
    private var isPerformingStandaloneMutation = false
    private var pendingDirectorySelection: (directory: URL, urls: [URL])?
    private var pendingNewFolderRename: URL?
    private var isBrowserPaneVisible = true
    private static let sidebarWidthKey = "ExplorerSidebarWidth"

    private let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private let desktopPresentation: Bool
    var desktopOpenHandler: ((URL) -> Void)?

    var currentURL: URL {
        currentLocation.folderURL ?? FileManager.default.homeDirectoryForCurrentUser
    }

    private var displaysFileItems: Bool {
        switch currentLocation {
        case .folder, .tag: return true
        case .home, .recents, .network: return false
        }
    }

    var locationTitle: String { currentLocation.title }

    var isShowingHiddenFiles: Bool { showHiddenFiles }
    var currentDateGroupingMode: FileDateGroupingMode { fileListController.dateGroupingMode }
    var canConfigureDateGrouping: Bool {
        currentLocation.folderURL != nil && fileListController.isReadyForFolderCommands
    }
    var isShowingFolderSizes: Bool { fileListController.showsFolderSizes }
    var canConfigureFolderSizes: Bool {
        currentLocation.folderURL != nil
            && fileListController.viewMode == .details
            && fileListController.isReadyForFolderCommands
    }
    var canConfigureFolderView: Bool {
        currentLocation.folderURL != nil && fileListController.isReadyForFolderCommands
    }
    var hasSavedViewForCurrentFolder: Bool {
        currentLocation.folderURL != nil && fileListController.hasSavedViewForCurrentFolder
    }
    var hasFileSelection: Bool { displaysFileItems && !fileListController.selectedItems.isEmpty }
    var canRenameSelection: Bool {
        hasFileSelection && !isPerformingFileUndo && !isPerformingStandaloneMutation
    }
    var canDuplicateSelection: Bool {
        canRenameSelection
            && currentLocation.folderURL != nil
            && searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var canCreateFolderFromSelection: Bool {
        guard canRenameSelection, let directory = currentLocation.folderURL?.standardizedFileURL else {
            return false
        }
        return fileListController.selectedItems.allSatisfy {
            $0.url.deletingLastPathComponent().standardizedFileURL == directory
        }
    }
    var canCreateItems: Bool {
        currentLocation.folderURL != nil
            && !isPerformingFileUndo
            && !isPerformingStandaloneMutation
    }
    var canPasteItems: Bool {
        canCreateItems && NSPasteboard.general.types?.contains(.fileURL) == true
    }
    var canNavigateBack: Bool { historyIndex > 0 }
    var canNavigateForward: Bool { historyIndex < history.count - 1 }
    var canNavigateUp: Bool { currentLocation.folderURL != nil && currentURL.path != "/" }

    var canTransferToOtherPane: Bool {
        otherBrowser?.currentLocation.folderURL != nil
    }

    func handleNavigationMouseDown(_ event: NSEvent) -> Bool {
        guard event.type == .leftMouseDown, event.window === view.window else { return false }
        for button in [backButton, forwardButton, upButton, refreshButton] where !button.isHidden {
            if button.bounds.contains(button.convert(event.locationInWindow, from: nil)) {
                NavigationClickDispatcher.enqueue(button)
                return true
            }
        }
        return breadcrumbBar.handleMouseDown(atWindowPoint: event.locationInWindow)
    }

    private var otherBrowser: MainViewController? {
        (view.window?.contentViewController as? ExplorerWindowViewController)?.otherBrowser(than: self)
    }

    init(initialURL: URL? = nil, desktopPresentation: Bool = false) {
        self.desktopPresentation = desktopPresentation
        if let initialURL {
            let location = BrowserLocation.folder(initialURL.standardizedFileURL)
            currentLocation = location
            history = [BrowserHistoryEntry(location: location)]
        } else {
            currentLocation = .home
            history = [BrowserHistoryEntry(location: .home)]
        }
        super.init(nibName: nil, bundle: nil)
    }

    init(initialLocation: BrowserLocation) {
        desktopPresentation = false
        currentLocation = initialLocation
        history = [BrowserHistoryEntry(location: initialLocation)]
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        searchLoadToken?.cancel()
        navigationLoadToken?.cancel()
        tagMetadataLoadToken?.cancel()
        tagMetadataViewportToken?.cancel()
        selectionPresentationWorkItem?.cancel()
        stopTagQuery()
    }

    override func loadView() {
        let rootView = ExplorerRootView()
        rootView.wantsLayer = true

        let rootStack = NSStackView()
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 0
        rootView.addSubview(rootStack)

        let navigationBar = makeNavigationBar()
        let commandBar = makeCommandBar()
        rootStack.addArrangedSubview(commandBar)
        rootStack.addArrangedSubview(navigationBar)
        commandBar.isHidden = desktopPresentation
        navigationBar.isHidden = desktopPresentation

        mainSplit.translatesAutoresizingMaskIntoConstraints = false
        mainSplit.isVertical = true
        mainSplit.dividerStyle = .thin
        mainSplit.delegate = self
        rootStack.addArrangedSubview(mainSplit)

        addChild(sidebarController)
        sidebarController.delegate = self
        sidebarController.view.translatesAutoresizingMaskIntoConstraints = false
        sidebarController.view.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        sidebarController.view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        mainSplit.addArrangedSubview(sidebarController.view)
        mainSplit.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        sidebarController.view.isHidden = desktopPresentation

        let browserPane = NSStackView()
        browserPane.translatesAutoresizingMaskIntoConstraints = false
        browserPane.orientation = .vertical
        browserPane.alignment = .leading
        browserPane.spacing = 0
        browserPane.setContentHuggingPriority(.defaultLow, for: .horizontal)
        browserPane.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        mainSplit.addArrangedSubview(browserPane)

        contentSplit.translatesAutoresizingMaskIntoConstraints = false
        contentSplit.isVertical = true
        contentSplit.dividerStyle = .thin
        contentSplit.autosaveName = "ExplorerContentSplitView"
        browserPane.addArrangedSubview(contentSplit)

        contentHost.translatesAutoresizingMaskIntoConstraints = false
        contentSplit.addArrangedSubview(contentHost)

        addChild(homeController)
        homeController.delegate = self
        homeController.view.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(homeController.view)

        fileListController.setDesktopAppearance(desktopPresentation)
        fileListController.onMetadataPrefetchRequested = { [weak self] items in
            self?.requestTagMetadata(for: items)
        }
        if desktopPresentation {
            fileListController.onBlankClick = {
                ExplorerDesktopManager.shared.toggleShowDesktop()
            }
        }
        addChild(fileListController)
        fileListController.delegate = self
        fileListController.view.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(fileListController.view)

        for contentView in [homeController.view, fileListController.view] {
            NSLayoutConstraint.activate([
                contentView.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
                contentView.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
                contentView.topAnchor.constraint(equalTo: contentHost.topAnchor),
                contentView.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor)
            ])
        }

        addChild(detailsController)
        detailsController.view.translatesAutoresizingMaskIntoConstraints = false
        detailsController.view.widthAnchor.constraint(equalToConstant: 245).isActive = true
        contentSplit.addArrangedSubview(detailsController.view)
        detailsController.view.isHidden = true

        let statusBar = makeStatusBar()
        statusBarView = statusBar
        browserPane.addArrangedSubview(statusBar)
        statusBar.isHidden = desktopPresentation

        for arrangedView in rootStack.arrangedSubviews {
            arrangedView.leadingAnchor.constraint(equalTo: rootStack.leadingAnchor).isActive = true
            arrangedView.trailingAnchor.constraint(equalTo: rootStack.trailingAnchor).isActive = true
        }
        for arrangedView in browserPane.arrangedSubviews {
            arrangedView.leadingAnchor.constraint(equalTo: browserPane.leadingAnchor).isActive = true
            arrangedView.trailingAnchor.constraint(equalTo: browserPane.trailingAnchor).isActive = true
        }
        mainSplit.setContentHuggingPriority(.defaultLow, for: .vertical)
        mainSplit.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        contentSplit.setContentHuggingPriority(.defaultLow, for: .vertical)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: rootView.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            commandBar.heightAnchor.constraint(equalToConstant: 40),
            navigationBar.heightAnchor.constraint(equalToConstant: 44),
            statusBar.heightAnchor.constraint(equalToConstant: 27)
        ])

        view = rootView
    }

    private func ensureNetworkViewMounted() {
        guard !isNetworkViewMounted else { return }
        addChild(networkController)
        networkController.delegate = self
        let networkView = networkController.view
        networkView.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(networkView)
        NSLayoutConstraint.activate([
            networkView.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            networkView.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            networkView.topAnchor.constraint(equalTo: contentHost.topAnchor),
            networkView.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor)
        ])
        networkView.isHidden = true
        isNetworkViewMounted = true
    }

    private func presentContentView(_ contentView: NSView) {
        homeController.view.isHidden = contentView !== homeController.view
        homeController.setContentVisible(isBrowserPaneVisible && contentView === homeController.view)
        fileListController.view.isHidden = contentView !== fileListController.view
        fileListController.setContentVisible(
            isBrowserPaneVisible && contentView === fileListController.view
        )
        if networkController.isViewLoaded {
            networkController.view.isHidden = contentView !== networkController.view
        }
        contentView.isHidden = false
        if contentView.superview === contentHost {
            contentHost.addSubview(contentView, positioned: .above, relativeTo: nil)
        }
    }

    /// Tabs keep their view controllers alive to preserve navigation state, but
    /// background work must follow what is actually mounted in a pane.
    func setBrowserPaneVisible(_ visible: Bool) {
        guard visible != isBrowserPaneVisible else { return }
        isBrowserPaneVisible = visible
        homeController.setContentVisible(visible && isViewLoaded && !homeController.view.isHidden)
        fileListController.setContentVisible(
            visible && isViewLoaded && !fileListController.view.isHidden
        )
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if desktopPresentation {
            fileListController.setZoomLevel(3)
        }
        loadCurrentLocation()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if desktopPresentation {
            view.window?.makeFirstResponder(view)
            return
        }
        initializeSidebarWidthIfNeeded()
        if displaysFileItems {
            fileListController.focus()
        } else {
            view.window?.makeFirstResponder(view)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !desktopPresentation else { return }
        let width = view.bounds.width
        forwardButton.isHidden = width < 250
        upButton.isHidden = width < 310
        refreshButton.isHidden = width < 370
        searchField.isHidden = width < 520 && !forceSearchVisible
        // Keep Details available in a narrow split pane; lower-priority controls
        // collapse first.
        detailsButton.isHidden = false
        diskUsageButton.isHidden = width < 820
        shelfButton.isHidden = width < 900
        splitButton.isHidden = width < 280
        viewButton.isHidden = width < 420
        newButton.isHidden = width < 230
        filterButton.isHidden = width < 760
        shareButton.isHidden = width < 860
        renameButton.isHidden = width < 720
        trashButton.isHidden = width < 680
        sortButton.isHidden = width < 620
        cutButton.isHidden = width < 390
        copyButton.isHidden = width < 350
        pasteButton.isHidden = width < 310
    }

    private func makeNavigationBar() -> NSView {
        let container = barContainer(color: .controlBackgroundColor)
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
        container.addSubview(stack)

        configureNavigationButton(backButton, symbol: "chevron.left", description: L10n.text("Back"), action: #selector(goBack(_:)))
        configureNavigationButton(forwardButton, symbol: "chevron.right", description: L10n.text("Forward"), action: #selector(goForward(_:)))
        configureNavigationButton(upButton, symbol: "arrow.up", description: L10n.text("Up"), action: #selector(goUp(_:)))
        configureNavigationButton(refreshButton, symbol: "arrow.clockwise", description: L10n.text("Refresh"), action: #selector(refresh(_:)))

        breadcrumbBar.translatesAutoresizingMaskIntoConstraints = false
        breadcrumbBar.delegate = self
        breadcrumbBar.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        breadcrumbBar.setContentHuggingPriority(.defaultLow, for: .horizontal)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = L10n.text("Search Home")
        searchField.delegate = self
        searchField.bezelStyle = .roundedBezel
        searchField.toolTip = L10n.text("Search by name or use filters such as ext:jpg, kind:image, tag:red, size:>100MB, and modified:week.")
        searchField.setContentCompressionResistancePriority(.required, for: .horizontal)
        searchField.setContentHuggingPriority(.required, for: .horizontal)

        stack.addArrangedSubview(backButton)
        stack.addArrangedSubview(forwardButton)
        stack.addArrangedSubview(upButton)
        stack.addArrangedSubview(refreshButton)
        stack.addArrangedSubview(breadcrumbBar)
        stack.addArrangedSubview(searchField)

        let proportionalSearchWidth = searchField.widthAnchor.constraint(equalTo: container.widthAnchor, multiplier: 0.22)
        proportionalSearchWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            breadcrumbBar.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            searchField.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
            proportionalSearchWidth,
            breadcrumbBar.heightAnchor.constraint(equalToConstant: 32),
            searchField.heightAnchor.constraint(equalToConstant: 30)
        ])
        return container
    }

    private func makeCommandBar() -> NSView {
        let container = barContainer(color: .controlBackgroundColor)
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 10, bottom: 3, right: 10)
        container.addSubview(stack)

        configureLabeledCommandButton(newButton, symbol: "plus.circle", title: L10n.text("New") + " ⌄", action: #selector(showNewMenu(_:)), minimumWidth: 70)
        configureIconCommandButton(cutButton, symbol: "scissors", title: L10n.text("Cut"), action: #selector(cut(_:)))
        configureIconCommandButton(copyButton, symbol: "doc.on.doc", title: L10n.text("Copy"), action: #selector(copy(_:)))
        configureIconCommandButton(pasteButton, symbol: "clipboard", title: L10n.text("Paste"), action: #selector(paste(_:)))
        configureIconCommandButton(renameButton, symbol: "character.cursor.ibeam", title: L10n.text("Rename"), action: #selector(rename(_:)))
        configureIconCommandButton(shareButton, symbol: "square.and.arrow.up", title: L10n.text("Share"), action: #selector(share(_:)))
        configureIconCommandButton(trashButton, symbol: "trash", title: L10n.text("Delete"), action: #selector(moveToTrash(_:)))
        configureLabeledCommandButton(sortButton, symbol: "arrow.up.arrow.down", title: L10n.text("Sort") + " ⌄", action: #selector(showSortMenu(_:)), minimumWidth: 68)
        configureLabeledCommandButton(viewButton, symbol: "list.bullet", title: L10n.text("View") + " ⌄", action: #selector(showViewMenu(_:)), minimumWidth: 70)
        configureIconCommandButton(splitButton, symbol: "rectangle.split.2x1", title: L10n.text("Split View"), action: #selector(toggleSplitView(_:)))
        configureIconCommandButton(diskUsageButton, symbol: "internaldrive", title: L10n.text("Storage Map"), action: #selector(showStorageMap(_:)))
        configureIconCommandButton(shelfButton, symbol: "tray.full", title: L10n.text("File Shelf"), action: #selector(showFileShelf(_:)))
        shelfButton.onURLsDropped = { urls in FileShelf.shared.add(urls) }
        configureLabeledCommandButton(filterButton, symbol: "line.3.horizontal.decrease", title: L10n.text("Filter") + " ⌄", action: #selector(showFilterMenu(_:)), minimumWidth: 74)
        configureIconCommandButton(moreButton, symbol: "ellipsis", title: L10n.text("More"), action: #selector(showMoreMenu(_:)))
        configureLabeledCommandButton(detailsButton, symbol: "sidebar.right", title: L10n.text("Details"), action: #selector(toggleDetailsPane(_:)), minimumWidth: 82)
        detailsButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        detailsButton.setContentHuggingPriority(.required, for: .horizontal)

        stack.addArrangedSubview(newButton)
        stack.addArrangedSubview(makeSeparator())
        stack.addArrangedSubview(cutButton)
        stack.addArrangedSubview(copyButton)
        stack.addArrangedSubview(pasteButton)
        stack.addArrangedSubview(renameButton)
        stack.addArrangedSubview(shareButton)
        stack.addArrangedSubview(trashButton)
        stack.addArrangedSubview(makeSeparator())
        stack.addArrangedSubview(sortButton)
        stack.addArrangedSubview(viewButton)
        stack.addArrangedSubview(splitButton)
        stack.addArrangedSubview(diskUsageButton)
        stack.addArrangedSubview(shelfButton)
        stack.addArrangedSubview(filterButton)
        stack.addArrangedSubview(moreButton)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(spacer)
        stack.addArrangedSubview(detailsButton)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    private func barContainer(color: NSColor) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = color.cgColor
        let line = NSBox()
        line.translatesAutoresizingMaskIntoConstraints = false
        line.boxType = .separator
        view.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        return view
    }

    private func makeStatusBar() -> NSView {
        let effect = NSVisualEffectView()
        effect.material = .contentBackground
        effect.blendingMode = .withinWindow
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        effect.addSubview(statusLabel)

        configureNavigationButton(zoomOutButton, symbol: "minus", description: L10n.text("Zoom Out"), action: #selector(zoomOut(_:)))
        configureNavigationButton(zoomInButton, symbol: "plus", description: L10n.text("Zoom In"), action: #selector(zoomIn(_:)))
        zoomOutButton.translatesAutoresizingMaskIntoConstraints = false
        zoomInButton.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(zoomOutButton)
        effect.addSubview(zoomInButton)

        zoomSlider.translatesAutoresizingMaskIntoConstraints = false
        zoomSlider.minValue = 0
        zoomSlider.maxValue = 5
        zoomSlider.numberOfTickMarks = 6
        zoomSlider.allowsTickMarkValuesOnly = true
        zoomSlider.isContinuous = true
        zoomSlider.doubleValue = Double(fileListController.zoomLevel)
        zoomSlider.target = self
        zoomSlider.action = #selector(changeZoomFromSlider(_:))
        zoomSlider.toolTip = L10n.text("Change view size")
        effect.addSubview(zoomSlider)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 11),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: zoomOutButton.leadingAnchor, constant: -10),
            statusLabel.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
            zoomOutButton.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
            zoomSlider.leadingAnchor.constraint(equalTo: zoomOutButton.trailingAnchor, constant: 2),
            zoomSlider.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
            zoomSlider.widthAnchor.constraint(equalToConstant: 105),
            zoomInButton.leadingAnchor.constraint(equalTo: zoomSlider.trailingAnchor, constant: 2),
            zoomInButton.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -8),
            zoomInButton.centerYAnchor.constraint(equalTo: effect.centerYAnchor)
        ])
        return effect
    }

    private func configureNavigationButton(_ button: NSButton, symbol: String, description: String, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        button.title = ""
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.target = self
        button.action = action
        button.toolTip = description
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
    }

    private func configureIconCommandButton(_ button: NSButton, symbol: String, title: String, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.title = ""
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.target = self
        button.action = action
        button.toolTip = title
        button.widthAnchor.constraint(equalToConstant: 34).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
    }

    private func configureLabeledCommandButton(_ button: NSButton, symbol: String, title: String, action: Selector, minimumWidth: CGFloat) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.title = title
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.font = .systemFont(ofSize: 12.5)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.target = self
        button.action = action
        button.toolTip = title.replacingOccurrences(of: " ⌄", with: "")
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: minimumWidth).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
    }

    private func makeSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.heightAnchor.constraint(equalToConstant: 25).isActive = true
        return separator
    }

    private func loadCurrentLocation(
        selectURL: URL? = nil,
        selectURLs: [URL] = [],
        preservingSelection: Bool = false,
        preparedItems: [FileItem]? = nil
    ) {
        cancelSearch()
        stopTagQuery()
        if currentLocation.folderURL == nil {
            directoryLoadGeneration += 1
            directoryLoadInProgressPath = nil
            pendingDirectoryReload = false
            tagMetadataLoadToken?.cancel()
            tagMetadataLoadToken = nil
            tagMetadataViewportToken?.cancel()
            tagMetadataViewportToken = nil
            tagMetadataLoadedPaths.removeAll(keepingCapacity: true)
            tagMetadataPendingPaths.removeAll(keepingCapacity: true)
            tagMetadataDesiredPaths.removeAll(keepingCapacity: true)
        }
        switch currentLocation {
        case .home:
            watcher.stop()
            homeController.setRecentOnly(false)
            presentContentView(homeController.view)
            breadcrumbBar.showHome()
            sidebarController.select(location: .home)
            searchField.placeholderString = L10n.text("Search Home")
            homeController.setFilter(searchField.stringValue)
        case .recents:
            watcher.stop()
            homeController.setRecentOnly(true)
            presentContentView(homeController.view)
            breadcrumbBar.showRecents()
            sidebarController.select(location: .recents)
            searchField.placeholderString = L10n.text("Search Recent")
            homeController.setFilter(searchField.stringValue)
        case .network:
            watcher.stop()
            ensureNetworkViewMounted()
            presentContentView(networkController.view)
            breadcrumbBar.showNetwork()
            sidebarController.select(location: .network)
            searchField.placeholderString = L10n.text("Search Network")
            networkController.setFilter(searchField.stringValue)
            networkController.reload()
        case let .tag(tag):
            watcher.stop()
            presentContentView(fileListController.view)
            breadcrumbBar.showTag(tag.name)
            sidebarController.select(location: .tag(tag))
            searchField.placeholderString = L10n.text("Search") + " " + tag.name
            fileListController.setFilter(searchField.stringValue)
            loadTag(
                tag,
                preservingSelection: preservingSelection,
                explicitSelection: selectURLs.isEmpty ? nil : Set(selectURLs)
            )
        case .folder:
            presentContentView(fileListController.view)
            loadDirectory(
                selectURL: selectURL,
                selectURLs: selectURLs,
                preservingSelection: preservingSelection,
                preparedItems: preparedItems
            )
        }
        browserDelegate?.browser(self, didChangeTitle: locationTitle)
        view.window?.title = locationTitle
        updateControls()
    }

    private func loadTag(
        _ tag: FinderTag,
        preservingSelection: Bool,
        explicitSelection: Set<URL>? = nil
    ) {
        let preserved = explicitSelection
            ?? (preservingSelection ? Set(fileListController.selectedItems.map(\.url)) : [])
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryLocalComputerScope]
        query.predicate = NSPredicate(format: "kMDItemUserTags ==[c] %@", tag.name)
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSNameKey, ascending: true)]
        tagQuery = query
        isSearching = true
        fileListController.showLoading(
            title: L10n.text("Searching") + "…",
            clearCurrentItems: true
        )

        let center = NotificationCenter.default
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, Notification.Name.NSMetadataQueryDidUpdate] {
            tagQueryObservers.append(center.addObserver(
                forName: name,
                object: query,
                queue: .main
            ) { [weak self, weak query] _ in
                guard let self, let query else { return }
                self.consumeTagResults(from: query, tag: tag, preservingSelection: preserved)
            })
        }

        if !query.start() {
            isSearching = false
            fileListController.display(
                items: [],
                in: FileManager.default.homeDirectoryForCurrentUser,
                preservingSelection: preserved,
                emptyTitle: L10n.text("No items have this tag.")
            )
        }
        updateControls()
    }

    private func consumeTagResults(
        from query: NSMetadataQuery,
        tag: FinderTag,
        preservingSelection: Set<URL>
    ) {
        guard tagQuery === query, currentLocation == .tag(tag) else { return }
        query.disableUpdates()
        var seen = Set<String>()
        let items = query.results.compactMap { result -> FileItem? in
            guard let metadata = result as? NSMetadataItem,
                  let path = metadata.value(forAttribute: NSMetadataItemPathKey) as? String,
                  seen.insert(path).inserted,
                  let item = fileSystem.item(for: URL(fileURLWithPath: path)),
                  showHiddenFiles || !item.isHidden else { return nil }
            return item
        }
        query.enableUpdates()
        fileListController.display(
            items: items,
            in: FileManager.default.homeDirectoryForCurrentUser,
            preservingSelection: preservingSelection,
            emptyTitle: L10n.text("No items have this tag.")
        )
        isSearching = query.isGathering
        updateControls()
    }

    private func stopTagQuery() {
        tagQuery?.stop()
        tagQuery = nil
        tagQueryObservers.forEach(NotificationCenter.default.removeObserver)
        tagQueryObservers.removeAll(keepingCapacity: true)
    }

    func navigate(to url: URL, addToHistory: Bool = true, selectURL: URL? = nil) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            present(message: L10n.text("Location not found"), detail: url.path)
            return
        }
        guard isDirectory.boolValue else {
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            NSWorkspace.shared.open(url)
            return
        }
        setLocation(.folder(url.standardizedFileURL), addToHistory: addToHistory, selectURL: selectURL)
    }

    private func showHome(addToHistory: Bool = true) {
        setLocation(.home, addToHistory: addToHistory)
    }

    private func setLocation(
        _ location: BrowserLocation,
        addToHistory: Bool,
        selectURL: URL? = nil,
        restoredQuery: String = "",
        restoredSelection: [URL] = [],
        restoredHistoryIndex: Int? = nil,
        preparedItems: [FileItem]? = nil
    ) {
        navigationLoadToken?.cancel()
        navigationLoadToken = nil
        // Keep both the visible page and its action targets on the old location
        // until enumeration succeeds. A newer navigation supersedes this request.
        if let directory = location.folderURL, preparedItems == nil,
           restoredQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let token = DirectoryMetadataLoadToken()
            navigationLoadToken = token
            let showHidden = showHiddenFiles
            let service = fileSystem
            breadcrumbBar.endEditing()
            // Acknowledge the requested destination without bouncing the
            // highlight back to the page retained during enumeration.
            sidebarController.select(location: location)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = Result {
                    try service.contents(of: directory, showHidden: showHidden,
                        shouldContinue: { !token.isCancelled })
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.navigationLoadToken === token,
                          !token.isCancelled else { return }
                    self.navigationLoadToken = nil
                    if showHidden != self.showHiddenFiles {
                        // The user can change visibility while the previous
                        // page remains interactive. Do not publish a stale list.
                        self.setLocation(location, addToHistory: addToHistory,
                            selectURL: selectURL, restoredQuery: restoredQuery,
                            restoredSelection: restoredSelection,
                            restoredHistoryIndex: restoredHistoryIndex)
                        return
                    }
                    switch result {
                    case .success(let items):
                        self.setLocation(location, addToHistory: addToHistory,
                            selectURL: selectURL, restoredQuery: restoredQuery,
                            restoredSelection: restoredSelection,
                            restoredHistoryIndex: restoredHistoryIndex, preparedItems: items)
                    case .failure(let error):
                        self.sidebarController.select(location: self.currentLocation)
                        self.present(error: error)
                    }
                }
            }
            return
        }
        if addToHistory { captureCurrentHistoryEntry() }
        if let restoredHistoryIndex { historyIndex = restoredHistoryIndex }
        breadcrumbBar.endEditing()
        cancelSearch()
        tagMetadataLoadToken?.cancel()
        tagMetadataLoadToken = nil
        tagMetadataViewportToken?.cancel()
        tagMetadataViewportToken = nil
        tagMetadataLoadedPaths.removeAll(keepingCapacity: true)
        tagMetadataPendingPaths.removeAll(keepingCapacity: true)
        tagMetadataDesiredPaths.removeAll(keepingCapacity: true)
        currentLocation = location
        locationGeneration += 1
        availableCapacityGeneration += 1
        availableCapacityPath = nil
        availableCapacity = nil
        directoryLoadInProgressPath = nil
        pendingDirectoryReload = false
        if let pendingDirectorySelection,
           location.folderURL?.standardizedFileURL != pendingDirectorySelection.directory.standardizedFileURL {
            self.pendingDirectorySelection = nil
            self.pendingNewFolderRename = nil
        }
        if addToHistory {
            if historyIndex < history.count - 1 {
                history.removeSubrange((historyIndex + 1)..<history.count)
            }
            if history.last?.location != location {
                history.append(BrowserHistoryEntry(location: location))
                historyIndex = history.count - 1
            }
        }
        searchField.stringValue = restoredQuery
        fileListController.setFilter("")
        homeController.setFilter("")
        loadCurrentLocation(
            selectURL: selectURL,
            selectURLs: restoredSelection,
            preservingSelection: false,
            preparedItems: preparedItems
        )
    }

    private func captureCurrentHistoryEntry() {
        guard history.indices.contains(historyIndex) else { return }
        history[historyIndex].location = currentLocation
        history[historyIndex].query = searchField.stringValue
        history[historyIndex].selectionURLs = displaysFileItems
            ? fileListController.selectedItems.map(\.url)
            : []
    }

    func selectRevealedFiles(_ urls: [URL]) {
        loadDirectory(selectURLs: urls)
    }

    private func loadDirectory(
        selectURL: URL? = nil,
        selectURLs: [URL] = [],
        preservingSelection: Bool = false,
        preparedItems: [FileItem]? = nil
    ) {
        guard case .folder = currentLocation else {
            if case let .tag(tag) = currentLocation {
                stopTagQuery()
                loadTag(tag, preservingSelection: preservingSelection)
            }
            return
        }
        let directory = currentURL.standardizedFileURL
        if availableCapacityPath != directory.path {
            refreshAvailableCapacity(for: directory)
        }
        let explicitSelection = selectURLs + (selectURL.map { [$0] } ?? [])
        if !explicitSelection.isEmpty {
            pendingDirectorySelection = (directory: directory, urls: explicitSelection)
        }
        let requestedSelection: [URL]
        if let pendingDirectorySelection,
           pendingDirectorySelection.directory.standardizedFileURL == directory {
            requestedSelection = pendingDirectorySelection.urls
        } else {
            requestedSelection = []
        }
        let activeQuery = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !activeQuery.isEmpty {
            beginRecursiveSearch(activeQuery)
            return
        }
        let preserved = requestedSelection.isEmpty && preservingSelection
            ? Set(fileListController.selectedItems.map(\.url))
            : []
        let showHidden = showHiddenFiles
        directoryLoadGeneration += 1
        let generation = directoryLoadGeneration
        directoryLoadInProgressPath = directory.path
        tagMetadataLoadToken?.cancel()
        tagMetadataViewportToken?.cancel()
        let metadataToken = DirectoryMetadataLoadToken()
        tagMetadataLoadToken = metadataToken
        tagMetadataViewportToken = nil
        tagMetadataLoadedPaths.removeAll(keepingCapacity: true)
        tagMetadataPendingPaths.removeAll(keepingCapacity: true)
        tagMetadataDesiredPaths.removeAll(keepingCapacity: true)

        // Navigation arrives here with its items already prepared. Initial loads
        // and refreshes still use the asynchronous enumeration below.
        breadcrumbBar.show(url: directory)
        sidebarController.select(location: .folder(directory))
        searchField.placeholderString = L10n.text("Search") + " " + locationTitle
        watcher.watch(directory) { [weak self] change in
            self?.directoryDidChange(directory, change: change)
        }
        if preparedItems == nil && (fileListController.directoryURL.standardizedFileURL != directory || fileListController.allItems.isEmpty) {
            fileListController.showLoading(
                title: L10n.text("Loading folder") + "…",
                clearCurrentItems: true
            )
        }
        updateControls()

        let complete: (Result<[FileItem], Error>) -> Void = { [weak self] result in
                guard let self,
                      generation == self.directoryLoadGeneration,
                      !self.isSearching,
                      self.searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      self.currentLocation.folderURL?.standardizedFileURL == directory else { return }
                self.directoryLoadInProgressPath = nil
                switch result {
                case .success(let items):
                    self.fileListController.display(items: items, in: directory, preservingSelection: preserved)
                    if !requestedSelection.isEmpty {
                        self.fileListController.select(urls: requestedSelection)
                        if let pending = self.pendingDirectorySelection,
                           pending.directory.standardizedFileURL == directory,
                           Set(pending.urls.map { $0.standardizedFileURL.path })
                               == Set(requestedSelection.map { $0.standardizedFileURL.path }) {
                            self.pendingDirectorySelection = nil
                        }
                    }
                    self.updateControls()
                    if let created = self.pendingNewFolderRename,
                       created.deletingLastPathComponent().standardizedFileURL == directory,
                       self.fileListController.selectedItems.contains(where: {
                           $0.url.standardizedFileURL.path == created.standardizedFileURL.path
                       }) {
                        self.pendingNewFolderRename = nil
                        self.fileListController.beginInlineRename()
                    }
                case .failure(let error):
                    self.fileListController.showFailure(
                        title: L10n.text("Unable to display this folder."),
                        detail: error.localizedDescription
                    )
                    self.present(error: error)
                }
                if self.pendingDirectoryReload {
                    self.pendingDirectoryReload = false
                    DispatchQueue.main.async { [weak self] in
                        guard let self,
                              !self.isSearching,
                              self.searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        self.loadDirectory(preservingSelection: true)
                    }
                }
        }
        if let preparedItems {
            complete(.success(preparedItems))
        } else {
            let service = fileSystem
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result {
                    try service.contents(of: directory, showHidden: showHidden,
                        shouldContinue: { !metadataToken.isCancelled })
                }
                DispatchQueue.main.async { complete(result) }
            }
        }
    }

    private func requestTagMetadata(for items: [FileItem]) {
        guard let directory = currentLocation.folderURL?.standardizedFileURL,
              fileListController.directoryURL.standardizedFileURL == directory,
              directoryLoadInProgressPath == nil,
              let metadataToken = tagMetadataLoadToken,
              !metadataToken.isCancelled else { return }

        let eligibleItems = items.filter(\.isOnLocalVolume)
        let desiredPaths = Set(eligibleItems.map { $0.url.standardizedFileURL.path })
        if desiredPaths == tagMetadataDesiredPaths, !tagMetadataPendingPaths.isEmpty { return }

        tagMetadataViewportToken?.cancel()
        tagMetadataPendingPaths.removeAll(keepingCapacity: true)
        tagMetadataDesiredPaths = desiredPaths

        let requestedItems = eligibleItems.filter {
            !tagMetadataLoadedPaths.contains($0.url.standardizedFileURL.path)
        }
        guard !requestedItems.isEmpty else { return }

        let viewportToken = DirectoryMetadataLoadToken()
        tagMetadataViewportToken = viewportToken
        tagMetadataPendingPaths = Set(requestedItems.map { $0.url.standardizedFileURL.path })

        let generation = directoryLoadGeneration
        tagMetadataQueue.async { [weak self, metadataToken, viewportToken] in
            guard let self else { return }
            var index = 0
            while index < requestedItems.count,
                  !metadataToken.isCancelled,
                  !viewportToken.isCancelled {
                let upperBound = min(requestedItems.count, index + 32)
                let batch = Array(requestedItems[index..<upperBound])
                guard let taggedItems = self.fileSystem.loadingTagMetadata(
                    for: batch,
                    shouldContinue: {
                        !metadataToken.isCancelled && !viewportToken.isCancelled
                    }
                ) else { return }
                DispatchQueue.main.async { [weak self, metadataToken, viewportToken] in
                    guard let self,
                          !metadataToken.isCancelled,
                          !viewportToken.isCancelled,
                          self.tagMetadataLoadToken === metadataToken,
                          self.tagMetadataViewportToken === viewportToken,
                          generation == self.directoryLoadGeneration,
                          self.currentLocation.folderURL?.standardizedFileURL == directory else { return }
                    let paths = taggedItems.map { $0.url.standardizedFileURL.path }
                    self.tagMetadataPendingPaths.subtract(paths)
                    self.tagMetadataLoadedPaths.formUnion(paths)
                    self.fileListController.updateTagMetadata(items: taggedItems, in: directory)
                }
                index = upperBound
            }
        }
    }

    private func directoryDidChange(_ directory: URL, change: DirectoryWatcherChange) {
        let path = directory.standardizedFileURL.path
        guard currentLocation.folderURL?.standardizedFileURL.path == path else { return }
        if change == .invalidated {
            let parent = directory.deletingLastPathComponent()
            if parent.path != path {
                let replacement = BrowserLocation.folder(parent)
                if history.indices.contains(historyIndex) {
                    history[historyIndex].location = replacement
                    history[historyIndex].query = ""
                    history[historyIndex].selectionURLs = []
                }
                setLocation(replacement, addToHistory: false)
            }
            return
        }
        if directoryLoadInProgressPath == path {
            pendingDirectoryReload = true
            return
        }
        pendingDirectoryReload = false
        loadDirectory(preservingSelection: true)
    }

    private func refreshAvailableCapacity(for directory: URL) {
        let directory = directory.standardizedFileURL
        let path = directory.path
        availableCapacityGeneration += 1
        let generation = availableCapacityGeneration
        availableCapacityPath = path
        availableCapacity = nil
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let value = (try? directory.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            ))?.volumeAvailableCapacityForImportantUsage
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      generation == self.availableCapacityGeneration,
                      self.currentLocation.folderURL?.standardizedFileURL.path == path else { return }
                self.availableCapacity = value
                self.updateControls()
            }
        }
    }

    private func updateControls() {
        synchronizeCutAppearance()
        let folder = currentLocation.folderURL != nil
        let selectionCount = displaysFileItems ? fileListController.selectedItems.count : 0
        let itemCount: Int
        switch currentLocation {
        case .home: itemCount = 6
        case .recents: itemCount = homeController.visibleRecentCount
        case .network: itemCount = networkController.visibleItemCount
        case .tag: itemCount = fileListController.visibleItems.count
        case .folder: itemCount = fileListController.visibleItems.count
        }
        if selectionCount > 0 {
            statusLabel.stringValue = String(format: L10n.text("%d of %d selected"), selectionCount, itemCount)
            let selectedBytes = fileListController.selectedItems.compactMap(\.byteCount).reduce(0, +)
            if selectedBytes > 0 {
                statusLabel.stringValue += " · " + byteFormatter.string(fromByteCount: selectedBytes)
            }
        } else {
            statusLabel.stringValue = itemCount == 1
                ? L10n.text("1 item")
                : String(format: L10n.text("%d items"), itemCount)
            if availableCapacityPath == currentLocation.folderURL?.standardizedFileURL.path,
               let available = availableCapacity {
                statusLabel.stringValue += " · " + byteFormatter.string(fromByteCount: available) + " " + L10n.text("available")
            }
        }
        if isSearching {
            statusLabel.stringValue += " · " + L10n.text("Searching") + "…"
        } else if directoryLoadInProgressPath != nil {
            statusLabel.stringValue += " · " + L10n.text("Loading") + "…"
        }

        backButton.isEnabled = historyIndex > 0
        forwardButton.isEnabled = historyIndex < history.count - 1
        upButton.isEnabled = folder && currentURL.path != "/"
        updateNavigationButtonAppearance(backButton)
        updateNavigationButtonAppearance(forwardButton)
        updateNavigationButtonAppearance(upButton)
        cutButton.isEnabled = selectionCount > 0 && canRenameSelection
        copyButton.isEnabled = selectionCount > 0
        renameButton.isEnabled = selectionCount > 0 && canRenameSelection
        renameButton.toolTip = L10n.text(selectionCount > 1 ? "Rename Items" : "Rename")
        shareButton.isEnabled = selectionCount > 0
        trashButton.isEnabled = selectionCount > 0 && canRenameSelection
        sortButton.isEnabled = displaysFileItems && fileListController.isReadyForFolderCommands
        filterButton.isEnabled = displaysFileItems && fileListController.isReadyForFolderCommands
        newButton.isEnabled = canCreateItems
        pasteButton.isEnabled = canPasteItems
        let splitVisible = (view.window?.contentViewController as? ExplorerWindowViewController)?.isCurrentTabSplit ?? false
        splitButton.contentTintColor = splitVisible ? .controlAccentColor : .labelColor
        splitButton.toolTip = L10n.text(splitVisible ? "Close Split View" : "Split View")
        diskUsageButton.isEnabled = currentLocation != .network && !isTagLocation
        shelfButton.refreshShelfCount()
        detailsButton.contentTintColor = detailsVisible ? .controlAccentColor : .labelColor
        let viewSymbol = fileListController.viewMode == .details ? "list.bullet" : "square.grid.2x2"
        viewButton.image = NSImage(systemSymbolName: viewSymbol, accessibilityDescription: nil)
        zoomSlider.doubleValue = Double(fileListController.zoomLevel)
    }

    private func synchronizeCutAppearance() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastCutPasteboardChangeCount else { return }
        lastCutPasteboardChangeCount = pasteboard.changeCount
        guard pasteboard.string(forType: Self.operationPasteboardType) == "move" else {
            fileListController.setCutItems([])
            return
        }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        fileListController.setCutItems(urls)
    }

    private var isTagLocation: Bool {
        if case .tag = currentLocation { return true }
        return false
    }

    private func updateNavigationButtonAppearance(_ button: NSButton) {
        button.contentTintColor = button.isEnabled ? .labelColor : .tertiaryLabelColor
        button.alphaValue = button.isEnabled ? 1 : 0.48
    }

    private func runFileOperation(_ operation: () throws -> Void) {
        do {
            try operation()
            if case .folder = currentLocation { loadDirectory(preservingSelection: true) }
        } catch {
            present(error: error)
        }
    }

    var canUndoFileOperation: Bool {
        !fileUndoActions.isEmpty && !isPerformingFileUndo && !isPerformingStandaloneMutation
    }
    var canRedoFileOperation: Bool {
        !fileRedoActions.isEmpty && !isPerformingFileUndo && !isPerformingStandaloneMutation
    }

    private func registerFileUndo(
        undo: @escaping () throws -> Void,
        redo: @escaping () throws -> Void
    ) {
        fileUndoActions.append(ExplorerFileUndoAction(undo: undo, redo: redo))
        if fileUndoActions.count > 50 { fileUndoActions.removeFirst(fileUndoActions.count - 50) }
        fileRedoActions.removeAll()
    }

    private func registerCreatedItemsUndo(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let state = CreatedItemsHistoryState(urls: urls)
        registerFileUndo(undo: { try state.undo() }, redo: { try state.redo() })
    }

    private func registerMovesUndo(_ moves: [(current: URL, original: URL)]) {
        guard !moves.isEmpty else { return }
        let relocatePins: (Bool) -> Void = { reverse in
            let work = {
                for move in moves {
                    ExplorerPreferences.relocatePinnedFolder(
                        from: reverse ? move.current : move.original,
                        to: reverse ? move.original : move.current
                    )
                }
            }
            if Thread.isMainThread { work() }
            else { DispatchQueue.main.sync(execute: work) }
        }
        relocatePins(false)
        registerFileUndo(
            undo: { [fileSystem] in
                try fileSystem.undoMoves(moves)
                relocatePins(true)
            },
            redo: { [fileSystem] in
                try fileSystem.undoMoves(moves.map { (current: $0.original, original: $0.current) })
                relocatePins(false)
            }
        )
    }

    private func registerNewFolderWithSelectionUndo(
        _ transaction: NewFolderWithSelectionTransaction,
        result: NewFolderWithSelectionTransaction.Result
    ) {
        let relocatePins: (Bool) -> Void = { reverse in
            let work = {
                for move in result.moves {
                    ExplorerPreferences.relocatePinnedFolder(
                        from: reverse ? move.current : move.original,
                        to: reverse ? move.original : move.current
                    )
                }
            }
            if Thread.isMainThread { work() }
            else { DispatchQueue.main.sync(execute: work) }
        }
        relocatePins(false)
        registerFileUndo(
            undo: {
                try transaction.undo()
                relocatePins(true)
            },
            redo: {
                try transaction.redo()
                relocatePins(false)
            }
        )
    }

    @objc func undoLastFileOperation(_ sender: Any?) {
        guard canUndoFileOperation, let action = fileUndoActions.popLast() else {
            NSSound.beep()
            return
        }
        isPerformingFileUndo = true
        watcher.stop()
        updateControls()
        FileOperationManager.shared.performSerializedMutation(action.undo) { [weak self] result in
            guard let self else { return }
            self.isPerformingFileUndo = false
            switch result {
            case .success:
                self.fileRedoActions.append(action)
                if self.fileRedoActions.count > 50 {
                    self.fileRedoActions.removeFirst(self.fileRedoActions.count - 50)
                }
                self.loadDirectory(preservingSelection: false)
            case .failure(let error):
                self.fileUndoActions.append(action)
                self.loadDirectory(preservingSelection: true)
                self.present(error: error)
            }
        }
    }

    @objc func redoLastFileOperation(_ sender: Any?) {
        guard canRedoFileOperation, let action = fileRedoActions.popLast() else {
            NSSound.beep()
            return
        }
        isPerformingFileUndo = true
        watcher.stop()
        updateControls()
        FileOperationManager.shared.performSerializedMutation(action.redo) { [weak self] result in
            guard let self else { return }
            self.isPerformingFileUndo = false
            switch result {
            case .success:
                self.fileUndoActions.append(action)
                if self.fileUndoActions.count > 50 {
                    self.fileUndoActions.removeFirst(self.fileUndoActions.count - 50)
                }
                self.loadDirectory(preservingSelection: false)
            case .failure(let error):
                self.fileRedoActions.append(action)
                self.loadDirectory(preservingSelection: true)
                self.present(error: error)
            }
        }
    }

    private func present(error: Error) {
        let nsError = error as NSError
        let permissionDenied = (nsError.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(nsError.code))
            || (nsError.domain == NSPOSIXErrorDomain && [EACCES, EPERM].contains(Int32(nsError.code)))
        if permissionDenied {
            let alert = NSAlert()
            alert.messageText = L10n.text("Permission required")
            alert.informativeText = L10n.text("Choose this folder or a parent folder once so Mac Explorer can remember your approval.")
            alert.alertStyle = .warning
            alert.addButton(withTitle: L10n.text("Choose Folder"))
            alert.addButton(withTitle: L10n.text("Files & Folders Settings"))
            alert.addButton(withTitle: L10n.text("Cancel"))
            let completion: (NSApplication.ModalResponse) -> Void = { response in
                if response == .alertFirstButtonReturn {
                    FolderAccessManager.shared.requestAccess(from: self.view.window) { granted in
                        if granted { self.refresh(nil) }
                    }
                } else if response == .alertSecondButtonReturn {
                    Self.openFilesAndFoldersSettings()
                }
            }
            if let window = view.window {
                alert.beginSheetModal(for: window, completionHandler: completion)
            } else {
                completion(alert.runModal())
            }
            return
        }
        let alert = NSAlert(error: error)
        if let window = view.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    private func presentPartialTransferError(_ error: Error, completedCount: Int) {
        let nsError = error as NSError
        let permissionDenied = (nsError.domain == NSCocoaErrorDomain
            && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(nsError.code))
            || (nsError.domain == NSPOSIXErrorDomain && [EACCES, EPERM].contains(Int32(nsError.code)))
        guard !permissionDenied else {
            present(error: error)
            return
        }
        present(
            message: error.localizedDescription,
            detail: String(
                format: L10n.text("%d items were completed before the operation stopped."),
                completedCount
            )
        )
    }

    private static func openFilesAndFoldersSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_FilesAndFolders"
        ]
        for value in candidates {
            if let url = URL(string: value), NSWorkspace.shared.open(url) { return }
        }
    }

    private func present(message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        if let window = view.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    private func show(menu: NSMenu, from button: NSButton) {
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY - 3), in: button)
    }

    @objc private func showNewMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: L10n.text("Folder"), action: #selector(newFolder(_:)), keyEquivalent: "")
        menu.addItem(withTitle: L10n.text("Text document"), action: #selector(newEmptyFile(_:)), keyEquivalent: "")
        menu.items.forEach { $0.target = self }
        show(menu: menu, from: sender)
    }

    @objc private func showSortMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let profile = fileListController.currentFolderViewProfile
        [(L10n.text("Name"), FileSortKey.name),
         (L10n.text("Date modified"), FileSortKey.modifiedAt),
         (L10n.text("Type"), FileSortKey.kind),
         (L10n.text("Size"), FileSortKey.size)].forEach { title, key in
            let item = NSMenuItem(title: title, action: #selector(selectSortKey(_:)), keyEquivalent: "")
            item.tag = key.rawValue
            item.target = self
            item.state = profile.sortKey == key ? .on : .off
            item.isEnabled = fileListController.isReadyForFolderCommands
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let ascending = NSMenuItem(title: L10n.text("Ascending"), action: #selector(selectSortDirection(_:)), keyEquivalent: "")
        ascending.tag = 1
        ascending.target = self
        ascending.state = profile.sortAscending ? .on : .off
        ascending.isEnabled = fileListController.isReadyForFolderCommands
        menu.addItem(ascending)
        let descending = NSMenuItem(title: L10n.text("Descending"), action: #selector(selectSortDirection(_:)), keyEquivalent: "")
        descending.tag = 0
        descending.target = self
        descending.state = profile.sortAscending ? .off : .on
        descending.isEnabled = fileListController.isReadyForFolderCommands
        menu.addItem(descending)
        show(menu: menu, from: sender)
    }

    @objc private func showViewMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let details = NSMenuItem(title: L10n.text("Details"), action: #selector(showDetailsView(_:)), keyEquivalent: "")
        details.image = NSImage(systemSymbolName: "list.bullet.rectangle", accessibilityDescription: nil)
        details.target = self
        details.state = fileListController.viewMode == .details ? .on : .off
        details.isEnabled = fileListController.isReadyForFolderCommands
        menu.addItem(details)
        let icons = NSMenuItem(title: L10n.text("Large icons"), action: #selector(showIconView(_:)), keyEquivalent: "")
        icons.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
        icons.target = self
        icons.state = fileListController.viewMode == .icons ? .on : .off
        icons.isEnabled = fileListController.isReadyForFolderCommands
        menu.addItem(icons)
        menu.addItem(.separator())
        let compact = NSMenuItem(title: L10n.text("Compact view"), action: #selector(toggleCompactView(_:)), keyEquivalent: "")
        compact.target = self
        compact.state = fileListController.currentFolderViewProfile.compactSpacing ? .on : .off
        compact.isEnabled = fileListController.isReadyForFolderCommands
        menu.addItem(compact)
        let extensions = NSMenuItem(title: L10n.text("File name extensions"), action: #selector(toggleFileExtensions(_:)), keyEquivalent: "")
        extensions.state = fileListController.showsFileExtensions ? .on : .off
        extensions.target = self
        menu.addItem(extensions)
        let hidden = NSMenuItem(title: L10n.text("Show hidden files"), action: #selector(toggleHiddenFiles(_:)), keyEquivalent: "")
        hidden.state = showHiddenFiles ? .on : .off
        hidden.target = self
        menu.addItem(hidden)
        let folderSizes = NSMenuItem(title: L10n.text("Show folder sizes"), action: #selector(toggleFolderSizes(_:)), keyEquivalent: "")
        folderSizes.state = fileListController.showsFolderSizes ? .on : .off
        folderSizes.isEnabled = canConfigureFolderSizes
        folderSizes.target = self
        menu.addItem(folderSizes)
        menu.addItem(.separator())
        let dateGroupingMenu = NSMenu(title: L10n.text("Date groups"))
        dateGroupingMenu.autoenablesItems = false
        [(L10n.text("Automatic"), FileDateGroupingMode.automatic),
         (L10n.text("On"), FileDateGroupingMode.enabled),
         (L10n.text("Off"), FileDateGroupingMode.disabled)].forEach { title, mode in
            let item = NSMenuItem(title: title, action: #selector(setDateGroupingMode(_:)), keyEquivalent: "")
            item.target = self
            item.tag = mode.rawValue
            item.state = fileListController.dateGroupingMode == mode ? .on : .off
            item.isEnabled = currentLocation.folderURL != nil
            dateGroupingMenu.addItem(item)
        }
        let dateGroupingItem = NSMenuItem(title: L10n.text("Date groups"), action: nil, keyEquivalent: "")
        dateGroupingItem.submenu = dateGroupingMenu
        dateGroupingItem.isEnabled = currentLocation.folderURL != nil
        menu.addItem(dateGroupingItem)
        menu.addItem(.separator())
        let saveView = NSMenuItem(
            title: L10n.text("Save View for This Folder"),
            action: #selector(saveViewForThisFolder(_:)),
            keyEquivalent: ""
        )
        saveView.target = self
        saveView.isEnabled = canConfigureFolderView
        menu.addItem(saveView)
        let applySubfolders = NSMenuItem(
            title: L10n.text("Apply View to Subfolders"),
            action: #selector(applyViewToSubfolders(_:)),
            keyEquivalent: ""
        )
        applySubfolders.target = self
        applySubfolders.isEnabled = canConfigureFolderView
        menu.addItem(applySubfolders)
        let resetView = NSMenuItem(
            title: L10n.text("Reset Folder View"),
            action: #selector(resetFolderView(_:)),
            keyEquivalent: ""
        )
        resetView.target = self
        resetView.isEnabled = hasSavedViewForCurrentFolder
        menu.addItem(resetView)
        show(menu: menu, from: sender)
    }

    @objc private func showFilterMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        [(L10n.text("All items"), FileFilterKind.all),
         (L10n.text("Folders"), FileFilterKind.folders),
         (L10n.text("Images"), FileFilterKind.images),
         (L10n.text("Documents"), FileFilterKind.documents)].forEach { title, filter in
            let item = NSMenuItem(title: title, action: #selector(selectFilter(_:)), keyEquivalent: "")
            item.tag = filter.rawValue
            item.target = self
            item.state = fileListController.currentKindFilter == filter ? .on : .off
            item.isEnabled = fileListController.isReadyForFolderCommands
            menu.addItem(item)
        }
        show(menu: menu, from: sender)
    }

    @objc private func showMoreMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let selectedItems = displaysFileItems ? fileListController.selectedItems : []
        appendHiddenToolbarItems(to: menu)
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let duplicate = NSMenuItem(title: L10n.text("Duplicate"), action: #selector(self.duplicate(_:)), keyEquivalent: "")
        duplicate.target = self
        menu.addItem(duplicate)
        let finder = NSMenuItem(title: L10n.text("Reveal in Finder"), action: #selector(showInFinder(_:)), keyEquivalent: "")
        finder.target = self
        menu.addItem(finder)
        let addToShelf = NSMenuItem(title: L10n.text("Add to File Shelf"), action: #selector(addSelectionToShelf(_:)), keyEquivalent: "")
        addToShelf.image = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: nil)
        addToShelf.target = self
        addToShelf.isEnabled = !selectedItems.isEmpty
        menu.addItem(addToShelf)
        let viewContents = NSMenuItem(title: L10n.text("View Contents"), action: #selector(viewContents(_:)), keyEquivalent: "")
        viewContents.image = NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: nil)
        viewContents.target = self
        viewContents.isEnabled = selectedItems.count == 1 && selectedItems[0].isDirectory == false
        menu.addItem(viewContents)
        let createLink = NSMenuItem(title: L10n.text("Create Link") + "…", action: #selector(createLink(_:)), keyEquivalent: "")
        createLink.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
        createLink.target = self
        createLink.isEnabled = selectedItems.count == 1
        menu.addItem(createLink)
        menu.addItem(.separator())
        let splitVisible = (view.window?.contentViewController as? ExplorerWindowViewController)?.isCurrentTabSplit ?? false
        let split = NSMenuItem(
            title: L10n.text(splitVisible ? "Close Split View" : "Split View"),
            action: #selector(toggleSplitView(_:)),
            keyEquivalent: ""
        )
        split.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: nil)
        split.target = self
        menu.addItem(split)
        if canTransferToOtherPane {
            let compare = NSMenuItem(title: L10n.text("Compare Panes"), action: #selector(comparePanes(_:)), keyEquivalent: "")
            compare.image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: nil)
            compare.target = self
            menu.addItem(compare)
        }
        menu.addItem(.separator())
        let hidden = NSMenuItem(title: L10n.text("Show hidden files"), action: #selector(toggleHiddenFiles(_:)), keyEquivalent: "")
        hidden.state = showHiddenFiles ? .on : .off
        hidden.target = self
        menu.addItem(hidden)
        let searchHelp = NSMenuItem(title: L10n.text("Search Syntax"), action: #selector(showSearchSyntaxHelp(_:)), keyEquivalent: "")
        searchHelp.image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)
        searchHelp.target = self
        menu.addItem(searchHelp)
        if currentLocation.folderURL != nil {
            let duplicates = NSMenuItem(title: L10n.text("Find Duplicate Files"), action: #selector(findDuplicateFiles(_:)), keyEquivalent: "")
            duplicates.image = NSImage(systemSymbolName: "doc.on.doc.fill", accessibilityDescription: nil)
            duplicates.target = self
            menu.addItem(duplicates)
        }
        menu.addItem(.separator())
        let selectionMenu = NSMenu(title: L10n.text("Select"))
        let quickSelect = NSMenuItem(title: L10n.text("Quick Select") + "…", action: #selector(quickSelect(_:)), keyEquivalent: "")
        quickSelect.target = self
        selectionMenu.addItem(quickSelect)
        let invert = NSMenuItem(title: L10n.text("Invert Selection"), action: #selector(invertSelection(_:)), keyEquivalent: "")
        invert.target = self
        selectionMenu.addItem(invert)
        let sameExtension = NSMenuItem(title: L10n.text("Select Same Extension"), action: #selector(selectSameExtension(_:)), keyEquivalent: "")
        sameExtension.target = self
        selectionMenu.addItem(sameExtension)
        let selectionItem = NSMenuItem(title: L10n.text("Select"), action: nil, keyEquivalent: "")
        selectionItem.submenu = selectionMenu
        menu.addItem(selectionItem)
        show(menu: menu, from: sender)
    }

    private func appendHiddenToolbarItems(to menu: NSMenu) {
        struct OverflowAction {
            let button: NSButton
            let title: String
            let symbol: String
            let action: Selector
        }
        let actions = [
            OverflowAction(button: newButton, title: L10n.text("New"), symbol: "plus.circle", action: #selector(showOverflowNewMenu(_:))),
            OverflowAction(button: cutButton, title: L10n.text("Cut"), symbol: "scissors", action: #selector(cut(_:))),
            OverflowAction(button: copyButton, title: L10n.text("Copy"), symbol: "doc.on.doc", action: #selector(copy(_:))),
            OverflowAction(button: pasteButton, title: L10n.text("Paste"), symbol: "clipboard", action: #selector(paste(_:))),
            OverflowAction(button: renameButton, title: L10n.text("Rename"), symbol: "character.cursor.ibeam", action: #selector(rename(_:))),
            OverflowAction(button: shareButton, title: L10n.text("Share"), symbol: "square.and.arrow.up", action: #selector(share(_:))),
            OverflowAction(button: trashButton, title: L10n.text("Delete"), symbol: "trash", action: #selector(moveToTrash(_:))),
            OverflowAction(button: sortButton, title: L10n.text("Sort"), symbol: "arrow.up.arrow.down", action: #selector(showOverflowSortMenu(_:))),
            OverflowAction(button: viewButton, title: L10n.text("View"), symbol: "list.bullet", action: #selector(showOverflowViewMenu(_:))),
            OverflowAction(button: diskUsageButton, title: L10n.text("Storage Map"), symbol: "internaldrive", action: #selector(showStorageMap(_:))),
            OverflowAction(button: shelfButton, title: L10n.text("File Shelf"), symbol: "tray.full", action: #selector(showFileShelf(_:))),
            OverflowAction(button: filterButton, title: L10n.text("Filter"), symbol: "line.3.horizontal.decrease", action: #selector(showOverflowFilterMenu(_:))),
            OverflowAction(button: detailsButton, title: L10n.text("Details"), symbol: "sidebar.right", action: #selector(toggleDetailsPane(_:)))
        ]
        for action in actions where action.button.isHidden {
            let item = NSMenuItem(title: action.title, action: action.action, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: action.title)
            item.target = self
            item.isEnabled = action.button.isEnabled
            menu.addItem(item)
        }
    }

    @objc private func showOverflowNewMenu(_ sender: Any?) { showNewMenu(moreButton) }
    @objc private func showOverflowSortMenu(_ sender: Any?) { showSortMenu(sortButton.isHidden ? moreButton : sortButton) }
    @objc private func showOverflowViewMenu(_ sender: Any?) { showViewMenu(viewButton.isHidden ? moreButton : viewButton) }
    @objc private func showOverflowFilterMenu(_ sender: Any?) { showFilterMenu(filterButton.isHidden ? moreButton : filterButton) }

    @objc func toggleSplitView(_ sender: Any?) {
        browserDelegate?.browserDidBecomeActive(self)
        (view.window?.contentViewController as? ExplorerWindowViewController)?.toggleSplitView()
    }

    @objc func showStorageMap(_ sender: Any?) {
        guard currentLocation != .network else { return }
        DiskUsageWindowController.present(url: currentURL)
    }

    @objc func showFileShelf(_ sender: Any?) {
        FileShelfWindowController.shared.present(for: self)
    }

    @objc func addSelectionToShelf(_ sender: Any?) {
        let urls = fileListController.selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        FileShelf.shared.add(urls)
        statusLabel.stringValue = String(format: L10n.text("Added %d items to File Shelf"), urls.count)
    }

    func acceptShelfItems(kind: FileTransferKind) {
        let urls = FileShelf.shared.urls
        guard !urls.isEmpty, let destination = currentLocation.folderURL else { return }
        startTransfer(kind: kind, urls: urls, destination: destination) { createdURLs in
            if kind == .move { FileShelf.shared.remove(urls) }
            if !createdURLs.isEmpty { self.loadDirectory(selectURLs: createdURLs) }
        }
    }

    @objc func viewContents(_ sender: Any?) {
        guard fileListController.selectedItems.count == 1,
              let item = fileListController.selectedItems.first,
              !item.isDirectory else { return }
        FileContentViewerWindowController.present(url: item.url)
    }

    @objc func quickSelect(_ sender: Any?) {
        guard displaysFileItems, let window = view.window else { return }
        let accessory = QuickSelectAccessoryView()
        let alert = NSAlert()
        alert.messageText = L10n.text("Quick Select")
        alert.informativeText = L10n.text("Select visible items using a wildcard or regular expression.")
        alert.addButton(withTitle: L10n.text("Select"))
        alert.addButton(withTitle: L10n.text("Cancel"))
        alert.accessoryView = accessory
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, let options = accessory.options else { return }
            do {
                let count = try self.fileListController.selectItems(
                    matching: options.pattern,
                    usesRegularExpression: options.usesRegularExpression,
                    caseSensitive: options.caseSensitive,
                    includesFolders: options.includesFolders
                )
                self.updateControls()
                self.statusLabel.stringValue = String(format: L10n.text("%d items matched"), count)
            } catch {
                self.present(error: error)
            }
        }
    }

    @objc func createLink(_ sender: Any?) {
        guard fileListController.selectedItems.count == 1,
              let item = fileListController.selectedItems.first,
              let directory = currentLocation.folderURL,
              let window = view.window else { return }
        let accessory = LinkCreationAccessoryView(sourceURL: item.url, isDirectory: item.isDirectory)
        let alert = NSAlert()
        alert.messageText = L10n.text("Create Link")
        alert.informativeText = item.url.path
        alert.addButton(withTitle: L10n.text("Create"))
        alert.addButton(withTitle: L10n.text("Cancel"))
        alert.accessoryView = accessory
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, let options = accessory.options else { return }
            let destination = self.fileSystem.uniqueDestination(
                named: options.name,
                in: directory,
                preservingExtension: !item.isDirectory
            )
            do {
                switch options.kind {
                case .symbolic:
                    try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: item.url)
                case .hard:
                    try FileManager.default.linkItem(at: item.url, to: destination)
                }
                self.loadDirectory(selectURL: destination)
            } catch {
                self.present(error: error)
            }
        }
    }

    @objc func openInOtherPane(_ sender: Any?) {
        let destination: URL
        if fileListController.selectedItems.count == 1,
           let item = fileListController.selectedItems.first,
           item.isDirectory, !item.isPackage {
            destination = item.url
        } else {
            destination = currentURL
        }
        (view.window?.contentViewController as? ExplorerWindowViewController)?
            .open(url: destination, inOtherPaneFrom: self)
    }

    @objc private func showSearchSyntaxHelp(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = L10n.text("Search Syntax")
        alert.informativeText = [
            L10n.text("Words search names, types, and paths."),
            "ext:jpg,png  ·  kind:image  ·  tag:red",
            "size:>100MB  ·  modified:today/week/month/year",
            L10n.text("Combine filters with spaces to require all conditions.")
        ].joined(separator: "\n")
        alert.addButton(withTitle: L10n.text("Done"))
        if let window = view.window { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }

    @objc private func findDuplicateFiles(_ sender: Any?) {
        guard let root = currentLocation.folderURL else { return }
        statusLabel.stringValue = L10n.text("Finding duplicate files") + "…"
        let includeHidden = showHiddenFiles
        let operation = Task.detached(priority: .userInitiated) {
            DuplicateFinderService.find(in: root, showHidden: includeHidden)
        }
        Task { @MainActor [weak self] in
            let report = await operation.value
            guard let self else { return }
            self.updateControls()
            self.presentDuplicateReport(report, root: root)
        }
    }

    func setSplitPaneAppearance(isActive: Bool, isSplit: Bool) {
        guard isViewLoaded else { return }
        view.layer?.borderWidth = 0
        splitButton.contentTintColor = isSplit ? .controlAccentColor : .labelColor
        splitButton.toolTip = L10n.text(isSplit ? "Close Split View" : "Split View")
    }

    @objc private func selectSortKey(_ sender: NSMenuItem) {
        guard let key = FileSortKey(rawValue: sender.tag) else { return }
        fileListController.setSort(key: key)
        updateControls()
    }

    @objc private func selectSortDirection(_ sender: NSMenuItem) {
        fileListController.setSort(ascending: sender.tag == 1)
        updateControls()
    }

    @objc private func selectFilter(_ sender: NSMenuItem) {
        guard let filter = FileFilterKind(rawValue: sender.tag) else { return }
        fileListController.setKindFilter(filter)
        updateControls()
    }

    @objc func showDetailsView(_ sender: Any?) {
        fileListController.setViewMode(.details)
        viewButton.image = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: nil)
    }

    @objc func showIconView(_ sender: Any?) {
        fileListController.setViewMode(.icons)
        viewButton.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
    }

    @objc private func toggleCompactView(_ sender: Any?) {
        fileListController.toggleCompactSpacing()
    }

    @objc func toggleDetailsPane(_ sender: Any?) {
        detailsVisible.toggle()
        detailsController.view.isHidden = !detailsVisible
        if detailsVisible {
            detailsController.display(items: fileListController.selectedItems)
        }
        updateControls()
    }

    @objc private func toggleFileExtensions(_ sender: Any?) {
        fileListController.toggleFileExtensions()
    }

    @objc func toggleFolderSizes(_ sender: Any?) {
        guard canConfigureFolderSizes else { return }
        fileListController.toggleFolderSizes()
        updateControls()
    }

    @objc func setDateGroupingMode(_ sender: NSMenuItem) {
        guard canConfigureDateGrouping,
              let mode = FileDateGroupingMode(rawValue: sender.tag) else { return }
        fileListController.setDateGroupingMode(mode)
        updateControls()
    }

    @objc func saveViewForThisFolder(_ sender: Any?) {
        guard canConfigureFolderView else { return }
        fileListController.saveCurrentFolderView(scope: .thisFolder)
        updateControls()
    }

    @objc func applyViewToSubfolders(_ sender: Any?) {
        guard canConfigureFolderView else { return }
        fileListController.saveCurrentFolderView(scope: .subfolders)
        updateControls()
    }

    @objc func resetFolderView(_ sender: Any?) {
        guard canConfigureFolderView else { return }
        fileListController.resetCurrentFolderView()
        updateControls()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(setDateGroupingMode(_:)) {
            menuItem.state = menuItem.tag == fileListController.dateGroupingMode.rawValue ? .on : .off
            return canConfigureDateGrouping
        }
        if menuItem.action == #selector(toggleHiddenFiles(_:)) {
            menuItem.state = showHiddenFiles ? .on : .off
        }
        if menuItem.action == #selector(toggleFolderSizes(_:)) {
            menuItem.state = fileListController.showsFolderSizes ? .on : .off
            return canConfigureFolderSizes
        }
        if menuItem.action == #selector(saveViewForThisFolder(_:))
            || menuItem.action == #selector(applyViewToSubfolders(_:)) {
            return canConfigureFolderView
        }
        if menuItem.action == #selector(resetFolderView(_:)) {
            return canConfigureFolderView && hasSavedViewForCurrentFolder
        }
        if menuItem.action == #selector(goBack(_:)) { return canNavigateBack }
        if menuItem.action == #selector(goForward(_:)) { return canNavigateForward }
        if menuItem.action == #selector(goUp(_:)) { return canNavigateUp }
        if menuItem.action == #selector(newFolder(_:))
            || menuItem.action == #selector(newEmptyFile(_:)) { return canCreateItems }
        if menuItem.action == #selector(newFolderWithSelection(_:)) {
            return canCreateFolderFromSelection
        }
        if menuItem.action == #selector(duplicate(_:)) { return canDuplicateSelection }
        if menuItem.action == #selector(rename(_:))
            || menuItem.action == #selector(moveToTrash(_:))
            || menuItem.action == #selector(cut(_:)) { return canRenameSelection }
        if menuItem.action == #selector(openSelection(_:))
            || menuItem.action == #selector(copy(_:))
            || menuItem.action == #selector(showSelectionDetails(_:))
            || menuItem.action == #selector(quickLook(_:)) { return hasFileSelection }
        if menuItem.action == #selector(paste(_:))
            || menuItem.action == #selector(pasteAndMove(_:)) { return canPasteItems }
        return true
    }

    @objc private func changeZoomFromSlider(_ sender: NSSlider) {
        fileListController.setZoomLevel(sender.integerValue)
    }

    @objc func zoomIn(_ sender: Any?) { fileListController.adjustZoomStep(1) }
    @objc func zoomOut(_ sender: Any?) { fileListController.adjustZoomStep(-1) }
    @objc func actualSize(_ sender: Any?) { fileListController.resetZoom() }

    @objc func showViewOptions(_ sender: Any?) {
        showViewMenu(viewButton)
    }

    @objc func toggleSidebar(_ sender: Any?) {
        if let container = view.window?.contentViewController as? ExplorerWindowViewController {
            container.toggleSidebarVisibility()
        } else {
            sidebarController.view.isHidden.toggle()
        }
    }

    func setSidebarVisible(_ visible: Bool) {
        sidebarController.view.isHidden = !visible
        if visible {
            DispatchQueue.main.async { [weak self] in
                self?.restoreSidebarWidth()
            }
        }
    }

    private func initializeSidebarWidthIfNeeded() {
        guard !sidebarWidthInitialized else { return }
        sidebarWidthInitialized = true
        restoreSidebarWidth()
    }

    private func restoreSidebarWidth() {
        guard !sidebarController.view.isHidden, mainSplit.arrangedSubviews.count > 1 else { return }
        let savedWidth = UserDefaults.standard.object(forKey: Self.sidebarWidthKey) as? Double
        let desiredWidth = CGFloat(savedWidth ?? 210)
        let maximum = max(110, min(360, mainSplit.bounds.width - 140))
        mainSplit.setPosition(min(max(desiredWidth, 110), maximum), ofDividerAt: 0)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard splitView === mainSplit, dividerIndex == 0 else { return proposedMinimumPosition }
        return max(proposedMinimumPosition, 110)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard splitView === mainSplit, dividerIndex == 0 else { return proposedMaximumPosition }
        let maximum = max(110, min(360, splitView.bounds.width - 140))
        return min(proposedMaximumPosition, maximum)
    }

    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        guard splitView === mainSplit else { return true }
        return view !== sidebarController.view
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard let resizedSplitView = notification.object as? NSSplitView,
              resizedSplitView === mainSplit,
              sidebarWidthInitialized,
              !sidebarController.view.isHidden else { return }
        UserDefaults.standard.set(Double(sidebarController.view.frame.width), forKey: Self.sidebarWidthKey)
    }

    @objc func toggleStatusBar(_ sender: Any?) {
        statusBarView?.isHidden.toggle()
    }

    @objc func newFolder(_ sender: Any?) {
        guard canCreateItems else { return }
        let destination = currentURL
        performCreatedItemMutation(renameAfterCreation: true) { [fileSystem] in
            try fileSystem.createFolder(in: destination)
        }
    }

    @objc func newFolderWithSelection(_ sender: Any?) {
        let items = fileListController.selectedItems
        guard canCreateFolderFromSelection,
              !items.isEmpty,
              let window = view.window else { return }

        let alert = NSAlert()
        alert.messageText = L10n.text("New Folder with Selection")
        alert.informativeText = L10n.text("Enter a name for the folder that will contain the selected items.")
        alert.addButton(withTitle: L10n.text("Create"))
        alert.addButton(withTitle: L10n.text("Cancel"))
        let field = NSTextField(string: L10n.text("New Folder With Items"))
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        alert.accessoryView = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            guard let parentDirectory = self.currentLocation.folderURL else { return }
            let locationAtStart = self.currentLocation
            let operationGeneration = self.locationGeneration
            let transaction = NewFolderWithSelectionTransaction(
                parentDirectory: parentDirectory,
                preferredName: field.stringValue,
                selectedURLs: items.map(\.url)
            )

            self.isPerformingStandaloneMutation = true
            self.watcher.stop()
            self.updateControls()
            FileOperationManager.shared.performSerializedMutation({
                try transaction.perform()
            }) { [weak self] result in
                guard let self else { return }
                self.isPerformingStandaloneMutation = false
                switch result {
                case .success(let transactionResult):
                    self.registerNewFolderWithSelectionUndo(transaction, result: transactionResult)
                    if self.locationGeneration == operationGeneration,
                       self.currentLocation == locationAtStart {
                        self.loadDirectory(selectURL: transactionResult.folderURL)
                    } else {
                        self.updateControls()
                    }
                case .failure(let error):
                    if self.locationGeneration == operationGeneration,
                       self.currentLocation == locationAtStart {
                        self.loadDirectory(preservingSelection: true)
                    } else {
                        self.updateControls()
                    }
                    self.present(error: error)
                }
            }
        }
    }

    @objc private func newEmptyFile(_ sender: Any?) {
        guard canCreateItems else { return }
        let destination = currentURL
        performCreatedItemMutation { [fileSystem] in
            try fileSystem.createEmptyFile(in: destination)
        }
    }

    private func performCreatedItemMutation(renameAfterCreation: Bool = false, _ operation: @escaping () throws -> URL) {
        guard canCreateItems else { return }
        let locationAtStart = currentLocation
        let operationGeneration = locationGeneration
        isPerformingStandaloneMutation = true
        watcher.stop()
        updateControls()
        FileOperationManager.shared.performSerializedMutation(operation) { [weak self] result in
            guard let self else { return }
            self.isPerformingStandaloneMutation = false
            switch result {
            case .success(let created):
                self.registerCreatedItemsUndo([created])
                if self.locationGeneration == operationGeneration,
                   self.currentLocation == locationAtStart {
                    if renameAfterCreation { self.pendingNewFolderRename = created }
                    self.loadDirectory(selectURL: created)
                } else {
                    self.updateControls()
                }
            case .failure(let error):
                if self.locationGeneration == operationGeneration,
                   self.currentLocation == locationAtStart {
                    self.loadDirectory(preservingSelection: true)
                } else {
                    self.updateControls()
                }
                self.present(error: error)
            }
        }
    }

    @objc func openSelection(_ sender: Any?) {
        let items = fileListController.selectedItems
        guard !items.isEmpty else { return }
        if items.count == 1, items[0].isDirectory, !items[0].isPackage {
            if desktopPresentation {
                desktopOpenHandler?(items[0].url)
            } else {
                navigate(to: items[0].url)
            }
        } else {
            items.forEach {
                NSDocumentController.shared.noteNewRecentDocumentURL($0.url)
                NSWorkspace.shared.open($0.url)
            }
        }
    }

    @objc func openSelectionInNewTab(_ sender: Any?) {
        guard let item = fileListController.selectedItems.first,
              fileListController.selectedItems.count == 1,
              item.isDirectory, !item.isPackage else { return }
        if desktopPresentation {
            desktopOpenHandler?(item.url)
        } else {
            (view.window?.contentViewController as? ExplorerWindowViewController)?.addTab(at: item.url)
        }
    }

    @objc func openSelectionInNewWindow(_ sender: Any?) {
        guard let item = fileListController.selectedItems.first,
              fileListController.selectedItems.count == 1,
              item.isDirectory, !item.isPackage else { return }
        (NSApp.delegate as? AppDelegate)?.createWindow(at: item.url)
    }

    @objc func showPackageContents(_ sender: Any?) {
        guard let item = fileListController.selectedItems.first,
              fileListController.selectedItems.count == 1,
              item.isPackage else { return }
        navigate(to: item.url)
    }

    @objc func openSelectionWithApplication(_ sender: NSMenuItem) {
        guard let applicationURL = sender.representedObject as? URL else { return }
        let urls = fileListController.selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(urls, withApplicationAt: applicationURL, configuration: configuration) { [weak self] _, error in
            if let error { DispatchQueue.main.async { self?.present(error: error) } }
        }
    }

    @objc func openInTerminal(_ sender: Any?) {
        let selected = fileListController.selectedItems.first
        let directory: URL
        if let selected {
            directory = selected.isDirectory && !selected.isPackage
                ? selected.url
                : selected.url.deletingLastPathComponent()
        } else {
            directory = currentURL
        }
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            present(message: L10n.text("Terminal not found"), detail: L10n.text("The Terminal application could not be found."))
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        NSWorkspace.shared.open([directory], withApplicationAt: terminal, configuration: configuration) { [weak self] _, error in
            if let error { DispatchQueue.main.async { self?.present(error: error) } }
        }
    }

    @objc func copyPath(_ sender: Any?) {
        let paths = fileListController.selectedItems.map(\.url.path)
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    @objc func copyName(_ sender: Any?) {
        let names = fileListController.selectedItems.map(\.name)
        guard !names.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(names.joined(separator: "\n"), forType: .string)
    }

    @objc func calculateSHA256(_ sender: Any?) {
        let urls = fileListController.selectedItems.filter { !$0.isDirectory }.map(\.url)
        guard !urls.isEmpty else { return }
        statusLabel.stringValue = L10n.text("Calculating checksum") + "…"
        let operation = Task.detached(priority: .userInitiated) {
            Result { try ChecksumService.sha256(for: urls) }
        }
        Task { @MainActor [weak self] in
            let result = await operation.value
            guard let self else { return }
            self.updateControls()
            switch result {
            case .success(let values): self.presentChecksumResults(values)
            case .failure(let error): self.present(error: error)
            }
        }
    }

    @objc func compressSelection(_ sender: Any?) {
        let urls = fileListController.selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        let parent = urls[0].deletingLastPathComponent()
        guard urls.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL }) else {
            present(message: L10n.text("Cannot compress items"), detail: L10n.text("Select items from the same folder."))
            return
        }

        let requestedFormat = (sender as? NSMenuItem)?.representedObject as? String
        let suggestedFormat = requestedFormat.flatMap(ArchiveCreationFormat.init(rawValue:)) ?? .zip
        let baseName = urls.count == 1
            ? urls[0].deletingPathExtension().lastPathComponent
            : (parent.lastPathComponent.isEmpty ? L10n.text("Archive") : parent.lastPathComponent)
        guard let window = view.window else { return }
        let accessory = ArchiveCreationAccessoryView(
            baseName: baseName,
            suggestedFormat: suggestedFormat
        )
        let alert = NSAlert()
        alert.messageText = L10n.text("Create Archive")
        alert.informativeText = String(
            format: L10n.text("Choose the archive name, format, and compression level for %d selected items."),
            urls.count
        )
        alert.accessoryView = accessory
        alert.addButton(withTitle: L10n.text("Compress"))
        alert.addButton(withTitle: L10n.text("Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            guard let options = accessory.options else {
                self.present(
                    message: L10n.text("Cannot compress items"),
                    detail: L10n.text("Enter a valid archive name without path separators.")
                )
                return
            }
            self.resolveCompressionDestination(urls: urls, parent: parent, options: options)
        }
    }

    private func resolveCompressionDestination(
        urls: [URL],
        parent: URL,
        options: ArchiveCreationOptions
    ) {
        let requested = parent.appendingPathComponent(options.baseName + options.format.filenameSuffix)
        guard FileManager.default.fileExists(atPath: requested.path) else {
            startCompression(urls: urls, destination: requested, options: options)
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text("Archive already exists")
        alert.informativeText = String(
            format: L10n.text("An item named %@ already exists. Choose how to save the new archive."),
            requested.lastPathComponent
        )
        alert.addButton(withTitle: L10n.text("Overwrite"))
        alert.addButton(withTitle: L10n.text("Save with Number"))
        alert.addButton(withTitle: L10n.text("Cancel"))
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                do {
                    try FileManager.default.removeItem(at: requested)
                    self.startCompression(urls: urls, destination: requested, options: options)
                } catch {
                    self.present(error: error)
                }
            case .alertSecondButtonReturn:
                let unique = ArchiveService.uniqueDestination(
                    baseName: options.baseName,
                    format: options.format,
                    in: parent
                )
                self.startCompression(urls: urls, destination: unique, options: options)
            default:
                break
            }
        }
        if let window = view.window { alert.beginSheetModal(for: window, completionHandler: completion) }
        else { completion(alert.runModal()) }
    }

    private func startCompression(
        urls: [URL],
        destination: URL,
        options: ArchiveCreationOptions
    ) {
        guard let command = ArchiveService.creationCommand(
            format: options.format,
            compressionLevel: options.compressionLevel,
            sources: urls,
            destination: destination
        ) else {
            present(message: L10n.text("Cannot compress items"), detail: L10n.text("Select items from the same folder."))
            return
        }

        statusLabel.stringValue = String(
            format: L10n.text("Compressing as %@"),
            options.format.title
        ) + "…"
        ArchiveOperationManager.shared.start(
            command: command,
            sources: urls,
            destination: destination,
            format: options.format,
            parentWindow: view.window
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.loadDirectory(selectURL: destination)
            case .failure(let error):
                try? FileManager.default.removeItem(at: destination)
                self.updateControls()
                if case FileTransferError.cancelled = error {
                    break
                } else {
                    self.present(message: L10n.text("Compression failed"), detail: error.localizedDescription)
                }
            }
        }
    }

    @objc func extractSelection(_ sender: Any?) {
        guard let item = fileListController.selectedItems.first,
              fileListController.selectedItems.count == 1,
              item.isExtractableArchive else { return }
        extractArchive(at: item.url)
    }

    private func extractArchive(at archive: URL) {
        let parent = archive.deletingLastPathComponent()
        let destination = fileSystem.uniqueDestination(
            named: ArchiveService.extractionBaseName(for: archive),
            in: parent,
            preservingExtension: false
        )
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        } catch {
            present(error: error)
            return
        }

        statusLabel.stringValue = L10n.text("Extracting archive") + "…"
        let command = ArchiveService.extractionCommand(archive: archive, destination: destination)
        let process = Process()
        process.executableURL = command.executableURL
        process.arguments = command.arguments
        process.currentDirectoryURL = command.currentDirectoryURL
        if let environment = command.environment { process.environment = environment }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] task in
            DispatchQueue.main.async {
                guard let self else { return }
                if task.terminationStatus == 0 {
                    self.loadDirectory(selectURL: destination)
                } else {
                    try? FileManager.default.removeItem(at: destination)
                    self.updateControls()
                    self.present(message: L10n.text("Extraction failed"), detail: archive.path)
                }
            }
        }
        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: destination)
            present(error: error)
        }
    }

    @objc func rotateImagesLeft(_ sender: Any?) { rotateSelectedImages(clockwise: false) }
    @objc func rotateImagesRight(_ sender: Any?) { rotateSelectedImages(clockwise: true) }

    private func rotateSelectedImages(clockwise: Bool) {
        let urls = selectedImageURLs
        guard !urls.isEmpty else { return }
        runImageQuickAction(selectURL: urls.first) {
            for url in urls { try ImageQuickActionService.shared.rotate(url, clockwise: clockwise) }
        }
    }

    @objc func markupImage(_ sender: Any?) {
        guard let url = selectedImageURLs.first else { return }
        guard let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else {
            NSWorkspace.shared.open(url)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: configuration) { [weak self] _, error in
            if let error { DispatchQueue.main.async { self?.present(error: error) } }
        }
    }

    @objc func createPDFFromImages(_ sender: Any?) {
        let urls = selectedImageURLs
        guard !urls.isEmpty else { return }
        let parent = urls[0].deletingLastPathComponent()
        let preferredName = urls.count == 1
            ? urls[0].deletingPathExtension().lastPathComponent + ".pdf"
            : L10n.text("Images.pdf")
        let destination = fileSystem.uniqueDestination(named: preferredName, in: parent, preservingExtension: true)
        runImageQuickAction(selectURL: destination) {
            try ImageQuickActionService.shared.createPDF(from: urls, at: destination)
        }
    }

    @objc func convertImages(_ sender: Any?) {
        let urls = selectedImageURLs
        guard !urls.isEmpty else { return }

        let formats = ImageConversionFormat.allCases
        let sizes = ImageConversionSize.allCases
        let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        formatPopup.addItems(withTitles: formats.map(\.title))
        let sizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        sizePopup.addItems(withTitles: sizes.map(\.title))
        let metadata = NSButton(checkboxWithTitle: L10n.text("Preserve Metadata"), target: nil, action: nil)
        metadata.state = .on
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: L10n.text("Format")), formatPopup],
            [NSTextField(labelWithString: L10n.text("Image Size")), sizePopup]
        ])
        grid.columnSpacing = 12
        grid.rowSpacing = 8
        let accessory = NSStackView(views: [grid, metadata])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 10
        accessory.frame = NSRect(x: 0, y: 0, width: 330, height: 82)

        let alert = NSAlert()
        alert.messageText = L10n.text("Convert Image")
        alert.informativeText = urls.count == 1
            ? urls[0].lastPathComponent
            : String(format: L10n.text("%d images selected"), urls.count)
        alert.addButton(withTitle: L10n.text("Convert"))
        alert.addButton(withTitle: L10n.text("Cancel"))
        alert.accessoryView = accessory

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let format = formats[max(0, formatPopup.indexOfSelectedItem)]
            let size = sizes[max(0, sizePopup.indexOfSelectedItem)]
            var firstDestination: URL?
            self.runImageQuickAction(selectURLProvider: { firstDestination }) {
                for url in urls {
                    let name = url.deletingPathExtension().lastPathComponent + "." + format.pathExtension
                    let destination = self.fileSystem.uniqueDestination(named: name, in: url.deletingLastPathComponent(), preservingExtension: true)
                    if firstDestination == nil { firstDestination = destination }
                    try ImageQuickActionService.shared.convert(
                        url,
                        to: destination,
                        format: format,
                        size: size,
                        preserveMetadata: metadata.state == .on
                    )
                }
            }
        }
        if let window = view.window { alert.beginSheetModal(for: window, completionHandler: completion) }
        else { completion(alert.runModal()) }
    }

    @objc func removeImageBackgrounds(_ sender: Any?) {
        let urls = selectedImageURLs
        guard !urls.isEmpty else { return }
        var firstDestination: URL?
        runImageQuickAction(selectURLProvider: { firstDestination }) {
            for url in urls {
                let name = url.deletingPathExtension().lastPathComponent + L10n.text(" Background Removed") + ".png"
                let destination = self.fileSystem.uniqueDestination(named: name, in: url.deletingLastPathComponent(), preservingExtension: true)
                if firstDestination == nil { firstDestination = destination }
                try ImageQuickActionService.shared.removeBackground(from: url, to: destination)
            }
        }
    }

    @objc func customizeQuickActions(_ sender: Any?) {
        let candidates = [
            "x-apple.systempreferences:com.apple.ExtensionsPreferences?QuickActions",
            "x-apple.systempreferences:com.apple.ExtensionsPreferences"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }

    private var selectedImageURLs: [URL] {
        fileListController.selectedItems.compactMap {
            $0.contentType?.conforms(to: .image) == true ? $0.url : nil
        }
    }

    private func runImageQuickAction(selectURL: URL?, operation: @escaping () throws -> Void) {
        runImageQuickAction(selectURLProvider: { selectURL }, operation: operation)
    }

    private func runImageQuickAction(
        selectURLProvider: @escaping () -> URL?,
        operation: @escaping () throws -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try operation() }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success:
                    self.loadDirectory(selectURL: selectURLProvider())
                case .failure(let error):
                    self.present(error: error)
                }
            }
        }
    }

    @objc func applyTag(_ sender: NSMenuItem) {
        let tagName = sender.representedObject as? String
        let selectedItems = fileListController.selectedItems
        let shouldRemoveTag = tagName.map { selectedTag in
            selectedItems.allSatisfy { item in
                item.tagNames.contains {
                    FinderTagPalette.displayName(for: $0)
                        .localizedCaseInsensitiveCompare(selectedTag) == .orderedSame
                }
                    || item.labelNumber == sender.tag
            }
        } ?? true
        runFileOperation {
            for item in selectedItems {
                let url = item.url
                if let tagName {
                    var names = (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
                    if shouldRemoveTag {
                        names.removeAll {
                            FinderTagPalette.displayName(for: $0)
                                .localizedCaseInsensitiveCompare(tagName) == .orderedSame
                        }
                    } else if !names.contains(where: {
                        FinderTagPalette.displayName(for: $0)
                            .localizedCaseInsensitiveCompare(tagName) == .orderedSame
                    }) {
                        names.append(tagName)
                    }
                    try (url as NSURL).setResourceValue(names, forKey: .tagNamesKey)
                    let remainingColor = names.compactMap(FinderTagPalette.colorIndex(for:)).first ?? 0
                    try (url as NSURL).setResourceValue(remainingColor, forKey: .labelNumberKey)
                } else {
                    try (url as NSURL).setResourceValue([], forKey: .tagNamesKey)
                    try (url as NSURL).setResourceValue(0, forKey: .labelNumberKey)
                }
            }
        }
    }

    @objc func setAsDesktopPicture(_ sender: Any?) {
        guard let url = fileListController.selectedItems.first?.url,
              let service = NSSharingService(named: .useAsDesktopPicture) else { return }
        service.perform(withItems: [url])
    }

    @objc func showSelectionDetails(_ sender: Any?) {
        let items = fileListController.selectedItems
        guard !items.isEmpty else { return }
        InfoWindowController.present(items: items)
    }

    @objc func showCurrentFolderDetails(_ sender: Any?) {
        guard let item = fileSystem.item(for: currentURL) else { return }
        InfoWindowController.present(items: [item])
    }

    @objc func rename(_ sender: Any?) {
        guard canRenameSelection else { return }
        let items = fileListController.selectedItems
        guard !items.isEmpty else { return }
        if items.count > 1 {
            showBatchRename(for: items)
            return
        }
        fileListController.beginInlineRename()
    }

    private func showBatchRename(for items: [FileItem]) {
        guard let window = view.window else { return }
        let accessory = BatchRenameAccessoryView()
        let alert = NSAlert()
        alert.messageText = String(format: L10n.text("Rename %d Items"), items.count)
        alert.informativeText = L10n.text("Choose how the selected item names should change. File extensions are preserved.")
        alert.addButton(withTitle: L10n.text("Rename"))
        alert.addButton(withTitle: L10n.text("Cancel"))
        alert.accessoryView = accessory
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                let names = try accessory.proposedNames(for: items)
                let originals = items.map(\.url)
                let renamed = try self.fileSystem.batchRename(Array(zip(items.map(\.url), names)))
                self.registerMovesUndo(Array(zip(renamed, originals)).map {
                    (current: $0.0, original: $0.1)
                })
                self.loadDirectory(selectURLs: renamed)
            } catch {
                self.present(error: error)
            }
        }
    }

    @objc func duplicate(_ sender: Any?) {
        let urls = fileListController.selectedItems.map(\.url)
        guard !urls.isEmpty, let destination = currentLocation.folderURL else { return }
        // Reuse the cancellable, serialized transfer path so duplicating a
        // large folder never blocks AppKit and every created item is selected.
        startTransfer(kind: .copy, urls: urls, destination: destination)
    }

    @objc func moveToTrash(_ sender: Any?) {
        let urls = fileListController.selectedItems.map(\.url)
        guard !urls.isEmpty, !isPerformingStandaloneMutation, !isPerformingFileUndo else { return }

        let selectedPaths = Set(urls.map { $0.standardizedFileURL.path })
        let visibleURLs = fileListController.visibleItems.map(\.url)
        let firstSelectedIndex = visibleURLs.firstIndex {
            selectedPaths.contains($0.standardizedFileURL.path)
        }
        let nextSelection = firstSelectedIndex.flatMap { index -> URL? in
            if let following = visibleURLs[index...].first(where: {
                !selectedPaths.contains($0.standardizedFileURL.path)
            }) {
                return following
            }
            return visibleURLs[..<index].last(where: {
                !selectedPaths.contains($0.standardizedFileURL.path)
            })
        }
        let operationGeneration = locationGeneration
        let locationAtStart = currentLocation

        isPerformingStandaloneMutation = true
        if case .folder = currentLocation { watcher.stop() }
        updateControls()
        FileOperationManager.shared.performSerializedMutation({ [fileSystem] in
            try fileSystem.trash(urls)
        }) { [weak self] result in
            guard let self else { return }
            self.isPerformingStandaloneMutation = false
            switch result {
            case .success(let trashed):
                self.registerMovesUndo(trashed.map { (current: $0.trashed, original: $0.original) })
                guard self.locationGeneration == operationGeneration,
                      self.currentLocation == locationAtStart else {
                    self.updateControls()
                    return
                }
                switch self.currentLocation {
                case .folder:
                    self.loadDirectory(selectURL: nextSelection)
                case let .tag(tag):
                    self.stopTagQuery()
                    self.loadTag(tag, preservingSelection: false)
                default:
                    self.updateControls()
                }
            case .failure(let error):
                if self.locationGeneration == operationGeneration,
                   self.currentLocation == locationAtStart {
                    self.refresh(nil)
                } else {
                    self.updateControls()
                }
                self.present(error: error)
            }
        }
    }

    @objc func copy(_ sender: Any?) { writeSelectionToPasteboard(operation: "copy") }
    @objc func cut(_ sender: Any?) { writeSelectionToPasteboard(operation: "move") }

    private func writeSelectionToPasteboard(operation: String) {
        let urls = fileListController.selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        pasteboard.setString(operation, forType: Self.operationPasteboardType)
        updateControls()
    }

    private func startTransfer(
        kind: FileTransferKind,
        urls: [URL],
        destination: URL,
        clearPasteboardOnSuccess: Bool = false,
        onSuccess: (([URL]) -> Void)? = nil
    ) {
        guard !urls.isEmpty, !isPerformingStandaloneMutation, !isPerformingFileUndo else { return }
        let normalizedDestination = destination.standardizedFileURL
        let expectedPasteboardChangeCount = clearPasteboardOnSuccess
            ? NSPasteboard.general.changeCount
            : nil
        let conflicts = urls.filter {
            let requested = normalizedDestination.appendingPathComponent($0.lastPathComponent).standardizedFileURL
            return requested != $0.standardizedFileURL && FileManager.default.fileExists(atPath: requested.path)
        }
        if !conflicts.isEmpty, let window = view.window {
            let containsFolderConflict = conflicts.contains { source in
                let requested = normalizedDestination.appendingPathComponent(source.lastPathComponent)
                var sourceIsDirectory: ObjCBool = false
                var destinationIsDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: source.path, isDirectory: &sourceIsDirectory)
                    && sourceIsDirectory.boolValue
                    && FileManager.default.fileExists(atPath: requested.path, isDirectory: &destinationIsDirectory)
                    && destinationIsDirectory.boolValue
            }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(format: L10n.text("%d item name conflicts"), conflicts.count)
            alert.informativeText = containsFolderConflict
                ? L10n.text("Folders with the same name can’t be replaced safely. Keep both folders or skip those items.")
                : L10n.text("The destination already contains items with the same names. Choose how to continue for all conflicts.")
            // Keep Both is deliberately the default: pressing Return must never
            // select the destructive choice in a conflict sheet. Replacing one
            // folder with another is not offered until recursive merge has a
            // complete per-child undo journal.
            alert.addButton(withTitle: L10n.text("Keep Both"))
            if !containsFolderConflict {
                alert.addButton(withTitle: L10n.text("Replace"))
            }
            alert.addButton(withTitle: L10n.text("Skip"))
            alert.addButton(withTitle: L10n.text("Cancel"))
            alert.buttons.last?.keyEquivalent = "\u{1b}"
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self else { return }
                let policy: FileConflictPolicy
                if containsFolderConflict {
                    switch response {
                    case .alertFirstButtonReturn: policy = .keepBoth
                    case .alertSecondButtonReturn: policy = .skip
                    default: return
                    }
                } else {
                    switch response {
                    case .alertFirstButtonReturn: policy = .keepBoth
                    case .alertSecondButtonReturn: policy = .replace
                    case .alertThirdButtonReturn: policy = .skip
                    default: return
                    }
                }
                self.beginTransfer(
                    kind: kind,
                    urls: urls,
                    destination: normalizedDestination,
                    conflictPolicy: policy,
                    clearPasteboardOnSuccess: clearPasteboardOnSuccess,
                    expectedPasteboardChangeCount: expectedPasteboardChangeCount,
                    onSuccess: onSuccess
                )
            }
            return
        }
        beginTransfer(
            kind: kind,
            urls: urls,
            destination: normalizedDestination,
            conflictPolicy: .keepBoth,
            clearPasteboardOnSuccess: clearPasteboardOnSuccess,
            expectedPasteboardChangeCount: expectedPasteboardChangeCount,
            onSuccess: onSuccess
        )
    }

    private func beginTransfer(
        kind: FileTransferKind,
        urls: [URL],
        destination: URL,
        conflictPolicy: FileConflictPolicy,
        clearPasteboardOnSuccess: Bool,
        expectedPasteboardChangeCount: Int?,
        onSuccess: (([URL]) -> Void)?
    ) {
        let currentFolder = currentLocation.folderURL?.standardizedFileURL
        let operationLocationGeneration = locationGeneration
        let removesFromCurrentFolder = kind == .move && urls.contains {
            $0.deletingLastPathComponent().standardizedFileURL == currentFolder
        }
        let changesCurrentFolder = currentFolder == destination || removesFromCurrentFolder
        if changesCurrentFolder {
            // The operation completion performs one authoritative reload. Pausing
            // the watcher avoids competing directory scans for intermediate writes.
            watcher.stop()
        }

        FileOperationManager.shared.startTransfer(
            kind: kind,
            sources: urls,
            destination: destination,
            conflictPolicy: conflictPolicy,
            parentWindow: view.window
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let transferResult):
                let createdURLs = transferResult.createdURLs
                self.registerTransferUndo(transferResult, kind: kind, conflictPolicy: conflictPolicy)
                if clearPasteboardOnSuccess {
                    self.rewriteMovePasteboard(
                        with: transferResult.remainingSources,
                        ifUnchangedSince: expectedPasteboardChangeCount
                    )
                }
                if self.locationGeneration == operationLocationGeneration {
                    if currentFolder == destination, !createdURLs.isEmpty {
                        self.loadDirectory(selectURLs: createdURLs)
                    } else if currentFolder == destination || removesFromCurrentFolder {
                        self.loadDirectory(preservingSelection: true)
                    }
                }
                self.updateControls()
                onSuccess?(createdURLs)
            case .failure(let error):
                let partialFailure = error as? FileTransferPartialFailure
                let partialResult = partialFailure?.partialResult
                let underlyingError = partialFailure?.underlyingError ?? error
                if let partialResult {
                    self.registerTransferUndo(partialResult, kind: kind, conflictPolicy: conflictPolicy)
                    if clearPasteboardOnSuccess {
                        self.rewriteMovePasteboard(
                            with: partialResult.remainingSources,
                            ifUnchangedSince: expectedPasteboardChangeCount
                        )
                    }
                    if self.locationGeneration == operationLocationGeneration {
                        if currentFolder == destination, !partialResult.createdURLs.isEmpty {
                            self.loadDirectory(selectURLs: partialResult.createdURLs)
                        } else if currentFolder == destination || removesFromCurrentFolder {
                            self.loadDirectory(preservingSelection: true)
                        }
                    }
                } else if changesCurrentFolder,
                          self.locationGeneration == operationLocationGeneration {
                    self.loadDirectory(preservingSelection: true)
                }
                self.updateControls()
                if case FileTransferError.cancelled = underlyingError { return }
                if let partialResult {
                    self.presentPartialTransferError(
                        underlyingError,
                        completedCount: partialResult.createdURLs.count
                    )
                } else {
                    self.present(error: underlyingError)
                }
            }
        }
    }

    private func registerTransferUndo(
        _ result: FileTransferResult,
        kind: FileTransferKind,
        conflictPolicy: FileConflictPolicy
    ) {
        guard conflictPolicy != .replace else { return }
        switch kind {
        case .copy:
            registerCreatedItemsUndo(result.createdURLs)
        case .move:
            registerMovesUndo(result.completedMoves.map {
                (current: $0.destination, original: $0.source)
            })
        }
    }

    private func rewriteMovePasteboard(
        with remainingSources: [URL],
        ifUnchangedSince expectedChangeCount: Int?
    ) {
        guard let expectedChangeCount,
              NSPasteboard.general.changeCount == expectedChangeCount else { return }
        let remaining = remainingSources.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !remaining.isEmpty {
            pasteboard.writeObjects(remaining as [NSURL])
            pasteboard.setString("move", forType: Self.operationPasteboardType)
        }
        lastCutPasteboardChangeCount = -1
        synchronizeCutAppearance()
    }

    @objc func copyToOtherPane(_ sender: Any?) {
        let urls = fileListController.selectedItems.map(\.url)
        guard !urls.isEmpty, let other = otherBrowser, let destination = other.currentLocation.folderURL else { return }
        startTransfer(kind: .copy, urls: urls, destination: destination) { [weak other] _ in
            other?.refresh(nil)
        }
    }

    @objc func moveToOtherPane(_ sender: Any?) {
        let urls = fileListController.selectedItems.map(\.url)
        guard !urls.isEmpty, let other = otherBrowser, let destination = other.currentLocation.folderURL else { return }
        startTransfer(kind: .move, urls: urls, destination: destination) { [weak other] _ in
            other?.refresh(nil)
        }
    }

    @objc func comparePanes(_ sender: Any?) {
        guard let left = currentLocation.folderURL,
              let right = otherBrowser?.currentLocation.folderURL else { return }
        statusLabel.stringValue = L10n.text("Comparing folders") + "…"
        let operation = Task.detached(priority: .userInitiated) {
            FolderComparisonService.compare(left: left, right: right)
        }
        Task { @MainActor [weak self] in
            let report = await operation.value
            guard let self else { return }
            self.updateControls()
            self.presentComparisonReport(report, left: left, right: right)
        }
    }

    private func presentChecksumResults(_ values: [(url: URL, digest: String)]) {
        let output = values.map { "\($0.digest)  \($0.url.lastPathComponent)" }.joined(separator: "\n")
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 540, height: 190))
        textView.string = output
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let scrollView = NSScrollView(frame: textView.frame)
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        let alert = NSAlert()
        alert.messageText = L10n.text("SHA-256 Checksum")
        alert.informativeText = String(format: L10n.text("Calculated checksums for %d items."), values.count)
        alert.addButton(withTitle: L10n.text("Copy"))
        alert.addButton(withTitle: L10n.text("Done"))
        alert.accessoryView = scrollView
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(output, forType: .string)
        }
        if let window = view.window { alert.beginSheetModal(for: window, completionHandler: completion) }
        else { completion(alert.runModal()) }
    }

    private func presentComparisonReport(_ report: FolderComparisonReport, left: URL, right: URL) {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 620, height: 300))
        textView.string = "\(L10n.text("Left")): \(left.path)\n\(L10n.text("Right")): \(right.path)\n\n\(report.text)"
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let scrollView = NSScrollView(frame: textView.frame)
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        let alert = NSAlert()
        alert.messageText = L10n.text("Folder Comparison")
        alert.informativeText = report.summary
        alert.addButton(withTitle: L10n.text("Copy"))
        alert.addButton(withTitle: L10n.text("Done"))
        alert.accessoryView = scrollView
        let output = textView.string
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(output, forType: .string)
        }
        if let window = view.window { alert.beginSheetModal(for: window, completionHandler: completion) }
        else { completion(alert.runModal()) }
    }

    private func presentDuplicateReport(_ report: DuplicateFinderReport, root: URL) {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 620, height: 320))
        textView.string = "\(L10n.text("Location")): \(root.path)\n\(L10n.text("Scanned files")): \(report.scannedFileCount)\n\n\(report.text)"
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let scrollView = NSScrollView(frame: textView.frame)
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        let alert = NSAlert()
        alert.messageText = L10n.text("Duplicate Files")
        alert.informativeText = report.summary
        alert.addButton(withTitle: L10n.text("Copy"))
        alert.addButton(withTitle: L10n.text("Done"))
        alert.accessoryView = scrollView
        let output = textView.string
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(output, forType: .string)
        }
        if let window = view.window { alert.beginSheetModal(for: window, completionHandler: completion) }
        else { completion(alert.runModal()) }
    }

    @objc func paste(_ sender: Any?) {
        guard canCreateItems else { return }
        let pasteboard = NSPasteboard.general
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty else { return }
        let shouldMove = pasteboard.string(forType: Self.operationPasteboardType) == "move"
        startTransfer(
            kind: shouldMove ? .move : .copy,
            urls: urls,
            destination: currentURL,
            clearPasteboardOnSuccess: shouldMove
        )
    }

    @objc func pasteAndMove(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty,
              canCreateItems else { return }
        startTransfer(kind: .move, urls: urls, destination: currentURL, clearPasteboardOnSuccess: true)
    }

    @objc private func share(_ sender: Any?) {
        let urls = fileListController.selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        let anchor = (sender as? NSButton) ?? moreButton
        NSSharingServicePicker(items: urls).show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    @objc func showInFinder(_ sender: Any?) {
        let urls = fileListController.selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc func quickLook(_ sender: Any?) {
        guard !fileListController.selectedItems.isEmpty else { return }
        if let panel = QLPreviewPanel.shared() {
            panel.makeKeyAndOrderFront(nil)
            panel.reloadData()
        }
    }

    @objc func goBack(_ sender: Any?) {
        guard historyIndex > 0 else { return }
        captureCurrentHistoryEntry()
        let destinationIndex = historyIndex - 1
        let entry = history[destinationIndex]
        setLocation(
            entry.location,
            addToHistory: false,
            restoredQuery: entry.query,
            restoredSelection: entry.selectionURLs,
            restoredHistoryIndex: destinationIndex
        )
    }

    @objc func goForward(_ sender: Any?) {
        guard historyIndex < history.count - 1 else { return }
        captureCurrentHistoryEntry()
        let destinationIndex = historyIndex + 1
        let entry = history[destinationIndex]
        setLocation(
            entry.location,
            addToHistory: false,
            restoredQuery: entry.query,
            restoredSelection: entry.selectionURLs,
            restoredHistoryIndex: destinationIndex
        )
    }

    @objc func goUp(_ sender: Any?) {
        guard case .folder = currentLocation, currentURL.path != "/" else { return }
        breadcrumbBar.endEditing()
        let child = currentURL
        navigate(to: currentURL.deletingLastPathComponent(), selectURL: child)
    }

    @objc func goHome(_ sender: Any?) { showHome() }

    @objc func showNetwork(_ sender: Any?) {
        setLocation(.network, addToHistory: true)
    }

    @objc func goToUserHome(_ sender: Any?) {
        navigate(to: FileManager.default.homeDirectoryForCurrentUser)
    }

    @objc func goToComputer(_ sender: Any?) { navigate(to: URL(fileURLWithPath: "/")) }
    @objc func goToDesktop(_ sender: Any?) { navigate(toSearchPath: .desktopDirectory) }
    @objc func goToDownloads(_ sender: Any?) { navigate(toSearchPath: .downloadsDirectory) }
    @objc func goToDocuments(_ sender: Any?) { navigate(toSearchPath: .documentDirectory) }
    @objc func goToUtilities(_ sender: Any?) { navigate(to: URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true)) }

    @objc func goToICloudDrive(_ sender: Any?) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        navigate(to: url)
    }

    @objc func goToRecents(_ sender: Any?) { setLocation(.recents, addToHistory: true) }

    @objc func openAirDrop(_ sender: Any?) {
        if let url = URL(string: "airdrop://") { NSWorkspace.shared.open(url) }
    }

    private func navigate(toSearchPath directory: FileManager.SearchPathDirectory) {
        guard let url = FileManager.default.urls(for: directory, in: .userDomainMask).first else { return }
        navigate(to: url)
    }

    @objc func ejectCurrentVolume(_ sender: Any?) {
        let candidate = fileListController.selectedItems.first?.url ?? currentLocation.folderURL
        guard let candidate else { return }
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsLocalKey],
            options: [.skipHiddenVolumes]
        ) ?? []
        guard let volume = volumes
            .filter({ $0.path != "/" && (candidate.path == $0.path || candidate.path.hasPrefix($0.path + "/")) })
            .max(by: { $0.path.count < $1.path.count }) else { return }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
        } catch {
            present(error: error)
        }
    }

    @objc func refresh(_ sender: Any?) {
        if case .folder = currentLocation {
            if searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                fileListController.invalidateFolderSizeCache()
                loadDirectory(preservingSelection: true)
            } else {
                beginRecursiveSearch(searchField.stringValue)
            }
        } else if case let .tag(tag) = currentLocation {
            stopTagQuery()
            loadTag(tag, preservingSelection: true)
        } else if currentLocation == .home || currentLocation == .recents {
            homeController.setFilter(searchField.stringValue)
        } else {
            networkController.reload()
        }
    }

    @objc func focusAddressBar(_ sender: Any?) { breadcrumbBar.beginEditing() }
    @objc func focusSearch(_ sender: Any?) {
        forceSearchVisible = true
        searchField.isHidden = false
        view.needsLayout = true
        view.window?.makeFirstResponder(searchField)
    }

    @objc func cycleExplorerFocus(_ sender: Any?) {
        cycleExplorerFocus(direction: 1)
    }

    @objc func cycleExplorerFocusBackward(_ sender: Any?) {
        cycleExplorerFocus(direction: -1)
    }

    private func cycleExplorerFocus(direction: Int) {
        enum FocusRegion: CaseIterable {
            case content
            case address
            case search
            case sidebar
        }

        let firstResponder = view.window?.firstResponder
        let current: FocusRegion
        if firstResponder is FileTableView || firstResponder is FileCollectionView
            || homeController.hasKeyboardFocus
            || (networkController.isViewLoaded && networkController.hasKeyboardFocus) {
            current = .content
        } else if breadcrumbBar.isEditingAddress {
            current = .address
        } else if firstResponder === searchField || searchField.currentEditor() === firstResponder {
            current = .search
        } else if sidebarController.hasKeyboardFocus {
            current = .sidebar
        } else {
            current = .content
        }

        var regions: [FocusRegion] = []
        switch currentLocation {
        case .folder, .tag:
            if !fileListController.view.isHidden { regions.append(.content) }
        case .home, .recents:
            if !homeController.view.isHidden { regions.append(.content) }
        case .network:
            if networkController.isViewLoaded, !networkController.view.isHidden {
                regions.append(.content)
            }
        }
        if !breadcrumbBar.isHidden { regions.append(.address) }
        if !searchField.isHidden { regions.append(.search) }
        if !sidebarController.view.isHidden { regions.append(.sidebar) }
        guard !regions.isEmpty else { return }

        let target: FocusRegion
        if let currentIndex = regions.firstIndex(of: current) {
            let nextIndex = (currentIndex + (direction > 0 ? 1 : -1) + regions.count) % regions.count
            target = regions[nextIndex]
        } else {
            // The responder may be a toolbar button or a content view without
            // its own selection model. Enter the visible focus ring at the
            // beginning (or end for Shift-F6) instead of targeting a hidden view.
            target = direction > 0 ? regions[0] : regions[regions.count - 1]
        }

        switch target {
        case .content:
            breadcrumbBar.endEditing()
            switch currentLocation {
            case .folder, .tag: fileListController.focus()
            case .home, .recents: homeController.focus()
            case .network: networkController.focus()
            }
        case .address:
            focusAddressBar(nil)
        case .search:
            breadcrumbBar.endEditing()
            focusSearch(nil)
        case .sidebar where !sidebarController.view.isHidden:
            breadcrumbBar.endEditing()
            sidebarController.focus()
        default:
            return
        }
    }

    override func selectAll(_ sender: Any?) {
        if displaysFileItems { fileListController.selectAllItems() }
    }

    @objc func invertSelection(_ sender: Any?) {
        if displaysFileItems { fileListController.invertSelection() }
    }

    @objc func selectSameExtension(_ sender: Any?) {
        if displaysFileItems { fileListController.selectItemsWithSameExtension() }
    }

    @objc func toggleHiddenFiles(_ sender: Any?) {
        showHiddenFiles.toggle()
        UserDefaults.standard.set(showHiddenFiles, forKey: "ExplorerShowHiddenFiles")
        if case .folder = currentLocation { loadDirectory(preservingSelection: true) }
        if case let .tag(tag) = currentLocation {
            stopTagQuery()
            loadTag(tag, preservingSelection: true)
        }
    }

    @objc func toggleQuickAccessPin(_ sender: Any?) {
        let selectedFolder = fileListController.selectedItems.first.flatMap { item -> URL? in
            guard fileListController.selectedItems.count == 1,
                  item.isDirectory,
                  !item.isPackage else { return nil }
            return item.url
        }
        guard let url = selectedFolder ?? currentLocation.folderURL else {
            NSSound.beep()
            return
        }
        if ExplorerPreferences.isFolderPinned(url) {
            ExplorerPreferences.unpinFolder(url)
        } else {
            ExplorerPreferences.pinFolder(url)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSSearchField === searchField else { return }
        if currentLocation == .home || currentLocation == .recents {
            homeController.setFilter(searchField.stringValue)
        } else if currentLocation == .network {
            networkController.setFilter(searchField.stringValue)
        } else if case .tag = currentLocation {
            fileListController.setFilter(searchField.stringValue)
        } else {
            // The toolbar field performs recursive search. Applying a local
            // filter first caused two complete sort/group/reload passes and a
            // distracting intermediate result for every keystroke.
            beginRecursiveSearch(searchField.stringValue)
        }
        updateControls()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard obj.object as? NSSearchField === searchField else { return }
        forceSearchVisible = false
        view.needsLayout = true
    }

    private func beginRecursiveSearch(_ rawQuery: String) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        cancelSearch()
        guard !query.isEmpty, case .folder = currentLocation else {
            if case .folder = currentLocation { loadDirectory(preservingSelection: true) }
            return
        }

        directoryLoadGeneration += 1
        directoryLoadInProgressPath = nil
        pendingDirectoryReload = false
        tagMetadataLoadToken?.cancel()
        tagMetadataLoadToken = nil
        tagMetadataViewportToken?.cancel()
        tagMetadataViewportToken = nil
        tagMetadataLoadedPaths.removeAll(keepingCapacity: true)
        tagMetadataPendingPaths.removeAll(keepingCapacity: true)
        tagMetadataDesiredPaths.removeAll(keepingCapacity: true)
        let rootURL = currentURL
        let generation = searchGeneration
        let searchToken = DirectoryMetadataLoadToken()
        searchLoadToken = searchToken
        isSearching = true
        watcher.stop()
        fileListController.showLoading(
            title: L10n.text("Searching") + "…",
            clearCurrentItems: true
        )
        updateControls()
        let workItem = DispatchWorkItem { [weak self, searchToken] in
            guard let self, !searchToken.isCancelled else { return }
            let results = self.fileSystem.search(
                in: rootURL,
                query: query,
                showHidden: self.showHiddenFiles,
                shouldContinue: { !searchToken.isCancelled }
            )
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      !searchToken.isCancelled,
                      self.searchLoadToken === searchToken,
                      generation == self.searchGeneration,
                      self.currentURL.standardizedFileURL == rootURL.standardizedFileURL,
                      self.searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
                self.searchWorkItem = nil
                self.searchLoadToken = nil
                self.isSearching = false
                self.watcher.stop()
                self.fileListController.display(
                    items: results,
                    in: rootURL,
                    emptyTitle: L10n.text("No items match your search."),
                    emptyDetail: L10n.text("Try a different name or filter.")
                )
                if let pending = self.pendingDirectorySelection,
                   pending.directory.standardizedFileURL == rootURL.standardizedFileURL {
                    self.fileListController.select(urls: pending.urls)
                    self.pendingDirectorySelection = nil
                }
                self.updateControls()
            }
        }
        searchWorkItem = workItem
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.28, execute: workItem)
    }

    private func cancelSearch() {
        searchLoadToken?.cancel()
        searchLoadToken = nil
        searchWorkItem?.cancel()
        searchWorkItem = nil
        searchGeneration += 1
        isSearching = false
    }

    func breadcrumbBarDidRequestHome(_ breadcrumbBar: BreadcrumbBarView) { showHome() }

    func breadcrumbBar(_ breadcrumbBar: BreadcrumbBarView, didSelect url: URL) { navigate(to: url) }

    func breadcrumbBar(_ breadcrumbBar: BreadcrumbBarView, didSubmitPath path: String) {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedPath = trimmedPath.lowercased()
        if lowercasedPath == "home://" {
            showHome()
            return
        }
        if lowercasedPath == "recent://" || lowercasedPath == "recents://" {
            setLocation(.recents, addToHistory: true)
            return
        }
        if lowercasedPath == "network://" {
            setLocation(.network, addToHistory: true)
            return
        }
        if lowercasedPath.hasPrefix("tag://") {
            let encodedName = String(trimmedPath.dropFirst("tag://".count))
            let name = encodedName.removingPercentEncoding ?? encodedName
            let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedName.isEmpty else {
                NSSound.beep()
                breadcrumbBar.endEditing()
                return
            }
            let knownTag = FinderTagPalette.favoriteTags.first {
                $0.name.localizedCaseInsensitiveCompare(normalizedName) == .orderedSame
            }
            let tag = knownTag ?? FinderTag(
                name: normalizedName,
                colorIndex: FinderTagPalette.colorIndex(for: normalizedName) ?? 0
            )
            setLocation(.tag(tag), addToHistory: true)
            return
        }
        if let scheme = URL(string: trimmedPath)?.scheme?.lowercased(),
           scheme != "file" {
            connectToServerAddress(path, showNetworkAfterOpening: true)
            return
        }
        guard let destination = resolveAddress(path) else {
            present(message: L10n.text("Location not found"), detail: path)
            return
        }
        navigate(to: destination)
    }

    private func resolveAddress(_ rawValue: String) -> URL? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\"") || value.hasPrefix("'") && value.hasSuffix("'")) {
            value.removeFirst()
            value.removeLast()
        }
        guard !value.isEmpty else { return nil }

        if let fileURL = URL(string: value), fileURL.isFileURL {
            return fileURL.standardizedFileURL
        }

        let knownLocations: [String: FileManager.SearchPathDirectory] = [
            "desktop": .desktopDirectory,
            "downloads": .downloadsDirectory,
            "documents": .documentDirectory,
            "pictures": .picturesDirectory,
            "music": .musicDirectory,
            "movies": .moviesDirectory,
            "applications": .applicationDirectory
        ]
        if ["home", "~"].contains(value.lowercased()) {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        if let directory = knownLocations[value.lowercased()],
           let url = FileManager.default.urls(for: directory, in: .userDomainMask).first {
            return url
        }

        for (name, environmentValue) in ProcessInfo.processInfo.environment.sorted(by: { $0.key.count > $1.key.count }) {
            value = value.replacingOccurrences(of: "${\(name)}", with: environmentValue)
            value = value.replacingOccurrences(of: "$\(name)", with: environmentValue)
        }
        value = NSString(string: value).expandingTildeInPath

        if value.hasPrefix("/") {
            return URL(fileURLWithPath: value).standardizedFileURL
        }
        return currentURL.appendingPathComponent(value).standardizedFileURL
    }

    func sidebar(_ sidebar: SidebarViewController, didSelect location: BrowserLocation) {
        guard location != currentLocation else {
            // Clicking the page still on screen cancels an in-flight move.
            navigationLoadToken?.cancel()
            navigationLoadToken = nil
            return
        }
        switch location {
        case .home: showHome()
        case .recents: setLocation(.recents, addToHistory: true)
        case .network: setLocation(.network, addToHistory: true)
        case let .tag(tag): setLocation(.tag(tag), addToHistory: true)
        case let .folder(url): navigate(to: url)
        }
    }

    func homeView(_ homeView: HomeViewController, didOpen url: URL) { navigate(to: url) }

    func networkView(_ networkView: NetworkViewController, didRequestConnect address: String?) {
        if let address {
            connectToServerAddress(address, showNetworkAfterOpening: false)
        } else {
            connectToServer(nil)
        }
    }

    func networkView(_ networkView: NetworkViewController, didRequestEditSavedServer address: String?) {
        if let address {
            presentServerEditor(.edit(originalAddress: address))
        } else {
            presentServerEditor(.add)
        }
    }

    func networkView(_ networkView: NetworkViewController, didOpen volume: URL) { navigate(to: volume) }

    @objc func connectToServer(_ sender: Any?) {
        presentServerEditor(.connect)
    }

    private func presentServerEditor(_ mode: ServerEditorMode) {
        let initialAddress: String?
        let showsSaveOption: Bool
        let primaryTitle: String
        let title: String
        switch mode {
        case .connect:
            initialAddress = nil
            showsSaveOption = true
            primaryTitle = L10n.text("Connect")
            title = L10n.text("Connect to Server")
        case .add:
            initialAddress = nil
            showsSaveOption = false
            primaryTitle = L10n.text("Save")
            title = L10n.text("Add Server")
        case let .edit(originalAddress):
            initialAddress = originalAddress
            showsSaveOption = false
            primaryTitle = L10n.text("Save")
            title = L10n.text("Edit Server")
        }

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = L10n.text("Choose a protocol, then enter a host and optional share or path. You can also paste a complete server URL.")
        alert.addButton(withTitle: primaryTitle)
        alert.addButton(withTitle: L10n.text("Cancel"))
        let accessory = ServerConnectionAccessoryView(
            initialAddress: initialAddress,
            showsSaveOption: showsSaveOption
        )
        alert.accessoryView = accessory

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                switch mode {
                case .connect:
                    self.connectToServerAddress(
                        accessory.address,
                        showNetworkAfterOpening: false,
                        remember: accessory.saveCheckbox.state == .on
                    )
                case .add:
                    try ServerConnectionManager.shared.save(accessory.address)
                    self.networkController.reload()
                case let .edit(originalAddress):
                    try ServerConnectionManager.shared.replace(originalAddress, with: accessory.address)
                    self.networkController.reload()
                }
            } catch {
                self.present(error: error)
            }
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
            DispatchQueue.main.async { accessory.focusAddressField() }
        } else {
            DispatchQueue.main.async { accessory.focusAddressField() }
            completion(alert.runModal())
        }
    }

    private func connectToServerAddress(
        _ address: String,
        showNetworkAfterOpening: Bool,
        remember: Bool = true
    ) {
        do {
            try ServerConnectionManager.shared.connect(to: address, remember: remember)
            if showNetworkAfterOpening { setLocation(.network, addToHistory: true) }
            networkController.reload()
        } catch {
            present(error: error)
        }
    }

    func fileList(_ fileList: FileListViewController, didActivate item: FileItem) {
        if item.isDirectory, !item.isPackage {
            if desktopPresentation {
                desktopOpenHandler?(item.url)
            } else {
                navigate(to: item.url)
            }
        } else if item.isExtractableArchive {
            extractArchive(at: item.url)
        } else {
            NSDocumentController.shared.noteNewRecentDocumentURL(item.url)
            NSWorkspace.shared.open(item.url)
        }
    }

    func fileListSelectionDidChange(_ fileList: FileListViewController) {
        updateControls()
        selectionPresentationWorkItem?.cancel()
        guard detailsVisible || QLPreviewPanel.sharedPreviewPanelExists() else { return }
        let workItem = DispatchWorkItem { [weak self, weak fileList] in
            guard let self, let fileList else { return }
            if self.detailsVisible { self.detailsController.display(items: fileList.selectedItems) }
            if QLPreviewPanel.sharedPreviewPanelExists() { QLPreviewPanel.shared()?.reloadData() }
        }
        selectionPresentationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: workItem)
    }

    func fileList(_ fileList: FileListViewController, didChangeViewMode mode: FileViewMode) {
        let symbol = mode == .details ? "list.bullet" : "square.grid.2x2"
        viewButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        zoomSlider.doubleValue = Double(fileList.zoomLevel)
    }

    func fileListDidRequestRename(_ fileList: FileListViewController) { rename(nil) }
    func fileListDidRequestBack(_ fileList: FileListViewController) { goBack(nil) }
    func fileListDidRequestForward(_ fileList: FileListViewController) { goForward(nil) }
    func fileList(_ fileList: FileListViewController, didRequestRename item: FileItem, to newName: String) {
        if let warning = FileRenameWarning.makeAlert(for: item.url, proposedName: newName, isDirectory: item.isDirectory),
           warning.runModal() != .alertFirstButtonReturn { return }
        do {
            let renamed = try fileSystem.rename(item.url, to: newName)
            if renamed.standardizedFileURL != item.url.standardizedFileURL {
                registerMovesUndo([(current: renamed, original: item.url)])
            }
            loadDirectory(selectURL: renamed)
        } catch {
            present(error: error)
            loadDirectory(selectURL: item.url)
        }
    }
    func fileListDidRequestTrash(_ fileList: FileListViewController) { moveToTrash(nil) }
    func fileListDidRequestQuickLook(_ fileList: FileListViewController) { quickLook(nil) }

    func fileList(_ fileList: FileListViewController, didRequestImport urls: [URL], destination: URL, move: Bool) {
        startTransfer(kind: move ? .move : .copy, urls: urls, destination: destination)
    }

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        let supported: Set<NSPasteboard.PasteboardType> = [.fileURL, .URL, .string]
        if let sendType, supported.contains(sendType), !fileListController.selectedItems.isEmpty {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    @objc func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let urls = fileListController.selectedItems.map(\.url)
        guard !urls.isEmpty else { return false }
        pboard.clearContents()
        let wroteURLs = pboard.writeObjects(urls as [NSURL])
        if types.contains(.string) {
            pboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        }
        return wroteURLs
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self; panel.delegate = self }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil; panel.delegate = nil }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { fileListController.selectedItems.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let items = fileListController.selectedItems
        guard items.indices.contains(index) else { return nil }
        return items[index].url as NSURL
    }
}
