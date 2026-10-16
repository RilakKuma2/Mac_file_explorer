import AppKit

enum ClosedExplorerPaneSide: Equatable {
    case left
    case right
}

struct ClosedExplorerSplitContext: Equatable {
    let closedSide: ClosedExplorerPaneSide
    let companionLocation: BrowserLocation
}

struct ClosedExplorerTab: Equatable {
    let location: BrowserLocation
    let splitContext: ClosedExplorerSplitContext?
}

/// App-session-only history shared by every Explorer window.
///
/// Keeping this separate from the live view controllers avoids retaining closed
/// tabs (and their directory listings, thumbnails, and watchers) just to support
/// reopening them.
final class RecentlyClosedTabStore {
    static let shared = RecentlyClosedTabStore(capacity: 6)

    let capacity: Int
    private var entries: [ClosedExplorerTab] = []

    init(capacity: Int) {
        self.capacity = max(0, capacity)
    }

    var count: Int { entries.count }
    var canReopen: Bool { !entries.isEmpty }

    func record(_ tab: ClosedExplorerTab) {
        guard capacity > 0 else { return }
        entries.append(tab)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    func popLast() -> ClosedExplorerTab? {
        entries.popLast()
    }
}

private enum ExplorerPaneSide {
    case left
    case right
}

private final class ExplorerPaneHostView: NSView {
    let browser: MainViewController
    var onActivate: (() -> Void)?

    init(browser: MainViewController) {
        self.browser = browser
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true

        browser.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(browser.view)
        NSLayoutConstraint.activate([
            browser.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            browser.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            browser.view.topAnchor.constraint(equalTo: topAnchor),
            browser.view.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        let minimumWidth = widthAnchor.constraint(greaterThanOrEqualToConstant: 160)
        minimumWidth.priority = .defaultHigh
        minimumWidth.isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        onActivate?()
        super.mouseDown(with: event)
    }

    func update(isActive: Bool, isSplit: Bool) {
        layer?.borderWidth = isSplit && isActive ? 2 : 0
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.82).cgColor
    }
}

private final class ExplorerSplitDropHostView: NSView {
    var canAcceptTab: ((UUID, ExplorerPaneSide) -> Bool)?
    var onDropTab: ((UUID, ExplorerPaneSide) -> Void)?

    private let preview = NSView()
    private var targetedTabID: UUID?
    private var targetedSide: ExplorerPaneSide?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([explorerTabPasteboardType])
        preview.wantsLayer = true
        preview.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.11).cgColor
        preview.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.95).cgColor
        preview.layer?.borderWidth = 3
        preview.layer?.cornerRadius = 10
        preview.isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropPreview(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropPreview(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hideDropPreview()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        targetedTabID != nil && targetedSide != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let tabID = targetedTabID, let side = targetedSide else { return false }
        hideDropPreview()
        onDropTab?(tabID, side)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        hideDropPreview()
    }

    private func updateDropPreview(_ info: NSDraggingInfo) -> NSDragOperation {
        guard let value = info.draggingPasteboard.string(forType: explorerTabPasteboardType),
              let tabID = UUID(uuidString: value) else {
            hideDropPreview()
            return []
        }

        let point = convert(info.draggingLocation, from: nil)
        let side: ExplorerPaneSide = point.x < bounds.midX ? .left : .right
        guard canAcceptTab?(tabID, side) == true else {
            hideDropPreview()
            return []
        }

        targetedTabID = tabID
        targetedSide = side
        addSubview(preview, positioned: .above, relativeTo: nil)
        let inset: CGFloat = 8
        preview.frame = NSRect(
            x: side == .left ? inset : bounds.midX + inset / 2,
            y: inset,
            width: max(0, bounds.width / 2 - inset * 1.5),
            height: max(0, bounds.height - inset * 2)
        )
        preview.isHidden = false
        return .move
    }

    private func hideDropPreview() {
        targetedTabID = nil
        targetedSide = nil
        preview.isHidden = true
    }
}

private final class ExplorerTab {
    let id: UUID
    let browser: MainViewController
    private var storedPaneHost: ExplorerPaneHostView?

