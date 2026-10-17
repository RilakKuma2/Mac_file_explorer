import AppKit

struct BreadcrumbChildDirectory: Equatable, Sendable {
    let url: URL
    let title: String
}

enum BreadcrumbChildDirectoryLoader {
    static func load(
        from directoryURL: URL,
        fileManager: FileManager = .default,
        shouldContinue: () -> Bool = { true }
    ) throws -> [BreadcrumbChildDirectory] {
        guard shouldContinue() else { throw CancellationError() }

        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isHiddenKey,
            .isPackageKey,
            .localizedNameKey
        ]
        let childURLs = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )

        var children: [BreadcrumbChildDirectory] = []
        children.reserveCapacity(childURLs.count)
        for childURL in childURLs {
            guard shouldContinue() else { throw CancellationError() }
            let values = try childURL.resourceValues(forKeys: Set(keys))
            guard values.isDirectory == true,
                  values.isHidden != true,
                  values.isPackage != true else { continue }
            children.append(BreadcrumbChildDirectory(
                url: childURL.standardizedFileURL,
                title: values.localizedName ?? fileManager.displayName(atPath: childURL.path)
            ))
        }

        return children.sorted { lhs, rhs in
            let comparison = lhs.title.localizedStandardCompare(rhs.title)
            if comparison == .orderedSame { return lhs.url.path < rhs.url.path }
            return comparison == .orderedAscending
        }
    }
}

private final class BreadcrumbChildDirectoryLoadToken: @unchecked Sendable {
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

private class BreadcrumbComponentButton: NSButton {
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovered = false
    var isDropTarget = false { didSet { updateHighlight() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 5
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateHighlight()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateHighlight()
    }

    private func updateHighlight() {
        let highlighted = isHovered || isDropTarget
        layer?.backgroundColor = highlighted
            ? NSColor.controlAccentColor.withAlphaComponent(isDropTarget ? 0.30 : 0.16).cgColor
            : NSColor.clear.cgColor
        layer?.borderWidth = highlighted ? 1 : 0
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(isDropTarget ? 0.85 : 0.35).cgColor
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

private final class BreadcrumbChevronButton: BreadcrumbComponentButton {
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let character = event.charactersIgnoringModifiers
        if event.keyCode == 36 || event.keyCode == 76 || event.keyCode == 125 || character == " " {
            performClick(nil)
            return
        }
        super.keyDown(with: event)
    }
}

protocol BreadcrumbBarViewDelegate: AnyObject {
    func breadcrumbBarDidRequestHome(_ breadcrumbBar: BreadcrumbBarView)
    func breadcrumbBar(_ breadcrumbBar: BreadcrumbBarView, didSelect url: URL)
    func breadcrumbBar(_ breadcrumbBar: BreadcrumbBarView, didSubmitPath path: String)
    func breadcrumbBar(_ breadcrumbBar: BreadcrumbBarView, validateDrop info: NSDraggingInfo, into directory: URL) -> NSDragOperation
    func breadcrumbBar(_ breadcrumbBar: BreadcrumbBarView, acceptDrop info: NSDraggingInfo, into directory: URL) -> Bool
}

extension BreadcrumbBarViewDelegate {
    func breadcrumbBar(_ breadcrumbBar: BreadcrumbBarView, validateDrop info: NSDraggingInfo, into directory: URL) -> NSDragOperation { [] }
    func breadcrumbBar(_ breadcrumbBar: BreadcrumbBarView, acceptDrop info: NSDraggingInfo, into directory: URL) -> Bool { false }
}

final class BreadcrumbBarView: NSView, NSTextFieldDelegate, NSMenuDelegate {
    override var acceptsFirstResponder: Bool { true }
    weak var delegate: BreadcrumbBarViewDelegate?

    var isEditingAddress: Bool { !editField.isHidden }

    private let stack = NSStackView()
    private let editField = NSTextField()
    private var componentURLs: [URL] = []
    private var chevronDirectoryURLs: [URL] = []
    private var representedPath = FileManager.default.homeDirectoryForCurrentUser.path
    private var outsideClickMonitor: Any?
    private let childDirectoryQueue = DispatchQueue(
        label: "com.macexplorer.breadcrumb-child-directories",
        qos: .utility
    )
    private var childDirectoryLoadToken: BreadcrumbChildDirectoryLoadToken?
    private var childDirectoryRequestID: UInt = 0
    private var activeChildDirectoryRequestID: UInt?
    private var activeChildDirectoryMenu: NSMenu?
    private weak var highlightedDropButton: BreadcrumbComponentButton?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        registerForDraggedTypes([.fileURL])

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 7, bottom: 2, right: 7)
        addSubview(stack)

        editField.translatesAutoresizingMaskIntoConstraints = false
        editField.isBordered = false
        editField.drawsBackground = false
        editField.font = .systemFont(ofSize: 13)
        editField.delegate = self
        editField.target = self
        editField.action = #selector(submitPath(_:))
        editField.isHidden = true
        addSubview(editField)

        toolTip = L10n.text("Click to enter a path") + " (⌘L)"

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            editField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            editField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            editField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        showHome()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        removeOutsideClickMonitor()
        childDirectoryLoadToken?.cancel()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard editField.isHidden else { return }
        addCursorRect(bounds, cursor: .iBeam)
        for case let button as NSButton in stack.arrangedSubviews
        where ["breadcrumbCrumb", "breadcrumbChevron"].contains(button.identifier?.rawValue ?? "") {
            guard !button.isHiddenOrHasHiddenAncestor else { continue }
            addCursorRect(convert(button.bounds, from: button), cursor: .pointingHand)
        }
    }

