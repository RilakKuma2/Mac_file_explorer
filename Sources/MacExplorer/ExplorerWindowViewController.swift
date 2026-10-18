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

        // A pane's outer width must not inherit the combined fitting widths of
        // its toolbar, sidebar and file columns. They adapt/scroll inside it.
        browser.view.translatesAutoresizingMaskIntoConstraints = true
        browser.view.autoresizingMask = [.width, .height]
        addSubview(browser.view)
        browser.view.frame = bounds

    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        browser.view.frame = bounds
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

/// Stable split-view children keep the divider position when a pane changes tabs.
private final class ExplorerPaneSlotView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true
        let minimum = widthAnchor.constraint(greaterThanOrEqualToConstant: 160)
        minimum.priority = .defaultHigh
        minimum.isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        for child in subviews { child.frame = bounds }
    }
}

private final class ExplorerSplitDropHostView: NSView {
    var canAcceptTab: ((UUID, ExplorerPaneSide) -> Bool)?
    var onDropTab: ((UUID, ExplorerPaneSide) -> Void)?
    var dividerPosition: (() -> CGFloat)?

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
        let divider = dividerPosition?() ?? bounds.midX
        let side: ExplorerPaneSide = point.x < divider ? .left : .right
        guard canAcceptTab?(tabID, side) == true else {
            hideDropPreview()
            return []
        }

        targetedTabID = tabID
        targetedSide = side
        addSubview(preview, positioned: .above, relativeTo: nil)
        let inset: CGFloat = 8
        preview.frame = NSRect(
            x: side == .left ? inset : divider + inset / 2,
            y: inset,
            width: max(0, (side == .left ? divider : bounds.width - divider) - inset * 1.5),
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
    var paneSide: ExplorerPaneSide = .left
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
    MainViewControllerDelegate,
    NSSplitViewDelegate {

    private let tabBar = ExplorerTabBarView()
    private let rightTabBar = ExplorerTabBarView()
    private let tabHeader = NSView()
    private let contentHost = ExplorerSplitDropHostView()
    private let paneSplitView = NSSplitView()
    private let leftPaneSlot = ExplorerPaneSlotView()
    private let rightPaneSlot = ExplorerPaneSlotView()
    private var tabs: [ExplorerTab] = []
    private var selectedIndex = 0
    private var leftTabID: UUID?
    private var rightTabID: UUID?
    private var activePane: ExplorerPaneSide = .left
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

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1120, height: 720))
        tabHeader.translatesAutoresizingMaskIntoConstraints = false
        tabBar.delegate = self
        rightTabBar.delegate = self
        tabBar.identifier = NSUserInterfaceItemIdentifier("leftPaneTabs")
        rightTabBar.identifier = NSUserInterfaceItemIdentifier("rightPaneTabs")
        // Keep the first tab clear of the three window controls.
        tabBar.leadingInset = 82
        rightTabBar.leadingInset = 8
        tabHeader.addSubview(tabBar)
        tabHeader.addSubview(rightTabBar)

        contentHost.translatesAutoresizingMaskIntoConstraints = false
        contentHost.canAcceptTab = { [weak self] tabID, side in
            self?.canDisplayTab(tabID, on: side) == true
        }
        contentHost.onDropTab = { [weak self] tabID, side in
            self?.displayDraggedTab(tabID, on: side)
        }
        contentHost.dividerPosition = { [weak self] in
            guard let self, self.isCurrentTabSplit else { return self?.contentHost.bounds.midX ?? 0 }
            return self.paneSplitView.arrangedSubviews.first?.frame.maxX ?? self.contentHost.bounds.midX
        }

        paneSplitView.translatesAutoresizingMaskIntoConstraints = false
        paneSplitView.isVertical = true
        paneSplitView.dividerStyle = .thin
        paneSplitView.delegate = self
        paneSplitView.identifier = NSUserInterfaceItemIdentifier("browserPaneSplit")
        contentHost.addSubview(paneSplitView)
        root.addSubview(tabHeader)
        root.addSubview(contentHost)

