import AppKit

struct ExplorerTabBarItem {
    let id: UUID
    let title: String
    let locationDescription: String

    init(id: UUID, title: String, locationDescription: String? = nil) {
        self.id = id
        self.title = title
        self.locationDescription = locationDescription?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? title
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

protocol ExplorerTabBarViewDelegate: AnyObject {
    func tabBar(_ tabBar: ExplorerTabBarView, didSelect index: Int)
    func tabBar(_ tabBar: ExplorerTabBarView, didRequestClose index: Int)
    func tabBar(_ tabBar: ExplorerTabBarView, didRequestMove tabID: UUID, to insertionIndex: Int)
    func tabBar(_ tabBar: ExplorerTabBarView, didFinishDragging tabID: UUID, at screenPoint: NSPoint, operation: NSDragOperation)
    func tabBarDidRequestNewTab(_ tabBar: ExplorerTabBarView)
}

let explorerTabPasteboardType = NSPasteboard.PasteboardType("app.macexplorer.tab")

private let explorerTabStripColor = NSColor(name: NSColor.Name("ExplorerTabStrip")) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0.145, green: 0.153, blue: 0.169, alpha: 1)
        : NSColor(srgbRed: 0.925, green: 0.937, blue: 0.953, alpha: 1)
}

private extension NSView {
    func dragSnapshot() -> NSImage {
        guard bounds.width > 0, bounds.height > 0,
              let representation = bitmapImageRepForCachingDisplay(in: bounds) else {
            return NSImage(size: NSSize(width: 240, height: 40))
        }
        cacheDisplay(in: bounds, to: representation)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(representation)
        return image
    }
}

private final class ExplorerTabButton: NSButton, NSDraggingSource {
    var tabIndex = 0
    var tabID = UUID()
    var onSelect: ((Int) -> Void)?
    var onDragEnded: ((UUID, NSPoint, NSDragOperation) -> Void)?
    var isSelectedTab = false

    override var acceptsFirstResponder: Bool { true }

    override func isAccessibilitySelected() -> Bool {
        isSelectedTab
    }

    override func accessibilityPerformPress() -> Bool {
        activateTab()
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              [36, 49, 76].contains(event.keyCode) else {
            super.keyDown(with: event)
            return
        }
        activateTab()
    }

    private func activateTab() {
        onSelect?(tabIndex)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let window else { return }
        window.makeFirstResponder(self)
        let start = event.locationInWindow
        highlight(true)

        while let next = MouseTracking.nextEvent(in: window) {
            if next.type == .leftMouseUp {
                highlight(false)
                if bounds.contains(convert(next.locationInWindow, from: nil)) {
                    activateTab()
                }
                return
            }

            let distance = hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y)
            guard distance >= 4 else { continue }
            highlight(false)

            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(tabID.uuidString, forType: explorerTabPasteboardType)
            let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
            let visual = superview ?? self
            let draggingFrame = convert(visual.bounds, from: visual)
            draggingItem.setDraggingFrame(draggingFrame, contents: visual.dragSnapshot())

            let session = beginDraggingSession(with: [draggingItem], event: next, source: self)
            session.draggingFormation = .none
            session.animatesToStartingPositionsOnCancelOrFail = false
            return
        }

        highlight(false)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDragEnded?(tabID, screenPoint, operation)
    }
}

final class ExplorerTabBarView: NSView {
    weak var delegate: ExplorerTabBarViewDelegate?

    private let tabScrollView = NSScrollView()
    private let tabStack = NSStackView()
    private let plusButton = NSButton()
    private let bottomLine = NSBox()
    private let insertionIndicator = NSView()
    private var tabScrollLeadingConstraint: NSLayoutConstraint?
    private var tabScrollWidthConstraint: NSLayoutConstraint?
    private var tabWidthConstraints: [NSLayoutConstraint] = []
    private var tabViewsByID: [UUID: NSView] = [:]
    private var tabButtons: [ExplorerTabButton] = []
    private var items: [ExplorerTabBarItem] = []
    private var activeTabID: UUID?
    private var visibleTabIDs: Set<UUID> = []
    private var shouldRevealActiveTab = true

    var availableWindowWidth: CGFloat = 680 {
        didSet { needsLayout = true }
    }