    init(id: UUID = UUID(), browser: MainViewController) {
        self.id = id
        self.browser = browser
    }

    var paneHost: ExplorerPaneHostView {
        if let storedPaneHost { return storedPaneHost }
        let host = ExplorerPaneHostView(browser: browser)
        storedPaneHost = host
        return host
    }

    func removePaneHostFromHierarchy() {
        storedPaneHost?.removeFromSuperview()
    }
}

final class ExplorerWindowViewController: NSViewController,
    ExplorerTabBarViewDelegate,
    MainViewControllerDelegate {

    private let tabBar = ExplorerTabBarView()
    private let contentHost = ExplorerSplitDropHostView()
    private let paneSplitView = NSSplitView()
    private var tabs: [ExplorerTab] = []
    private var selectedIndex = 0
    private var leftTabID: UUID?
    private var rightTabID: UUID?
    private var activePane: ExplorerPaneSide = .left
    private var paneClickMonitor: Any?
    private var contentBelowTabConstraint: NSLayoutConstraint?
    private var contentBelowTitlebarConstraint: NSLayoutConstraint?
    private var sidebarVisible = true
    private var trafficLightAlignmentScheduled = false
    private var trafficLightConstraints: [NSLayoutConstraint] = []
    private var customTrafficLightButtons: [NSButton] = []

    private var currentTab: ExplorerTab? {
        tabs.indices.contains(selectedIndex) ? tabs[selectedIndex] : nil
    }

    private var leftTab: ExplorerTab? {
        guard let leftTabID else { return currentTab }
        return tab(withID: leftTabID)
    }

    private var rightTab: ExplorerTab? {
        guard let rightTabID else { return nil }
        return tab(withID: rightTabID)
    }

    private var visibleTabs: [ExplorerTab] {
        if let leftTab, let rightTab, leftTab !== rightTab { return [leftTab, rightTab] }
        if let currentTab { return [currentTab] }
        return []
    }

    var currentBrowser: MainViewController? {
        if let responderView = view.window?.firstResponder as? NSView,
           let focused = visibleTabs.first(where: {
               responderView === $0.browser.view || responderView.isDescendant(of: $0.browser.view)
           }) {
            activateTab(focused, updateInterface: false)
        }
        return currentTab?.browser
    }

    var isCurrentTabSplit: Bool { rightTab != nil }

    func otherBrowser(than browser: MainViewController) -> MainViewController? {
        guard isCurrentTabSplit else { return nil }
        return visibleTabs.first { $0.browser !== browser }?.browser
    }

    init(initialURL: URL? = nil) {
        super.init(nibName: nil, bundle: nil)
        addBrowser(initialURL: initialURL, select: true)
    }

    private init(detachedTab: ExplorerTab) {
        super.init(nibName: nil, bundle: nil)
        tabs = [detachedTab]
        selectedIndex = 0
        leftTabID = detachedTab.id
        detachedTab.browser.browserDelegate = self
        addChild(detachedTab.browser)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let paneClickMonitor { NSEvent.removeMonitor(paneClickMonitor) }
    }

    override func loadView() {
        let root = NSView()
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.delegate = self
        // Keep the first tab clear of the three window controls.
        tabBar.leadingInset = 82

        contentHost.translatesAutoresizingMaskIntoConstraints = false
        contentHost.canAcceptTab = { [weak self] tabID, side in
            self?.canDisplayTab(tabID, on: side) == true
        }
        contentHost.onDropTab = { [weak self] tabID, side in
            self?.displayDraggedTab(tabID, on: side)
        }

        paneSplitView.translatesAutoresizingMaskIntoConstraints = false
        paneSplitView.isVertical = true
        paneSplitView.dividerStyle = .thin
        contentHost.addSubview(paneSplitView)
        root.addSubview(tabBar)
        root.addSubview(contentHost)

        let tabHeight = tabBar.heightAnchor.constraint(equalToConstant: 46)
        let belowTab = contentHost.topAnchor.constraint(equalTo: tabBar.bottomAnchor)
        let belowTitlebar = contentHost.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor)
        contentBelowTabConstraint = belowTab
        contentBelowTitlebarConstraint = belowTitlebar
        NSLayoutConstraint.activate([
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabBar.topAnchor.constraint(equalTo: root.topAnchor),
            tabHeight,
            contentHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            belowTab,
            contentHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            paneSplitView.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            paneSplitView.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            paneSplitView.topAnchor.constraint(equalTo: contentHost.topAnchor),
            paneSplitView.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor)
        ])
        view = root
        showVisibleTabs()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.title = currentBrowser?.locationTitle ?? "Mac Explorer"
        updateWindowMinimumSize()
        installPaneClickMonitorIfNeeded()
        scheduleTrafficLightAlignment()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        tabBar.availableWindowWidth = view.bounds.width
        scheduleTrafficLightAlignment()
    }

    func addTab(at url: URL? = nil) {
        let tab = addBrowser(initialURL: url, select: false)
        selectTab(tab)
    }

    func closeCurrentTab() {
        closeTab(at: selectedIndex)
    }

    @discardableResult
    func reopenClosedTab() -> Bool {
        guard let closedTab = RecentlyClosedTabStore.shared.popLast() else { return false }

        let companion = currentTab
        let reopened = addBrowser(initialLocation: closedTab.location)
        if let splitContext = closedTab.splitContext,
           !isCurrentTabSplit,
           let companion,
           companion.browser.currentLocation == splitContext.companionLocation {
            switch splitContext.closedSide {
            case .left:
                leftTabID = reopened.id
                rightTabID = companion.id
                activePane = .left
            case .right:
                leftTabID = companion.id
                rightTabID = reopened.id
                activePane = .right
            }
            selectedIndex = tabs.firstIndex(where: { $0.id == reopened.id }) ?? selectedIndex
            showVisibleTabs(equalizeDivider: true)
        } else {
            selectTab(reopened)
        }
        return true
    }

    func selectAdjacentTab(direction: Int) {
        guard tabs.count > 1 else { return }
        let index = (selectedIndex + direction + tabs.count) % tabs.count
        selectTab(tabs[index])
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectTab(tabs[index])
    }

    func toggleTabBar() {
        tabBar.isHidden.toggle()
        if tabBar.isHidden {
            contentBelowTabConstraint?.isActive = false
            contentBelowTitlebarConstraint?.isActive = true
        } else {
            contentBelowTitlebarConstraint?.isActive = false
            contentBelowTabConstraint?.isActive = true
        }
        scheduleTrafficLightAlignment()
    }

    func toggleSplitView() {
        guard let active = currentTab else { return }
        if isCurrentTabSplit {
            leftTabID = active.id
            rightTabID = nil
            activePane = .left
            showVisibleTabs()
            return
        }

        let duplicate = addBrowser(initialLocation: active.browser.currentLocation)
        leftTabID = active.id
        rightTabID = duplicate.id
        activePane = .right
        selectedIndex = tabs.firstIndex(where: { $0.id == duplicate.id }) ?? selectedIndex
        showVisibleTabs(equalizeDivider: true)
    }

    func open(url: URL, inOtherPaneFrom browser: MainViewController) {
        guard let sourceTab = tab(containing: browser) else { return }
        activateTab(sourceTab, updateInterface: false)
        if !isCurrentTabSplit { toggleSplitView() }
        otherBrowser(than: browser)?.navigate(to: url)
    }

    func toggleSidebarVisibility() {
        sidebarVisible.toggle()
        applySidebarVisibility()
    }

    @discardableResult
    private func addBrowser(initialURL: URL?, select: Bool) -> ExplorerTab {
        let browser = MainViewController(initialURL: initialURL)
        let tab = installBrowser(browser)
        if select {
            selectedIndex = tabs.count - 1
            leftTabID = tab.id
            rightTabID = nil
            activePane = .left
        }
        if isViewLoaded { updateTabs() }
        return tab
    }

    @discardableResult
    private func addBrowser(initialLocation: BrowserLocation) -> ExplorerTab {
        installBrowser(MainViewController(initialLocation: initialLocation))
    }

    @discardableResult
    private func installBrowser(_ browser: MainViewController) -> ExplorerTab {
        browser.browserDelegate = self
        let tab = ExplorerTab(browser: browser)
        tabs.append(tab)
        if browser.parent !== self { addChild(browser) }
        return tab
    }

    private func tab(withID id: UUID) -> ExplorerTab? {
        tabs.first { $0.id == id }
    }

    private func tab(containing browser: MainViewController) -> ExplorerTab? {
        tabs.first { $0.browser === browser }
    }

    private func side(for tab: ExplorerTab) -> ExplorerPaneSide? {
        if leftTabID == tab.id { return .left }
        if rightTabID == tab.id { return .right }
        return nil
    }

    private func activateTab(_ tab: ExplorerTab, updateInterface: Bool) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        selectedIndex = index
        if let visibleSide = side(for: tab) { activePane = visibleSide }
        if updateInterface {
            view.window?.title = tab.browser.locationTitle
            updatePaneAppearance()
            updateTabs()
        }
    }

    private func selectTab(_ tab: ExplorerTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        selectedIndex = index
        if isCurrentTabSplit {
            if let visibleSide = side(for: tab) {
                activePane = visibleSide
            } else if activePane == .left {
                leftTabID = tab.id
            } else {
                rightTabID = tab.id
            }
        } else {
            leftTabID = tab.id
            activePane = .left
        }
        showVisibleTabs()
    }

    private func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        let removedTab = tabs[index]
        RecentlyClosedTabStore.shared.record(closedTabSnapshot(for: removedTab))

        if tabs.count == 1 {
            view.window?.performClose(nil)
            return
        }

        let previouslyActiveID = currentTab?.id
        let wasLeft = leftTabID == removedTab.id
        let wasRight = rightTabID == removedTab.id
        let survivingVisibleID: UUID? = wasLeft ? rightTabID : (wasRight ? leftTabID : nil)
        discard(tab: removedTab)
        tabs.remove(at: index)

        if let survivingVisibleID, tab(withID: survivingVisibleID) != nil {
            leftTabID = survivingVisibleID
            rightTabID = nil
            activePane = .left
            selectedIndex = tabs.firstIndex(where: { $0.id == survivingVisibleID }) ?? 0
        } else {
            if let previouslyActiveID,
               let activeIndex = tabs.firstIndex(where: { $0.id == previouslyActiveID }) {
                selectedIndex = activeIndex
            } else {
                selectedIndex = min(index, tabs.count - 1)
            }
            if !isCurrentTabSplit { leftTabID = currentTab?.id }
        }
        showVisibleTabs()
    }

    private func closedTabSnapshot(for tab: ExplorerTab) -> ClosedExplorerTab {
        let splitContext: ClosedExplorerSplitContext?
        if leftTabID == tab.id, let rightTab {
            splitContext = ClosedExplorerSplitContext(
                closedSide: .left,
                companionLocation: rightTab.browser.currentLocation
            )
        } else if rightTabID == tab.id, let leftTab {
            splitContext = ClosedExplorerSplitContext(
                closedSide: .right,
                companionLocation: leftTab.browser.currentLocation
            )
        } else {
            splitContext = nil
        }
        return ClosedExplorerTab(location: tab.browser.currentLocation, splitContext: splitContext)
    }

    private func discard(tab: ExplorerTab) {
        tab.removePaneHostFromHierarchy()
        tab.browser.view.removeFromSuperview()
        tab.browser.removeFromParent()
    }

    private func showVisibleTabs(equalizeDivider: Bool = false) {
        guard isViewLoaded, let active = currentTab else { return }
        normalizeVisibleTabs(around: active)
        mountVisibleTabs()
        view.window?.title = active.browser.locationTitle
        updateWindowMinimumSize()
        applySidebarVisibility()
        updatePaneAppearance()
        updateTabs()

        if isCurrentTabSplit && equalizeDivider {
            view.layoutSubtreeIfNeeded()
            if paneSplitView.bounds.width > 0 {
                paneSplitView.setPosition(paneSplitView.bounds.width / 2, ofDividerAt: 0)
            }
        }
    }

    private func normalizeVisibleTabs(around active: ExplorerTab) {
        if rightTabID == nil {
            leftTabID = active.id
            activePane = .left
            return
        }
        if leftTab == nil || rightTab == nil || leftTabID == rightTabID {
            leftTabID = active.id
            rightTabID = nil
            activePane = .left
        }
    }

    private func mountVisibleTabs() {
        let desiredHosts = visibleTabs.map(\.paneHost)
        let visibleTabIDs = Set(visibleTabs.map(\.id))
        for tab in tabs {
            tab.browser.setBrowserPaneVisible(visibleTabIDs.contains(tab.id))
        }
        let mountedHosts = paneSplitView.arrangedSubviews
        if desiredHosts.count == mountedHosts.count,
           !zip(desiredHosts, mountedHosts).contains(where: { $0.0 !== $0.1 }) {
            return
        }

        mountedHosts.forEach { host in
            paneSplitView.removeArrangedSubview(host)
            host.removeFromSuperview()
        }
        visibleTabs.forEach { tab in
            if tab.browser.parent !== self { addChild(tab.browser) }
            tab.paneHost.onActivate = { [weak self, weak tab] in
                guard let self, let tab else { return }
                self.activateTab(tab, updateInterface: true)
            }
            paneSplitView.addArrangedSubview(tab.paneHost)
        }
        if isCurrentTabSplit {
            paneSplitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
            paneSplitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        }
    }

    private func updatePaneAppearance() {
        let isSplit = isCurrentTabSplit
        visibleTabs.forEach { tab in
            let isActive = tab.id == currentTab?.id
            tab.browser.setSplitPaneAppearance(isActive: isActive, isSplit: isSplit)
            tab.paneHost.update(isActive: isActive, isSplit: isSplit)
        }
    }

    private func applySidebarVisibility() {
        guard let leftTab else { return }
        leftTab.browser.setSidebarVisible(sidebarVisible)
        rightTab?.browser.setSidebarVisible(false)
    }

    private func updateWindowMinimumSize() {
        guard let window = view.window else { return }
        window.minSize = NSSize(width: isCurrentTabSplit ? 400 : 320, height: window.minSize.height)
    }

    private func scheduleTrafficLightAlignment() {
        guard !trafficLightAlignmentScheduled else { return }
        trafficLightAlignmentScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.trafficLightAlignmentScheduled = false
            self.alignTrafficLights()
            // AppKit can perform one more titlebar layout pass after content layout.
            // Reapply once after that pass so the buttons remain centered while resizing.
            DispatchQueue.main.async { [weak self] in self?.alignTrafficLights() }
        }
    }

    private func alignTrafficLights() {
        guard let window = view.window else { return }
        let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        if tabBar.isHidden {
            removeCustomTrafficLightButtons()
            kinds.forEach { window.standardWindowButton($0)?.isHidden = false }
            return
        }
        kinds.forEach { window.standardWindowButton($0)?.isHidden = true }
        if customTrafficLightButtons.count == kinds.count {
            return
        }
        removeCustomTrafficLightButtons()

        for (index, kind) in kinds.enumerated() {
            guard let button = NSWindow.standardWindowButton(kind, for: window.styleMask) else { continue }
            button.translatesAutoresizingMaskIntoConstraints = false
            switch kind {
            case .closeButton: button.action = #selector(NSWindow.performClose(_:))
            case .miniaturizeButton: button.action = #selector(NSWindow.performMiniaturize(_:))
            // performZoom(_:) asks AppKit to click the window's native zoom
            // button. This is a detached replacement button, so that indirection
            // can be a no-op. Invoke the actual zoom state transition instead.
            case .zoomButton: button.action = #selector(NSWindow.zoom(_:))
            default: break
            }
            button.target = window
            tabBar.addSubview(button, positioned: .above, relativeTo: nil)
            customTrafficLightButtons.append(button)
            let leading = button.leadingAnchor.constraint(
                equalTo: tabBar.leadingAnchor,
                constant: 12 + CGFloat(index) * 20
            )
            let centered = button.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor)
            trafficLightConstraints.append(contentsOf: [leading, centered])
            button.needsDisplay = true
        }
        NSLayoutConstraint.activate(trafficLightConstraints)
    }

    private func removeCustomTrafficLightButtons() {
        trafficLightConstraints.forEach { $0.isActive = false }
        trafficLightConstraints.removeAll(keepingCapacity: true)
        customTrafficLightButtons.forEach { $0.removeFromSuperview() }
        customTrafficLightButtons.removeAll(keepingCapacity: true)
    }

    private func installPaneClickMonitorIfNeeded() {
        guard paneClickMonitor == nil else { return }
        paneClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self, event.window === self.view.window else { return event }
            guard let tab = self.visibleTabs.first(where: {
                !$0.browser.view.isHidden && $0.browser.view.bounds.contains(
                    $0.browser.view.convert(event.locationInWindow, from: nil)
                )
            }) else { return event }

            if tab.id != self.currentTab?.id {
                self.activateTab(tab, updateInterface: false)
                DispatchQueue.main.async { [weak self, weak tab] in
                    guard let self, let tab, self.visibleTabs.contains(where: { $0 === tab }) else { return }
                    self.view.window?.title = tab.browser.locationTitle
                    self.updatePaneAppearance()
                    self.updateTabs()
                }
            }
            if tab.browser.handleNavigationMouseDown(event) { return nil }
            return event
        }
    }

    private func updateTabs() {
        tabBar.update(
            items: tabs.map {
                ExplorerTabBarItem(
                    id: $0.id,
                    title: $0.browser.locationTitle,
                    locationDescription: $0.browser.currentLocation.addressDescription
                )
            },
            activeTabID: currentTab?.id,
            visibleTabIDs: Set(visibleTabs.map(\.id))
        )
    }

    private func canDisplayTab(_ tabID: UUID, on side: ExplorerPaneSide) -> Bool {
        guard let source = sourceController(containing: tabID),
              source.tab(withID: tabID) != nil else { return false }
        if source === self, !isCurrentTabSplit, currentTab?.id == tabID {
            return tabs.contains { $0.id != tabID }
        }
        if isCurrentTabSplit {
            let targetID = side == .left ? leftTabID : rightTabID
            return targetID != tabID || activePane != side
        }
        return true
    }

    private func displayDraggedTab(_ tabID: UUID, on side: ExplorerPaneSide) {
        guard let source = sourceController(containing: tabID) else { return }
        let movingTab: ExplorerTab
        if source === self {
            guard let localTab = tab(withID: tabID) else { return }
            movingTab = localTab
        } else {
            guard let transferred = source.removeTabForTransfer(tabID: tabID) else { return }
            transferred.browser.browserDelegate = self
            if transferred.browser.parent !== self { addChild(transferred.browser) }
            tabs.append(transferred)
            movingTab = transferred
        }

        if isCurrentTabSplit {
            let oldLeft = leftTabID
            let oldRight = rightTabID
            if side == .left {
                leftTabID = movingTab.id
                if oldRight == movingTab.id { rightTabID = oldLeft }
            } else {
                rightTabID = movingTab.id
                if oldLeft == movingTab.id { leftTabID = oldRight }
            }
        } else if let active = currentTab {
            if movingTab.id == active.id {
                guard let companion = tabs.first(where: { $0.id != movingTab.id }) else { return }
                leftTabID = side == .left ? movingTab.id : companion.id
                rightTabID = side == .right ? movingTab.id : companion.id
            } else {
                leftTabID = side == .left ? movingTab.id : active.id
                rightTabID = side == .right ? movingTab.id : active.id
            }
        }

        activePane = side
        selectedIndex = tabs.firstIndex(where: { $0.id == movingTab.id }) ?? selectedIndex
        showVisibleTabs(equalizeDivider: true)
    }

    private func sourceController(containing tabID: UUID) -> ExplorerWindowViewController? {
        NSApp.windows.compactMap {
            $0.contentViewController as? ExplorerWindowViewController
        }.first { controller in
            controller.tabs.contains { $0.id == tabID }
        }
    }

    func tabBar(_ tabBar: ExplorerTabBarView, didSelect index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectTab(tabs[index])
    }

    func tabBar(_ tabBar: ExplorerTabBarView, didRequestClose index: Int) {
        closeTab(at: index)
    }

    func tabBar(_ tabBar: ExplorerTabBarView, didRequestMove tabID: UUID, to insertionIndex: Int) {
        guard let source = sourceController(containing: tabID) else { return }
        if source === self {
            guard let sourceIndex = tabs.firstIndex(where: { $0.id == tabID }) else { return }
            let activeID = currentTab?.id
            let movingTab = tabs.remove(at: sourceIndex)
            var targetIndex = min(max(0, insertionIndex), tabs.count + 1)
            if sourceIndex < targetIndex { targetIndex -= 1 }
            targetIndex = min(max(0, targetIndex), tabs.count)
            tabs.insert(movingTab, at: targetIndex)
            if let activeID { selectedIndex = tabs.firstIndex(where: { $0.id == activeID }) ?? targetIndex }
            updateTabs()
            return
        }

        guard let movingTab = source.removeTabForTransfer(tabID: tabID) else { return }
        movingTab.browser.browserDelegate = self
        if movingTab.browser.parent !== self { addChild(movingTab.browser) }
        let targetIndex = min(max(0, insertionIndex), tabs.count)
        tabs.insert(movingTab, at: targetIndex)
        selectTab(movingTab)
    }

    func tabBar(
        _ tabBar: ExplorerTabBarView,
        didFinishDragging tabID: UUID,
        at screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        guard operation.isEmpty,
              tabs.contains(where: { $0.id == tabID }),
              tabs.count > 1,
              let sourceWindow = view.window,
              !sourceWindow.frame.contains(screenPoint),
              let appDelegate = NSApp.delegate as? AppDelegate,
              let detachedTab = removeTabForTransfer(tabID: tabID) else { return }

        let detachedBrowser = ExplorerWindowViewController(detachedTab: detachedTab)
        appDelegate.createWindow(with: detachedBrowser, near: screenPoint)
    }

    private func removeTabForTransfer(tabID: UUID) -> ExplorerTab? {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return nil }
        let removedTab = tabs[index]
        let wasLeft = leftTabID == tabID
        let wasRight = rightTabID == tabID
        let survivorID: UUID? = wasLeft ? rightTabID : (wasRight ? leftTabID : currentTab?.id)

        removedTab.removePaneHostFromHierarchy()
        removedTab.browser.removeFromParent()
        tabs.remove(at: index)

        if tabs.isEmpty {
            selectedIndex = 0
            leftTabID = nil
            rightTabID = nil
            updateTabs()
            let sourceWindow = view.window
            DispatchQueue.main.async { sourceWindow?.performClose(nil) }
        } else {
            let fallbackID = survivorID.flatMap { tab(withID: $0)?.id } ?? tabs[min(index, tabs.count - 1)].id
            selectedIndex = tabs.firstIndex(where: { $0.id == fallbackID }) ?? 0
            if wasLeft || wasRight {
                leftTabID = fallbackID
                rightTabID = nil
                activePane = .left
            } else if !isCurrentTabSplit {
                leftTabID = fallbackID
            }
            showVisibleTabs()
        }
        return removedTab
    }

    func tabBarDidRequestNewTab(_ tabBar: ExplorerTabBarView) {
        addTab()
    }

    func browserDidBecomeActive(_ browser: MainViewController) {
        guard let tab = tab(containing: browser), visibleTabs.contains(where: { $0 === tab }) else { return }
        guard currentTab !== tab else { return }
        activateTab(tab, updateInterface: true)
    }

    func browser(_ browser: MainViewController, didChangeTitle title: String) {
        if currentTab?.browser === browser { view.window?.title = title }
        updateTabs()
    }
}