        let tabHeight = tabHeader.heightAnchor.constraint(equalToConstant: 46)
        let belowTab = contentHost.topAnchor.constraint(equalTo: tabHeader.bottomAnchor)
        let belowTitlebar = contentHost.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor)
        contentBelowTabConstraint = belowTab
        contentBelowTitlebarConstraint = belowTitlebar
        NSLayoutConstraint.activate([
            tabHeader.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabHeader.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabHeader.topAnchor.constraint(equalTo: root.topAnchor),
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
        scheduleTrafficLightAlignment()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutTabBars()
        scheduleTrafficLightAlignment()
    }

    private func layoutTabBars() {
        let width = tabHeader.bounds.width
        let leftWidth = isCurrentTabSplit
            ? (paneSplitView.arrangedSubviews.first?.frame.width ?? width / 2) : width
        tabBar.frame = NSRect(x: 0, y: 0, width: leftWidth, height: tabHeader.bounds.height)
        tabBar.availableWindowWidth = leftWidth
        rightTabBar.isHidden = !isCurrentTabSplit
        let rightX = leftWidth + paneSplitView.dividerThickness
        rightTabBar.frame = NSRect(x: rightX, y: 0, width: max(0, width - rightX), height: tabHeader.bounds.height)
        rightTabBar.availableWindowWidth = rightTabBar.bounds.width
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard notification.object as? NSSplitView === paneSplitView else { return }
        layoutTabBars()
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, min(160, splitView.bounds.width / 2))
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, max(0, splitView.bounds.width - 160 - splitView.dividerThickness))
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
        if isCurrentTabSplit, let context = closedTab.splitContext {
            reopened.paneSide = context.closedSide == .left ? .left : .right
        }
        if let splitContext = closedTab.splitContext,
           !isCurrentTabSplit,
           let companion,
           companion.browser.currentLocation == splitContext.companionLocation {
            switch splitContext.closedSide {
            case .left:
                reopened.paneSide = .left
                companion.paneSide = .right
                leftTabID = reopened.id
                rightTabID = companion.id
                activePane = .left
            case .right:
                companion.paneSide = .left
                reopened.paneSide = .right
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
        let group = tabs(on: activePane)
        guard group.count > 1, let index = group.firstIndex(where: { $0 === currentTab }) else { return }
        selectTab(group[(index + direction + group.count) % group.count])
    }

    func selectTab(at index: Int) {
        let group = tabs(on: activePane)
        guard group.indices.contains(index) else { return }
        selectTab(group[index])
    }

    func toggleTabBar() {
        tabHeader.isHidden.toggle()
        if tabHeader.isHidden {
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
            tabs.forEach { $0.paneSide = .left }
            showVisibleTabs()
            return
        }

        let duplicate = addBrowser(initialLocation: active.browser.currentLocation)
        duplicate.paneSide = .right
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
        tab.paneSide = isCurrentTabSplit ? activePane : .left
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

    private func tabs(on side: ExplorerPaneSide) -> [ExplorerTab] {
        isCurrentTabSplit ? tabs.filter { $0.paneSide == side } : (side == .left ? tabs : [])
    }

    private func side(for bar: ExplorerTabBarView) -> ExplorerPaneSide {
        bar === rightTabBar ? .right : .left
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
            activePane = tab.paneSide
            if activePane == .left {
                leftTabID = tab.id
            } else {
                rightTabID = tab.id
            }
        } else {
            tab.paneSide = .left
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

        discard(tab: removedTab)
        removeTabFromModel(at: index)
        showVisibleTabs()
    }

    private func removeTabFromModel(at index: Int) {
        let removed = tabs[index]
        let wasSplit = isCurrentTabSplit
        let wasVisible = side(for: removed) != nil
        let activeID = currentTab?.id
        tabs.remove(at: index)
        guard !tabs.isEmpty else {
            selectedIndex = 0
            leftTabID = nil
            rightTabID = nil
            return
        }
        var nextActiveID = activeID == removed.id ? nil : activeID
        if wasSplit && wasVisible {
            if let replacement = tabs.first(where: { $0.paneSide == removed.paneSide }) {
                if removed.paneSide == .left { leftTabID = replacement.id }
                else { rightTabID = replacement.id }
                if nextActiveID == nil { nextActiveID = replacement.id }
            } else {
                let survivorID = removed.paneSide == .left ? rightTabID : leftTabID
                leftTabID = survivorID
                rightTabID = nil
                activePane = .left
                tabs.forEach { $0.paneSide = .left }
                nextActiveID = survivorID
            }
        }
        selectedIndex = nextActiveID.flatMap { id in tabs.firstIndex { $0.id == id } } ?? min(index, tabs.count - 1)
        if rightTabID == nil { leftTabID = currentTab?.id }
        activePane = currentTab?.paneSide ?? .left
    }

    private func closedTabSnapshot(for tab: ExplorerTab) -> ClosedExplorerTab {
        let splitContext: ClosedExplorerSplitContext?
        if tab.paneSide == .left, let rightTab {
            splitContext = ClosedExplorerSplitContext(
                closedSide: .left,
                companionLocation: rightTab.browser.currentLocation
            )
        } else if isCurrentTabSplit, tab.paneSide == .right, let leftTab {
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
        layoutTabBars()
        active.browser.focusBrowserContent()
    }

    private func normalizeVisibleTabs(around active: ExplorerTab) {
        if rightTabID == nil {
            tabs.forEach { $0.paneSide = .left }
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
        let slots = isCurrentTabSplit ? [leftPaneSlot, rightPaneSlot] : [leftPaneSlot]
        let visibleTabIDs = Set(visibleTabs.map(\.id))
        for tab in tabs {
            tab.browser.setBrowserPaneVisible(visibleTabIDs.contains(tab.id))
        }
        for slot in paneSplitView.arrangedSubviews where !slots.contains(where: { $0 === slot }) {
            slot.subviews.forEach { $0.removeFromSuperview() }
            paneSplitView.removeArrangedSubview(slot)
            slot.removeFromSuperview()
        }
        for (tab, slot) in zip(visibleTabs, slots) {
            if slot.superview !== paneSplitView { paneSplitView.addArrangedSubview(slot) }
            if tab.browser.parent !== self { addChild(tab.browser) }
            tab.paneHost.onActivate = { [weak self, weak tab] in
                guard let self, let tab else { return }
                self.activateTab(tab, updateInterface: true)
            }
            let host = tab.paneHost
            if host.superview !== slot {
                slot.subviews.forEach { $0.removeFromSuperview() }
                host.translatesAutoresizingMaskIntoConstraints = true
                host.autoresizingMask = [.width, .height]
                slot.addSubview(host)
                host.frame = slot.bounds
            }
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
        if tabHeader.isHidden {
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

    /// Run at window dispatch, after AppKit's event monitors and menu routing.
    /// A monitor that consumes just mouse-down leaves native controls with an
    /// unmatched mouse-up and can start navigation inside another tracking loop.
    func handlePaneMouseDown(_ event: NSEvent) -> Bool {
        guard [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type),
              event.window === view.window,
              let tab = visibleTabs.first(where: {
                  !$0.browser.view.isHiddenOrHasHiddenAncestor && $0.browser.view.bounds.contains(
                      $0.browser.view.convert(event.locationInWindow, from: nil)
                  )
              }) else { return false }

        if tab.id != currentTab?.id {
            activateTab(tab, updateInterface: false)
            DispatchQueue.main.async { [weak self, weak tab] in
                guard let self, let tab, self.visibleTabs.contains(where: { $0 === tab }) else { return }
                self.view.window?.title = self.currentTab?.browser.locationTitle ?? "Mac Explorer"
                self.updatePaneAppearance()
                self.updateTabs()
            }
        }
        return tab.browser.handleNavigationMouseDown(event)
    }

    private func updateTabs() {
        for (side, bar) in [(ExplorerPaneSide.left, tabBar), (.right, rightTabBar)] {
            bar.update(
                items: tabs(on: side).map {
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
            assign(movingTab, to: side)
        } else if let active = currentTab {
            if movingTab.id == active.id {
                guard let companion = tabs.first(where: { $0.id != movingTab.id }) else { return }
                leftTabID = side == .left ? movingTab.id : companion.id
                rightTabID = side == .right ? movingTab.id : companion.id
                companion.paneSide = side == .left ? .right : .left
            } else {
                leftTabID = side == .left ? movingTab.id : active.id
                rightTabID = side == .right ? movingTab.id : active.id
                active.paneSide = side == .left ? .right : .left
            }
            movingTab.paneSide = side
        }

        activePane = side
        selectedIndex = tabs.firstIndex(where: { $0.id == movingTab.id }) ?? selectedIndex
        showVisibleTabs(equalizeDivider: true)
    }

    private func sourceController(containing tabID: UUID) -> ExplorerWindowViewController? {
        if tabs.contains(where: { $0.id == tabID }) { return self }
        return NSApp.windows.compactMap {
            $0.contentViewController as? ExplorerWindowViewController
        }.first { controller in
            controller.tabs.contains { $0.id == tabID }
        }
    }

    func tabBar(_ tabBar: ExplorerTabBarView, didSelect index: Int) {
        let group = tabs(on: side(for: tabBar))
        guard group.indices.contains(index) else { return }
        selectTab(group[index])
    }

    func tabBar(_ tabBar: ExplorerTabBarView, didRequestClose index: Int) {
        let group = tabs(on: side(for: tabBar))
        guard group.indices.contains(index), let globalIndex = tabs.firstIndex(where: { $0 === group[index] }) else { return }
        closeTab(at: globalIndex)
    }

    private func assign(_ movingTab: ExplorerTab, to destinationSide: ExplorerPaneSide) {
        // Keep both panes usable when the last visible tab crosses sides: swap
        // with the destination's visible tab if the source has no replacement.
        if let sourceSide = side(for: movingTab), sourceSide != destinationSide {
            let replacement = tabs.first { $0 !== movingTab && $0.paneSide == sourceSide }
                ?? (destinationSide == .left ? leftTab : rightTab)
            replacement?.paneSide = sourceSide
            if sourceSide == .left { leftTabID = replacement?.id }
            else { rightTabID = replacement?.id }
        }
        movingTab.paneSide = destinationSide
        if destinationSide == .left { leftTabID = movingTab.id }
        else { rightTabID = movingTab.id }
    }

    func tabBar(_ tabBar: ExplorerTabBarView, didRequestMove tabID: UUID, to insertionIndex: Int) {
        guard let source = sourceController(containing: tabID) else { return }
        let destinationSide = side(for: tabBar)
        let destinationGroup = tabs(on: destinationSide)
        var groupIndex = min(max(0, insertionIndex), destinationGroup.count)
        if let oldIndex = destinationGroup.firstIndex(where: { $0.id == tabID }), oldIndex < groupIndex {
            groupIndex -= 1
        }
        let remainingGroup = destinationGroup.filter { $0.id != tabID }
        if source === self {
            guard let sourceIndex = tabs.firstIndex(where: { $0.id == tabID }) else { return }
            let activeID = currentTab?.id
            let movingTab = tabs[sourceIndex]
            let changesPane = isCurrentTabSplit && movingTab.paneSide != destinationSide
            if changesPane { assign(movingTab, to: destinationSide) }
            tabs.remove(at: sourceIndex)
            let targetIndex = insertionIndexInAllTabs(group: remainingGroup, index: groupIndex)
            tabs.insert(movingTab, at: targetIndex)
            if let activeID { selectedIndex = tabs.firstIndex(where: { $0.id == activeID }) ?? targetIndex }
            if changesPane { selectTab(movingTab) } else { updateTabs() }
            return
        }

        guard let movingTab = source.removeTabForTransfer(tabID: tabID) else { return }
        movingTab.browser.browserDelegate = self
        if movingTab.browser.parent !== self { addChild(movingTab.browser) }
        movingTab.paneSide = destinationSide
        let targetIndex = insertionIndexInAllTabs(group: remainingGroup, index: groupIndex)
        tabs.insert(movingTab, at: targetIndex)
        selectTab(movingTab)
    }

    private func insertionIndexInAllTabs(group: [ExplorerTab], index: Int) -> Int {
        if group.indices.contains(index), let next = tabs.firstIndex(where: { $0 === group[index] }) { return next }
        if let last = group.last, let previous = tabs.firstIndex(where: { $0 === last }) { return previous + 1 }
        return tabs.count
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
        removedTab.removePaneHostFromHierarchy()
        removedTab.browser.removeFromParent()
        removeTabFromModel(at: index)

        if tabs.isEmpty {
            selectedIndex = 0
            leftTabID = nil
            rightTabID = nil
            updateTabs()
            let sourceWindow = view.window
            DispatchQueue.main.async { sourceWindow?.performClose(nil) }
        } else {
            showVisibleTabs()
        }
        return removedTab
    }

    func tabBarDidRequestNewTab(_ tabBar: ExplorerTabBarView) {
        activePane = side(for: tabBar)
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