    var leadingInset: CGFloat = 78 {
        didSet {
            tabScrollLeadingConstraint?.constant = leadingInset
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        updateColors()
        registerForDraggedTypes([explorerTabPasteboardType])

        tabScrollView.translatesAutoresizingMaskIntoConstraints = false
        tabScrollView.borderType = .noBorder
        tabScrollView.drawsBackground = false
        tabScrollView.hasHorizontalScroller = true
        tabScrollView.hasVerticalScroller = false
        tabScrollView.autohidesScrollers = true
        tabScrollView.scrollerStyle = .overlay
        tabScrollView.horizontalScrollElasticity = .automatic
        tabScrollView.verticalScrollElasticity = .none
        addSubview(tabScrollView)

        tabStack.orientation = .horizontal
        tabStack.alignment = .bottom
        tabStack.spacing = 2
        tabStack.setAccessibilityRole(.tabGroup)
        tabScrollView.documentView = tabStack

        plusButton.translatesAutoresizingMaskIntoConstraints = false
        plusButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: L10n.text("New tab"))
        plusButton.title = ""
        plusButton.bezelStyle = .accessoryBarAction
        plusButton.isBordered = false
        plusButton.target = self
        plusButton.action = #selector(addTab(_:))
        plusButton.toolTip = L10n.text("New tab")
        addSubview(plusButton)

        insertionIndicator.wantsLayer = true
        insertionIndicator.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        insertionIndicator.layer?.cornerRadius = 1.5
        insertionIndicator.isHidden = true
        addSubview(insertionIndicator)

        bottomLine.translatesAutoresizingMaskIntoConstraints = false
        bottomLine.boxType = .separator
        addSubview(bottomLine)

        tabScrollLeadingConstraint = tabScrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingInset)
        tabScrollLeadingConstraint?.priority = .init(999)
        tabScrollWidthConstraint = tabScrollView.widthAnchor.constraint(equalToConstant: 300)
        tabScrollWidthConstraint?.priority = .init(999)
        NSLayoutConstraint.activate([
            tabScrollLeadingConstraint!,
            tabScrollWidthConstraint!,
            tabScrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: 1),
            tabScrollView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            tabScrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            plusButton.leadingAnchor.constraint(equalTo: tabScrollView.trailingAnchor, constant: 8),
            plusButton.centerYAnchor.constraint(equalTo: tabScrollView.centerYAnchor),
            plusButton.widthAnchor.constraint(equalToConstant: 34),
            plusButton.heightAnchor.constraint(equalToConstant: 32),
            plusButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            bottomLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomLine.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        updatePreferredTabWidths()
        updateTabDocumentFrame()
        revealActiveTabIfNeeded()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override var mouseDownCanMoveWindow: Bool { true }

    private func updateColors() {
        layer?.backgroundColor = explorerTabStripColor.cgColor
    }

    func update(items: [ExplorerTabBarItem], activeTabID: UUID?, visibleTabIDs: Set<UUID>) {
        shouldRevealActiveTab = self.activeTabID != activeTabID || self.items.isEmpty
        self.items = items
        self.activeTabID = activeTabID
        self.visibleTabIDs = visibleTabIDs
        rebuildTabs()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard draggedTabID(from: sender) != nil else { return [] }
        updateInsertionIndicator(for: sender)
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard draggedTabID(from: sender) != nil else { return [] }
        updateInsertionIndicator(for: sender)
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        insertionIndicator.isHidden = true
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        draggedTabID(from: sender) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let tabID = draggedTabID(from: sender) else { return false }
        let index = insertionIndex(at: convert(sender.draggingLocation, from: nil))
        insertionIndicator.isHidden = true
        delegate?.tabBar(self, didRequestMove: tabID, to: index)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        insertionIndicator.isHidden = true
    }

    private func draggedTabID(from info: NSDraggingInfo) -> UUID? {
        guard let value = info.draggingPasteboard.string(forType: explorerTabPasteboardType) else { return nil }
        return UUID(uuidString: value)
    }

    private func insertionIndex(at point: NSPoint) -> Int {
        for (index, tab) in tabStack.arrangedSubviews.enumerated() {
            let frame = convert(tab.bounds, from: tab)
            if point.x < frame.midX { return index }
        }
        return items.count
    }

    private func updateInsertionIndicator(for info: NSDraggingInfo) {
        let index = insertionIndex(at: convert(info.draggingLocation, from: nil))
        let x: CGFloat
        if index < tabStack.arrangedSubviews.count {
            let tab = tabStack.arrangedSubviews[index]
            x = convert(tab.bounds, from: tab).minX - 2
        } else if let last = tabStack.arrangedSubviews.last {
            x = convert(last.bounds, from: last).maxX
        } else {
            x = leadingInset
        }
        insertionIndicator.frame = NSRect(x: x, y: 5, width: 3, height: max(20, bounds.height - 10))
        insertionIndicator.isHidden = false
    }

    private func rebuildTabs() {
        let previousViews = tabViewsByID
        let remainingIDs = Set(items.map(\.id))
        for (id, tab) in previousViews where !remainingIDs.contains(id) {
            tabStack.removeArrangedSubview(tab)
            tab.removeFromSuperview()
        }
        tabWidthConstraints.removeAll()
        tabViewsByID.removeAll(keepingCapacity: true)
        tabButtons.removeAll(keepingCapacity: true)

        for (index, item) in items.enumerated() {
            let isActive = item.id == activeTabID
            let isVisible = visibleTabIDs.contains(item.id)
            // Loading/title updates must not detach a button while AppKit is
            // tracking its mouse-down. Keep controls alive by stable tab ID.
            let existing = previousViews[item.id]
            let tab = existing ?? NSView()
            tab.translatesAutoresizingMaskIntoConstraints = false
            tab.wantsLayer = true
            tab.layer?.cornerRadius = 8
            // CALayer corner coordinates are not affected by NSView's flipped
            // drawing coordinates: MaxY is the visual top of this tab strip.
            // Round only the top edge and keep the command-bar edge square.
            tab.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            tab.layer?.backgroundColor = isVisible
                ? NSColor.controlBackgroundColor.cgColor
                : NSColor.clear.cgColor
            tab.layer?.borderWidth = isActive && visibleTabIDs.count > 1 ? 2 : 0
            tab.layer?.borderColor = NSColor.controlAccentColor.cgColor

            let button = tab.subviews.compactMap { $0 as? ExplorerTabButton }.first ?? ExplorerTabButton()
            button.translatesAutoresizingMaskIntoConstraints = false
            button.title = item.title
            button.image = NSImage(systemSymbolName: "folder", accessibilityDescription: item.title)
            button.imagePosition = .imageLeading
            button.alignment = .left
            button.lineBreakMode = .byTruncatingTail
            button.font = .systemFont(ofSize: 13.5, weight: isActive ? .semibold : (isVisible ? .medium : .regular))
            button.bezelStyle = .accessoryBarAction
            button.isBordered = false
            button.focusRingType = .default
            button.tabIndex = index
            button.tabID = item.id
            button.isSelectedTab = isActive
            button.state = isActive ? .on : .off
            button.setAccessibilityRole(.radioButton)
            button.setAccessibilityLabel(item.title)
            button.setAccessibilityHelp(item.locationDescription)
            button.onSelect = { [weak self] selectedIndex in
                guard let self else { return }
                self.delegate?.tabBar(self, didSelect: selectedIndex)
            }
            button.onDragEnded = { [weak self] tabID, point, operation in
                guard let self else { return }
                self.delegate?.tabBar(self, didFinishDragging: tabID, at: point, operation: operation)
            }
            button.toolTip = item.locationDescription + "\n" + L10n.text("Drag outside the window to open in a new window")
            if button.superview == nil { tab.addSubview(button) }

            let close = tab.subviews.compactMap { $0 as? NSButton }.first { !($0 is ExplorerTabButton) } ?? NSButton()
            close.translatesAutoresizingMaskIntoConstraints = false
            close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L10n.text("Close tab"))
            close.title = ""
            close.bezelStyle = .accessoryBarAction
            close.isBordered = false
            close.tag = index
            close.target = self
            close.action = #selector(closeTab(_:))
            close.toolTip = L10n.text("Close tab")
            if close.superview == nil { tab.addSubview(close) }

            let preferredWidth = tab.constraints.first { $0.firstAttribute == .width && $0.secondItem == nil }
                ?? tab.widthAnchor.constraint(equalToConstant: 260)
            tabWidthConstraints.append(preferredWidth)
            if existing == nil { NSLayoutConstraint.activate([
                preferredWidth,
                tab.heightAnchor.constraint(equalToConstant: 40),
                button.leadingAnchor.constraint(equalTo: tab.leadingAnchor, constant: 12),
                button.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -5),
                button.topAnchor.constraint(equalTo: tab.topAnchor, constant: 3),
                button.bottomAnchor.constraint(equalTo: tab.bottomAnchor, constant: -3),
                close.trailingAnchor.constraint(equalTo: tab.trailingAnchor, constant: -9),
                close.centerYAnchor.constraint(equalTo: tab.centerYAnchor),
                close.widthAnchor.constraint(equalToConstant: 21),
                close.heightAnchor.constraint(equalToConstant: 21)
            ]) }
            if tabStack.arrangedSubviews.firstIndex(of: tab) != index {
                if tab.superview != nil { tabStack.removeArrangedSubview(tab) }
                tabStack.insertArrangedSubview(tab, at: index)
            }
            tabViewsByID[item.id] = tab
            tabButtons.append(button)
        }
        updateKeyViewLoop()
        updatePreferredTabWidths()
        updateTabDocumentFrame()
        revealActiveTabIfNeeded()
    }

    private func updatePreferredTabWidths() {
        guard !tabWidthConstraints.isEmpty else {
            tabScrollWidthConstraint?.constant = 1
            return
        }
        let count = CGFloat(tabWidthConstraints.count)
        let viewportWidth = max(1, (bounds.width > 1 ? bounds.width : availableWindowWidth) - leadingInset - 52)
        let availableForTabs = max(1, viewportWidth - max(0, count - 1) * tabStack.spacing)
        // Tabs shrink down to the familiar compact Windows width. Beyond that
        // point the document view grows and the strip scrolls, instead of
        // asking Auto Layout to satisfy mutually impossible minimum widths.
        let target = min(300, max(140, availableForTabs / count))
        for constraint in tabWidthConstraints where abs(constraint.constant - target) > 0.5 {
            constraint.constant = target
        }
        let desiredWidth = min(viewportWidth, count * target + max(0, count - 1) * tabStack.spacing)
        if abs((tabScrollWidthConstraint?.constant ?? 0) - desiredWidth) > 0.5 {
            tabScrollWidthConstraint?.constant = desiredWidth
        }
    }

    private func updateTabDocumentFrame() {
        let width = tabWidthConstraints.reduce(CGFloat.zero) { $0 + $1.constant }
            + max(0, CGFloat(tabWidthConstraints.count - 1)) * tabStack.spacing
        let size = NSSize(
            width: max(width, tabScrollView.contentView.bounds.width),
            height: max(32, tabScrollView.contentView.bounds.height)
        )
        guard tabStack.frame.size != size else { return }
        tabStack.frame = NSRect(origin: .zero, size: size)
        tabStack.needsLayout = true
        tabStack.layoutSubtreeIfNeeded()
        tabScrollView.reflectScrolledClipView(tabScrollView.contentView)
    }

    private func revealActiveTabIfNeeded() {
        guard shouldRevealActiveTab,
              tabScrollView.contentView.bounds.width > 1,
              let activeTabID,
              let tab = tabViewsByID[activeTabID] else { return }
        tabStack.layoutSubtreeIfNeeded()
        guard tab.frame.width > 0 else { return }
        tab.scrollToVisible(tab.bounds.insetBy(dx: -6, dy: 0))
        tabScrollView.reflectScrolledClipView(tabScrollView.contentView)
        shouldRevealActiveTab = false
    }

    private func updateKeyViewLoop() {
        guard !tabButtons.isEmpty else {
            plusButton.nextKeyView = nil
            return
        }
        for (button, next) in zip(tabButtons, tabButtons.dropFirst()) {
            button.nextKeyView = next
        }
        tabButtons.last?.nextKeyView = plusButton
        plusButton.nextKeyView = tabButtons.first
    }

    @objc private func closeTab(_ sender: NSButton) {
        delegate?.tabBar(self, didRequestClose: sender.tag)
    }

    @objc private func addTab(_ sender: NSButton) {
        delegate?.tabBarDidRequestNewTab(self)
    }
}