    override func layout() {
        // Keep a readable current folder in narrow split panes instead of
        // reducing every ancestor name to zero and showing only chevrons.
        let retainedComponents = bounds.width < 240 ? 1 : (bounds.width < 400 ? 2 : componentURLs.count)
        let firstVisible = max(0, componentURLs.count - retainedComponents)
        for case let button as NSButton in stack.arrangedSubviews where button.tag >= 0 {
            let identifier = button.identifier?.rawValue
            if identifier == "breadcrumbCrumb" || identifier == "breadcrumbChevron" {
                button.isHidden = button.tag < firstVisible
            }
        }
        super.layout()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        guard editField.isHidden, !isHidden, bounds.contains(localPoint) else { return super.hitTest(point) }
        let candidate = super.hitTest(point)
        var ancestor = candidate
        while let view = ancestor {
            if let button = view as? NSButton {
                if button.identifier?.rawValue == "breadcrumbAddressTarget" { return self }
                return candidate
            }
            if view === self { break }
            ancestor = view.superview
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        beginEditing()
    }

    // Only actual path components are destinations. The Home dashboard, virtual
    // locations, chevrons and editable whitespace must never silently move files.
    func dropDestination(atWindowPoint point: NSPoint) -> URL? {
        guard let button = dropButton(atWindowPoint: point) else { return nil }
        return dropDirectory(for: button)
    }

    private func dropDirectory(for button: NSButton) -> URL? {
        if componentURLs.indices.contains(button.tag) { return componentURLs[button.tag] }
        // Under the user's home directory its name is abbreviated to the house
        // icon. It is a real ancestor only in this case, not on the dashboard or
        // when browsing an unrelated volume.
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        if button.tag == -1,
           representedPath == home.path || representedPath.hasPrefix(home.path + "/") {
            return home
        }
        return nil
    }

    private func dropButton(atWindowPoint point: NSPoint) -> BreadcrumbComponentButton? {
        guard !isEditingAddress, !isHiddenOrHasHiddenAncestor,
              bounds.contains(convert(point, from: nil)) else { return nil }
        return stack.arrangedSubviews.compactMap { $0 as? BreadcrumbComponentButton }.first {
            $0.identifier?.rawValue == "breadcrumbCrumb"
                && dropDirectory(for: $0) != nil
                && !$0.isHiddenOrHasHiddenAncestor
                && $0.bounds.contains($0.convert(point, from: nil))
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        cancelChildDirectoryMenuRequest(closeMenu: true)
        FileDragDiagnostics.logger.notice("Breadcrumb drag entered: sequence=\(sender.draggingSequenceNumber)")
        return draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let destination = dropDestination(atWindowPoint: sender.draggingLocation),
              let delegate else {
            clearDropHighlight()
            return []
        }
        let operation = delegate.breadcrumbBar(self, validateDrop: sender, into: destination)
        let button = operation.isEmpty ? nil : dropButton(atWindowPoint: sender.draggingLocation)
        if highlightedDropButton !== button {
            clearDropHighlight()
            highlightedDropButton = button
            button?.isDropTarget = true
        }
        return operation
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        clearDropHighlight()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !draggingUpdated(sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { clearDropHighlight() }
        guard let destination = dropDestination(atWindowPoint: sender.draggingLocation),
              let delegate else { return false }
        let accepted = delegate.breadcrumbBar(self, acceptDrop: sender, into: destination)
        FileDragDiagnostics.logger.notice("Breadcrumb drop: sequence=\(sender.draggingSequenceNumber) accepted=\(accepted)")
        return accepted
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        clearDropHighlight()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { clearDropHighlight() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func clearDropHighlight() {
        highlightedDropButton?.isDropTarget = false
        highlightedDropButton = nil
    }

    /// Routes a window-level mouse-down to the exact breadcrumb action. This is
    /// used by the browser window so the address controls remain clickable even
    /// when a split-view or titlebar tracking view overlaps AppKit's hit testing.
    func handleMouseDown(atWindowPoint windowPoint: NSPoint) -> Bool {
        guard editField.isHidden,
              !isHidden,
              bounds.contains(convert(windowPoint, from: nil)) else { return false }

        for case let button as NSButton in stack.arrangedSubviews {
            let identifier = button.identifier?.rawValue
            guard !button.isHiddenOrHasHiddenAncestor,
                  identifier == "breadcrumbCrumb" || identifier == "breadcrumbChevron" else { continue }
            if button.bounds.contains(button.convert(windowPoint, from: nil)) {
                NavigationClickDispatcher.enqueue(button)
                return true
            }
        }
        beginEditing()
        return true
    }

    func showHome() {
        representedPath = "home://"
        componentURLs = []
        rebuild(homeOnly: true)
    }

    func show(url: URL) {
        representedPath = url.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let normalized = url.standardizedFileURL
        let relativeToHome = normalized.path == home.path || normalized.path.hasPrefix(home.path + "/")

        if relativeToHome {
            var urls: [URL] = []
            var cursor = normalized
            while cursor.path != home.path {
                urls.append(cursor)
                cursor.deleteLastPathComponent()
            }
            componentURLs = urls.reversed()
        } else {
            let components = normalized.pathComponents
            var cursor = URL(fileURLWithPath: "/")
            var urls = [cursor]
            for component in components.dropFirst() {
                cursor.appendPathComponent(component)
                urls.append(cursor)
            }
            componentURLs = urls
        }
        rebuild(homeOnly: false)
    }

    func showNetwork() {
        showSpecial(title: L10n.text("Network"), symbol: "network", representedPath: "network://")
    }

    func showRecents() {
        showSpecial(title: L10n.text("Recent"), symbol: "clock.arrow.circlepath", representedPath: "recent://")
    }

    func showTag(_ name: String) {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? name
        showSpecial(title: name, symbol: "tag.fill", representedPath: "tag://" + encoded)
    }

    private func showSpecial(title: String, symbol: String, representedPath: String) {
        clearDropHighlight()
        cancelChildDirectoryMenuRequest(closeMenu: true)
        removeOutsideClickMonitor()
        self.representedPath = representedPath
        componentURLs = []
        chevronDirectoryURLs = []
        editField.isHidden = true
        stack.isHidden = false
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let homeButton = crumbButton(title: "", symbol: "house", tag: -1)
        homeButton.toolTip = L10n.text("Home")
        stack.addArrangedSubview(homeButton)
        stack.addArrangedSubview(separatorChevron())
        let specialButton = crumbButton(title: title, symbol: symbol, tag: -2)
        stack.addArrangedSubview(specialButton)
        stack.addArrangedSubview(addressEditTarget())
        window?.invalidateCursorRects(for: self)
    }

    func beginEditing() {
        clearDropHighlight()
        cancelChildDirectoryMenuRequest(closeMenu: true)
        editField.stringValue = representedPath
        editField.isHidden = false
        stack.isHidden = true
        window?.makeFirstResponder(editField)
        if let editor = editField.currentEditor() {
            editor.selectedRange = NSRange(location: 0, length: (editor.string as NSString).length)
        }
        installOutsideClickMonitor()
        window?.invalidateCursorRects(for: self)
    }

    func endEditing() {
        removeOutsideClickMonitor()
        guard !editField.isHidden else { return }
        let hadEditorFocus = editField.currentEditor().map { window?.firstResponder === $0 } ?? false
        editField.stringValue = representedPath
        editField.isHidden = true
        stack.isHidden = false
        if hadEditorFocus {
            window?.makeFirstResponder(self)
        }
        window?.invalidateCursorRects(for: self)
    }

    private func rebuild(homeOnly: Bool) {
        clearDropHighlight()
        cancelChildDirectoryMenuRequest(closeMenu: true)
        removeOutsideClickMonitor()
        chevronDirectoryURLs = []
        editField.isHidden = true
        stack.isHidden = false
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let homeButton = crumbButton(title: "", symbol: "house", tag: -1)
        homeButton.toolTip = L10n.text("Home")
        stack.addArrangedSubview(homeButton)

        guard !homeOnly else {
            stack.addArrangedSubview(chevron(for: FileManager.default.homeDirectoryForCurrentUser))
            let title = crumbButton(title: L10n.text("Home"), symbol: nil, tag: -1)
            stack.addArrangedSubview(title)
            stack.addArrangedSubview(addressEditTarget())
            window?.invalidateCursorRects(for: self)
            return
        }

        let homeURL = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        for (index, url) in componentURLs.enumerated() {
            let directoryToLeft = index == 0
                ? (url.path == "/" ? URL(fileURLWithPath: "/", isDirectory: true) : homeURL)
                : componentURLs[index - 1]
            stack.addArrangedSubview(chevron(for: directoryToLeft))
            let name: String
            if url.path == "/" {
                name = L10n.text("This Mac")
            } else if let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first,
                      url.standardizedFileURL == desktop.standardizedFileURL {
                name = L10n.text("Desktop")
            } else {
                name = FileManager.default.displayName(atPath: url.path)
            }
            stack.addArrangedSubview(crumbButton(title: name, symbol: nil, tag: index))
        }
        stack.addArrangedSubview(addressEditTarget())
        window?.invalidateCursorRects(for: self)
    }

    private func crumbButton(title: String, symbol: String?, tag: Int) -> NSButton {
        let button = BreadcrumbComponentButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.title = title
        button.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: title) }
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        button.font = .systemFont(ofSize: 13)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.identifier = NSUserInterfaceItemIdentifier("breadcrumbCrumb")
        button.cell?.lineBreakMode = .byTruncatingMiddle
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.tag = tag
        button.target = self
        button.action = #selector(selectComponent(_:))
        return button
    }

    private func chevron(for directoryURL: URL) -> NSButton {
        let button = BreadcrumbChevronButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.title = ""
        button.image = NSImage(
            systemSymbolName: "chevron.right",
            accessibilityDescription: L10n.text("Show subfolders")
        )
        button.imagePosition = .imageOnly
        button.contentTintColor = .tertiaryLabelColor
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.focusRingType = .default
        button.identifier = NSUserInterfaceItemIdentifier("breadcrumbChevron")
        button.target = self
        button.action = #selector(showChildDirectories(_:))
        button.tag = chevronDirectoryURLs.count
        chevronDirectoryURLs.append(directoryURL.standardizedFileURL)
        button.widthAnchor.constraint(equalToConstant: 17).isActive = true
        button.setContentCompressionResistancePriority(.required, for: .horizontal)

        let directoryName = displayNameForAccessibility(of: directoryURL)
        let label = String(format: L10n.text("Show subfolders of %@"), directoryName)
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.setAccessibilityHelp(L10n.text("Press Return, Space, or Down Arrow to open the folder menu."))
        return button
    }

    private func separatorChevron() -> NSImageView {
        let view = NSImageView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        view.contentTintColor = .tertiaryLabelColor
        view.imageScaling = .scaleProportionallyDown
        view.widthAnchor.constraint(equalToConstant: 13).isActive = true
        view.setAccessibilityElement(false)
        return view
    }

    private func displayNameForAccessibility(of url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        if url.standardizedFileURL == home { return L10n.text("Home") }
        if url.path == "/" { return L10n.text("This Mac") }
        return url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
    }

    private func addressEditTarget() -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(beginEditingFromButton(_:)))
        button.identifier = NSUserInterfaceItemIdentifier("breadcrumbAddressTarget")
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.bezelStyle = .accessoryBarAction
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.toolTip = L10n.text("Click to enter a path") + " (⌘L)"
        button.setAccessibilityLabel(L10n.text("Address bar"))
        return button
    }

    @objc private func selectComponent(_ sender: NSButton) {
        endEditing()
        if sender.tag == -1 {
            delegate?.breadcrumbBarDidRequestHome(self)
        } else if sender.tag >= 0, componentURLs.indices.contains(sender.tag) {
            delegate?.breadcrumbBar(self, didSelect: componentURLs[sender.tag])
        }
    }

    @objc private func showChildDirectories(_ sender: NSButton) {
        guard chevronDirectoryURLs.indices.contains(sender.tag) else { return }
        let directoryURL = chevronDirectoryURLs[sender.tag]
        let menu = makeChildDirectoryMenu(for: directoryURL)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY - 3), in: sender)
        if activeChildDirectoryMenu === menu {
            cancelChildDirectoryMenuRequest(closeMenu: false)
        }
    }

    func makeChildDirectoryMenu(for directoryURL: URL) -> NSMenu {
        cancelChildDirectoryMenuRequest(closeMenu: true)

        childDirectoryRequestID &+= 1
        let requestID = childDirectoryRequestID
        let token = BreadcrumbChildDirectoryLoadToken()
        childDirectoryLoadToken = token
        activeChildDirectoryRequestID = requestID

        let menu = NSMenu(title: displayNameForAccessibility(of: directoryURL))
        menu.autoenablesItems = false
        menu.delegate = self
        let loadingItem = NSMenuItem(title: L10n.text("Loading") + "…", action: nil, keyEquivalent: "")
        loadingItem.isEnabled = false
        menu.addItem(loadingItem)
        activeChildDirectoryMenu = menu

        childDirectoryQueue.async { [weak self] in
            let result = Result {
                try BreadcrumbChildDirectoryLoader.load(
                    from: directoryURL,
                    shouldContinue: { !token.isCancelled }
                )
            }
            guard !token.isCancelled else { return }
            // The popup can be tracking inside NavigationClickDispatcher's
            // main-queue block. Another main-queue block cannot run until that
            // popup closes. Deliver through its nested tracking run loop.
            RunLoop.main.perform(inModes: [.common, .eventTracking]) { [weak self] in
                self?.finishChildDirectoryLoad(result, requestID: requestID, token: token)
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }

        return menu
    }

    private func finishChildDirectoryLoad(
        _ result: Result<[BreadcrumbChildDirectory], Error>,
        requestID: UInt,
        token: BreadcrumbChildDirectoryLoadToken
    ) {
        guard !token.isCancelled,
              activeChildDirectoryRequestID == requestID,
              childDirectoryLoadToken === token,
              let menu = activeChildDirectoryMenu else { return }

        menu.removeAllItems()
        switch result {
        case let .success(children) where children.isEmpty:
            let item = NSMenuItem(title: L10n.text("No subfolders"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        case let .success(children):
            for child in children {
                let item = NSMenuItem(
                    title: child.title,
                    action: #selector(selectChildDirectory(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = child.url
                item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: child.title)
                item.setAccessibilityLabel(child.title)
                menu.addItem(item)
            }
        case let .failure(error):
            let item = NSMenuItem(
                title: L10n.text("Unable to load subfolders"),
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            item.toolTip = error.localizedDescription
            menu.addItem(item)
        }
        childDirectoryLoadToken = nil
    }

    @objc private func selectChildDirectory(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        delegate?.breadcrumbBar(self, didSelect: url)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard activeChildDirectoryMenu === menu else { return }
        cancelChildDirectoryMenuRequest(closeMenu: false)
    }

    private func cancelChildDirectoryMenuRequest(closeMenu: Bool) {
        childDirectoryLoadToken?.cancel()
        childDirectoryLoadToken = nil
        activeChildDirectoryRequestID = nil
        let menu = activeChildDirectoryMenu
        activeChildDirectoryMenu = nil
        if closeMenu { menu?.cancelTracking() }
    }

    @objc private func beginEditingFromButton(_ sender: NSButton) {
        beginEditing()
    }

    @objc private func submitPath(_ sender: NSTextField) {
        let submittedPath = sender.stringValue
        endEditing()
        delegate?.breadcrumbBar(self, didSubmitPath: submittedPath)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        endEditing()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === editField else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let submittedPath = textView.string
            endEditing()
            delegate?.breadcrumbBar(self, didSubmitPath: submittedPath)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            endEditing()
            return true
        }
        return false
    }

    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self, !self.editField.isHidden else { return event }
            guard event.window === self.window else {
                self.endEditing()
                return event
            }
            let point = self.convert(event.locationInWindow, from: nil)
            if !self.bounds.contains(point) { self.endEditing() }
            return event
        }
    }

    private func removeOutsideClickMonitor() {
        guard let outsideClickMonitor else { return }
        NSEvent.removeMonitor(outsideClickMonitor)
        self.outsideClickMonitor = nil
    }

}
