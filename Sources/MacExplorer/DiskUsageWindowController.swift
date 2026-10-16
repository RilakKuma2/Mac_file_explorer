import AppKit
import QuartzCore

// Share ancestor paths instead of retaining a full Foundation URL (and its
// resource caches) for every file in a volume.
fileprivate final class DiskUsagePath: Sendable {
    let name: String
    let parent: DiskUsagePath?
    let rootURL: URL?

    init(root: URL) {
        rootURL = URL(fileURLWithPath: root.path)
        name = root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent
        parent = nil
    }

    init(name: String, parent: DiskUsagePath) {
        self.name = name
        self.parent = parent
        rootURL = nil
    }

    var url: URL {
        if let rootURL { return rootURL }
        return parent!.url.appendingPathComponent(name)
    }
}

struct DiskUsageNode: Sendable {
    fileprivate let storagePath: DiskUsagePath
    var url: URL { storagePath.url }
    let byteCount: Int64
    let isDirectory: Bool
    let children: [DiskUsageNode]

    init(url: URL, byteCount: Int64, isDirectory: Bool, children: [DiskUsageNode]) {
        self.init(storagePath: DiskUsagePath(root: url), byteCount: byteCount,
                  isDirectory: isDirectory, children: children)
    }

    fileprivate init(storagePath: DiskUsagePath, byteCount: Int64, isDirectory: Bool, children: [DiskUsageNode]) {
        self.storagePath = storagePath
        self.byteCount = byteCount
        self.isDirectory = isDirectory
        self.children = children
    }

    var name: String {
        storagePath.name
    }
}

enum DiskUsageScanner {
    static let maximumProgressNodes = 2_048
    private final class MutableNode {
        let storagePath: DiskUsagePath
        var url: URL { storagePath.url }
        let isDirectory: Bool
        let isSymbolicLink: Bool
        let ownByteCount: Int64
        var byteCount: Int64
        var childrenByteCount: Int64 = 0
        var children: [MutableNode] = []
        weak var parent: MutableNode?

        func addChild(_ child: MutableNode) {
            child.parent = self
            children.append(child)
            adjustChildrenSize(by: child.byteCount)
        }

        private func adjustChildrenSize(by delta: Int64) {
            let oldSize = byteCount
            childrenByteCount &+= delta
            byteCount = max(ownByteCount, childrenByteCount)
            if byteCount != oldSize { parent?.adjustChildrenSize(by: byteCount - oldSize) }
        }

        init(url: URL, values: URLResourceValues?, parentPath: DiskUsagePath? = nil) {
            // Enumerator URLs cache resource dictionaries. Retain only the path.
            storagePath = parentPath.map { DiskUsagePath(name: url.lastPathComponent, parent: $0) }
                ?? DiskUsagePath(root: url)
            isDirectory = values?.isDirectory == true
            isSymbolicLink = values?.isSymbolicLink == true
            ownByteCount = Int64(
                values?.totalFileAllocatedSize
                    ?? values?.fileAllocatedSize
                    ?? values?.fileSize
                    ?? 0
            )
            byteCount = ownByteCount
        }

        func finishSnapshot() throws -> DiskUsageNode {
            try Task.checkCancellation()
            var childSnapshots: [DiskUsageNode] = []
            childSnapshots.reserveCapacity(children.count)
            while let child = children.popLast() {
                childSnapshots.append(try child.finishSnapshot())
            }
            // Release the mutable tree as it is converted, instead of retaining
            // two complete trees until all final sorting has finished.
            children.removeAll(keepingCapacity: false)
            try childSnapshots.sort { lhs, rhs in
                try Task.checkCancellation()
                if lhs.byteCount != rhs.byteCount { return lhs.byteCount > rhs.byteCount }
                return autoreleasepool { lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
            }
            let measuredByteCount = max(
                ownByteCount,
                childSnapshots.reduce(Int64(0)) { $0 &+ $1.byteCount }
            )
            return DiskUsageNode(
                storagePath: storagePath,
                byteCount: measuredByteCount,
                isDirectory: isDirectory,
                children: childSnapshots
            )
        }

        func progressSnapshot(budget: inout Int) -> DiskUsageNode {
            budget -= 1
            var visible: [DiskUsageNode] = []
            for child in children {
                guard budget > 0 else { break }
                visible.append(child.progressSnapshot(budget: &budget))
            }
            return DiskUsageNode(storagePath: storagePath, byteCount: byteCount,
                isDirectory: isDirectory, children: visible)
        }
    }

    private static let keys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .fileAllocatedSizeKey,
        .totalFileAllocatedSizeKey
    ]

    static func scan(
        _ url: URL,
        onProgress: @escaping @Sendable (DiskUsageNode, Int) -> Void
    ) throws -> DiskUsageNode {
        let root = MutableNode(url: url, values: try? url.resourceValues(forKeys: keys))
        var scannedItemCount = 0
        var lastPublishTime = Date.distantPast

        func publish(force: Bool = false) {
            let now = Date()
            let interval: TimeInterval
            if scannedItemCount < 1_000 { interval = 0.3 }
            else if scannedItemCount < 20_000 { interval = 0.8 }
            else if scannedItemCount < 100_000 { interval = 1.5 }
            else if scannedItemCount < 500_000 { interval = 3.0 }
            else { interval = 6.0 }
            guard force || now.timeIntervalSince(lastPublishTime) >= interval else { return }
            lastPublishTime = now
            var budget = maximumProgressNodes
            onProgress(root.progressSnapshot(budget: &budget), scannedItemCount)
        }

        func populate(_ node: MutableNode) throws {
            try Task.checkCancellation()
            scannedItemCount += 1
            publish()
            guard node.isDirectory, !node.isSymbolicLink else { return }

            guard let enumerator = FileManager.default.enumerator(
                at: node.url,
                includingPropertiesForKeys: Array(keys),
                options: [],
                errorHandler: { _, _ in true }
            ) else { return }
            while let child = autoreleasepool(invoking: { () -> MutableNode? in
                guard let childURL = enumerator.nextObject() as? URL else { return nil }
                let values = try? childURL.resourceValues(forKeys: keys)
                if values?.isDirectory == true { enumerator.skipDescendants() }
                return MutableNode(url: childURL, values: values, parentPath: node.storagePath)
            }) {
                try Task.checkCancellation()
                node.addChild(child)
                // Show a newly discovered item immediately, even before a large
                // directory below it has finished calculating.
                publish()
                try autoreleasepool { try populate(child) }
                publish()
            }
        }

        try populate(root)
        let finalSnapshot = try autoreleasepool { try root.finishSnapshot() }
        return finalSnapshot
    }
}

/// Coalesces scanner updates so a large drive can never enqueue an unbounded
/// number of complete tree snapshots on the main thread. At most the currently
/// displayed tree and one newer pending tree are retained.
private final class DiskUsageProgressRelay: @unchecked Sendable {
    typealias Value = (root: DiskUsageNode, itemCount: Int)

    private let lock = NSLock()
    private var latestValue: Value?
    private var deliveryScheduled = false
    private var cancelled = false
    private let handler: @MainActor (Value) -> Void

    init(handler: @escaping @MainActor (Value) -> Void) {
        self.handler = handler
    }

    func submit(root: DiskUsageNode, itemCount: Int) {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        latestValue = (root, itemCount)
        if deliveryScheduled {
            lock.unlock()
            return
        }
        deliveryScheduled = true
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.deliverLatest()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        latestValue = nil
        lock.unlock()
    }

    @MainActor
    private func deliverLatest() {
        lock.lock()
        guard !cancelled else {
            deliveryScheduled = false
            lock.unlock()
            return
        }
        let value = latestValue
        latestValue = nil
        deliveryScheduled = false
        lock.unlock()
        if let value { handler(value) }
    }
}

private final class DiskTreemapHoverOverlay: NSView {
    private var highlightedRect: NSRect = .zero
    private var text = ""
    private var presentationGeneration = 0

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func present(rect: NSRect, text: String, animated: Bool) {
        presentationGeneration += 1
        highlightedRect = rect
        self.text = text
        isHidden = false
        alphaValue = 1
        needsDisplay = true
        guard animated else {
            alphaValue = 1
            return
        }
        layer?.removeAnimation(forKey: "treemap-hover-fade")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.18
        fade.toValue = 1
        fade.duration = 0.16
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.add(fade, forKey: "treemap-hover-fade")
    }

    func dismiss(animated: Bool) {
        guard !isHidden else { return }
        presentationGeneration += 1
        let generation = presentationGeneration
        if !animated {
            isHidden = true
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.presentationGeneration == generation else { return }
            self.isHidden = true
            self.alphaValue = 1
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty, !highlightedRect.isEmpty else { return }
        let highlight = NSBezierPath(
            roundedRect: highlightedRect.insetBy(dx: -2, dy: -2),
            xRadius: 5,
            yRadius: 5
        )
        NSColor.controlAccentColor.withAlphaComponent(0.24).setFill()
        highlight.fill()
        NSColor.controlAccentColor.setStroke()
        highlight.lineWidth = 2.5
        highlight.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let measured = (text as NSString).size(withAttributes: attributes)
        let bubbleWidth = min(max(132, measured.width + 22), max(132, bounds.width - 16))
        let bubbleHeight: CGFloat = 30
        var bubbleX = min(highlightedRect.minX + 6, bounds.maxX - bubbleWidth - 8)
        bubbleX = max(8, bubbleX)
        var bubbleY = highlightedRect.minY + 7
        if bubbleY + bubbleHeight > bounds.maxY - 8 {
            bubbleY = max(8, highlightedRect.maxY - bubbleHeight - 7)
        }
        let bubbleRect = NSRect(x: bubbleX, y: bubbleY, width: bubbleWidth, height: bubbleHeight)
        let bubble = NSBezierPath(roundedRect: bubbleRect, xRadius: 8, yRadius: 8)
        NSColor.black.withAlphaComponent(0.78).setFill()
        bubble.fill()
        (text as NSString).draw(
            in: bubbleRect.insetBy(dx: 11, dy: 7),
            withAttributes: attributes
        )
    }
}

final class DiskTreemapView: NSView {
    private struct RenderedEntry {
        let node: DiskUsageNode
        let rect: NSRect
        let depth: Int
    }

    var onHover: ((DiskUsageNode?) -> Void)?
    var onRootChanged: ((DiskUsageNode, Bool) -> Void)?

    private var navigationStack: [DiskUsageNode] = []
    private var entries: [RenderedEntry] = []
    private var selectedURL: URL?
    private var trackingAreaReference: NSTrackingArea?
    private var contextMenuNode: DiskUsageNode?
    private var hoveredURL: URL?
    private let hoverOverlay = DiskTreemapHoverOverlay()
    // Keeping every scanned node is necessary for accurate totals and folder
    // navigation, but creating a rendered rectangle for every file is not.
    // Large package/cache folders can contain hundreds of thousands of files;
    // cap the visual representation so AppKit drawing stays memory-bounded.
    private let maximumRenderedEntryCount = 12_000

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        hoverOverlay.wantsLayer = true
        hoverOverlay.frame = bounds
        hoverOverlay.autoresizingMask = [.width, .height]
        hoverOverlay.isHidden = true
        addSubview(hoverOverlay)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var canNavigateBack: Bool { navigationStack.count > 1 }

    func clear() {
        entries.removeAll(keepingCapacity: false)
        navigationStack.removeAll(keepingCapacity: false)
        contextMenuNode = nil
        selectedURL = nil
        hoveredURL = nil
        hoverOverlay.dismiss(animated: false)
        needsDisplay = true
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        rebuildLayout()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
        trackingAreaReference = tracking
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        for entry in entries where entry.rect.intersects(dirtyRect) {
            draw(entry)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hoveredEntry = entry(at: point)
        guard hoveredEntry?.node.url != hoveredURL else { return }
        hoveredURL = hoveredEntry?.node.url
        if let hoveredEntry {
            let size = Self.byteFormatter.string(fromByteCount: hoveredEntry.node.byteCount)
            hoverOverlay.present(
                rect: hoveredEntry.rect,
                text: "\(hoveredEntry.node.name)  ·  \(size)",
                animated: true
            )
            onHover?(hoveredEntry.node)
        } else {
            hoverOverlay.dismiss(animated: true)
            onHover?(nil)
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredURL = nil
        hoverOverlay.dismiss(animated: true)
        onHover?(nil)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let entry = entry(at: point) else { return }
        selectedURL = entry.node.url
        needsDisplay = true

        guard event.clickCount == 2 else { return }
        if entry.node.isDirectory, !entry.node.children.isEmpty {
            navigationStack.append(entry.node)
            selectedURL = nil
            rebuildLayout()
            animateZoom(inward: true)
            onRootChanged?(entry.node, true)
        } else {
            NSWorkspace.shared.open(entry.node.url)
        }
    }

    func navigateBack() {
        guard navigationStack.count > 1 else { return }
        navigationStack.removeLast()
        selectedURL = nil
        rebuildLayout()
        animateZoom(inward: false)
        if let node = navigationStack.last { onRootChanged?(node, canNavigateBack) }
    }

    func display(rootNode: DiskUsageNode, preservingNavigation: Bool) {
        let currentURL = preservingNavigation ? navigationStack.last?.url : nil
        if let currentURL,
           let updatedPath = path(to: currentURL.standardizedFileURL, in: rootNode) {
            navigationStack = updatedPath
        } else {
            navigationStack = [rootNode]
        }
        rebuildLayout()
        if let current = navigationStack.last {
            onRootChanged?(current, canNavigateBack)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let entry = entry(at: point) else { return nil }
        contextMenuNode = entry.node
        selectedURL = entry.node.url
        needsDisplay = true

        let menu = NSMenu()
        let open = menu.addItem(
            withTitle: entry.node.isDirectory ? L10n.text("Open in Mac Explorer") : L10n.text("Open"),
            action: #selector(openContextNode(_:)),
            keyEquivalent: ""
        )
        open.target = self
        open.image = NSImage(systemSymbolName: entry.node.isDirectory ? "folder" : "arrow.up.forward.app", accessibilityDescription: nil)

        let reveal = menu.addItem(
            withTitle: L10n.text("Reveal in Finder"),
            action: #selector(revealContextNode(_:)),
            keyEquivalent: ""
        )
        reveal.target = self
        reveal.image = NSImage(systemSymbolName: "finder", accessibilityDescription: nil)

        let copyPath = menu.addItem(
            withTitle: L10n.text("Copy Path"),
            action: #selector(copyContextNodePath(_:)),
            keyEquivalent: ""
        )
        copyPath.target = self
        copyPath.image = NSImage(systemSymbolName: "document.on.clipboard", accessibilityDescription: nil)

        menu.addItem(.separator())
        let info = menu.addItem(
            withTitle: L10n.text("Get Info"),
            action: #selector(showContextNodeInfo(_:)),
            keyEquivalent: ""
        )
        info.target = self
        info.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        return menu
    }

    @objc private func openContextNode(_ sender: Any?) {
        guard let node = contextMenuNode else { return }
        if node.isDirectory, let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.createWindow(at: node.url)
        } else {
            NSWorkspace.shared.open(node.url)
        }
    }

    @objc private func revealContextNode(_ sender: Any?) {
        guard let node = contextMenuNode else { return }
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    @objc private func copyContextNodePath(_ sender: Any?) {
        guard let node = contextMenuNode else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.url.path, forType: .string)
    }

    @objc private func showContextNodeInfo(_ sender: Any?) {
        guard let node = contextMenuNode,
              let item = FileSystemService.shared.item(for: node.url) else { return }
        InfoWindowController.present(items: [item])
    }

    private func path(to targetURL: URL, in node: DiskUsageNode) -> [DiskUsageNode]? {
        let nodeURL = node.url.standardizedFileURL
        if nodeURL == targetURL { return [node] }
        let prefix = nodeURL.path == "/" ? "/" : nodeURL.path + "/"
        guard targetURL.path.hasPrefix(prefix) else { return nil }
        for child in node.children where child.isDirectory {
            if let childPath = path(to: targetURL, in: child) {
                return [node] + childPath
            }
        }
        return nil
    }

    private func animateZoom(inward: Bool) {
        guard let layer else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = inward ? 0.82 : 1.12
        scale.toValue = 1
        scale.duration = 0.24
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.40
        fade.toValue = 1
        fade.duration = 0.20
        layer.add(scale, forKey: "storage-map-zoom")
        layer.add(fade, forKey: "storage-map-fade")
    }

    private func rebuildLayout() {
        entries.removeAll(keepingCapacity: true)
        guard let root = navigationStack.last, bounds.width > 10, bounds.height > 10 else {
            needsDisplay = true
            return
        }
        append(nodes: root.children.isEmpty ? [root] : root.children, in: bounds.insetBy(dx: 5, dy: 5), depth: 0)
        if let hoveredURL,
           let hoveredEntry = entries.first(where: { $0.node.url == hoveredURL }) {
            let size = Self.byteFormatter.string(fromByteCount: hoveredEntry.node.byteCount)
            hoverOverlay.present(
                rect: hoveredEntry.rect,
                text: "\(hoveredEntry.node.name)  ·  \(size)",
                animated: false
            )
        } else {
            self.hoveredURL = nil
            hoverOverlay.dismiss(animated: false)
        }
        needsDisplay = true
    }

    private func append(nodes: [DiskUsageNode], in rect: NSRect, depth: Int) {
        let remainingCapacity = maximumRenderedEntryCount - entries.count
        guard remainingCapacity > 0, !nodes.isEmpty, rect.width >= 2, rect.height >= 2 else { return }
        // Completed snapshots are size-sorted, so the prefix contains the
        // entries that materially affect the map. Partial snapshots retain
        // discovery order and remain useful without another large sort.
        let renderedNodes = nodes.count > remainingCapacity
            ? Array(nodes.prefix(remainingCapacity))
            : nodes
        for (node, nodeRect) in binaryLayout(nodes: renderedNodes, in: rect) {
            guard entries.count < maximumRenderedEntryCount else { return }
            guard nodeRect.width >= 1, nodeRect.height >= 1 else { continue }
            entries.append(RenderedEntry(node: node, rect: nodeRect.insetBy(dx: 1, dy: 1), depth: depth))
            guard node.isDirectory,
                  !node.children.isEmpty,
                  depth < 8,
                  nodeRect.width > 26,
                  nodeRect.height > 24 else { continue }
            let headerHeight: CGFloat = nodeRect.width > 72 && nodeRect.height > 48 ? 18 : 3
            let childRect = NSRect(
                x: nodeRect.minX + 3,
                y: nodeRect.minY + headerHeight,
                width: max(0, nodeRect.width - 6),
                height: max(0, nodeRect.height - headerHeight - 3)
            )
            append(nodes: node.children, in: childRect, depth: depth + 1)
        }
    }

    private func binaryLayout(nodes: [DiskUsageNode], in rect: NSRect) -> [(DiskUsageNode, NSRect)] {
        guard !nodes.isEmpty else { return [] }
        var sums: [Double] = [0]
        sums.reserveCapacity(nodes.count + 1)
        for node in nodes { sums.append(sums.last! + Double(max(1, node.byteCount))) }
        var pending: [(Range<Int>, NSRect)] = [(nodes.indices, rect)]
        var result: [(DiskUsageNode, NSRect)] = []
        result.reserveCapacity(nodes.count)
        while let (range, area) = pending.popLast() {
            // Subpixel regions cannot produce visible entries; don't traverse
            // thousands of tiny descendants just to discard them afterwards.
            guard area.width >= 1, area.height >= 1 else { continue }
            if range.count == 1 {
                result.append((nodes[range.lowerBound], area))
                continue
            }
            let start = range.lowerBound
            let end = range.upperBound
            let total = sums[end] - sums[start]
            let midpoint = sums[start] + total / 2
            var low = start + 1
            var high = end - 1
            while low < high {
                let middle = (low + high) / 2
                if sums[middle] < midpoint { low = middle + 1 } else { high = middle }
            }
            var split = low
            if split > start + 1, abs(sums[split - 1] - midpoint) < abs(sums[split] - midpoint) {
                split -= 1
            }
            let fraction = CGFloat((sums[split] - sums[start]) / max(1, total))
            var first = area
            var second = area
            if area.width >= area.height {
                first.size.width *= fraction
                second.origin.x += first.width
                second.size.width -= first.width
            } else {
                first.size.height *= fraction
                second.origin.y += first.height
                second.size.height -= first.height
            }
            pending.append((split..<end, second))
            pending.append((start..<split, first))
        }
        return result
    }

    private func draw(_ entry: RenderedEntry) {
        let color = color(for: entry.node, depth: entry.depth)
        let path = NSBezierPath(roundedRect: entry.rect, xRadius: 3, yRadius: 3)
        color.setFill()
        path.fill()
        NSColor.black.withAlphaComponent(0.18).setStroke()
        path.lineWidth = 0.8
        path.stroke()

        if let selectedURL, selectedURL == entry.node.url {
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 3
            path.stroke()
        }

        guard entry.rect.width > 58, entry.rect.height > 24 else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 1
        shadow.shadowOffset = NSSize(width: 0, height: 1)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: entry.rect.width > 110 ? 11 : 9, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
            .shadow: shadow
        ]
        let labelRect = entry.rect.insetBy(dx: 5, dy: 4)
        (entry.node.name as NSString).draw(in: NSRect(
            x: labelRect.minX,
            y: labelRect.minY,
            width: labelRect.width,
            height: min(16, labelRect.height)
        ), withAttributes: attributes)

        if entry.rect.width > 90, entry.rect.height > 42 {
            let sizeAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.86),
                .paragraphStyle: paragraph,
                .shadow: shadow
            ]
            (Self.byteFormatter.string(fromByteCount: entry.node.byteCount) as NSString).draw(
                in: NSRect(x: labelRect.minX, y: labelRect.minY + 16, width: labelRect.width, height: 14),
                withAttributes: sizeAttributes
            )
        }
    }

    private func entry(at point: NSPoint) -> RenderedEntry? {
        entries.reversed().first { $0.rect.contains(point) }
    }

    private func color(for node: DiskUsageNode, depth: Int) -> NSColor {
        if node.isDirectory {
            let brightness = max(0.46, 0.72 - CGFloat(depth) * 0.035)
            return NSColor(calibratedHue: 0.56, saturation: 0.58, brightness: brightness, alpha: 0.92)
        }
        let ext = (node.name as NSString).pathExtension.lowercased()
        let hue: CGFloat
        if ["jpg", "jpeg", "png", "gif", "heic", "tiff", "webp"].contains(ext) {
            hue = 0.80
        } else if ["mov", "mp4", "mkv", "avi", "m4v"].contains(ext) {
            hue = 0.98
        } else if ["mp3", "m4a", "wav", "flac", "aac"].contains(ext) {
            hue = 0.08
        } else if ["zip", "7z", "rar", "tar", "gz", "dmg", "pkg"].contains(ext) {
            hue = 0.12
        } else if ["pdf", "doc", "docx", "txt", "rtf", "pages"].contains(ext) {
            hue = 0.61
        } else {
            hue = CGFloat(abs(ext.hashValue % 100)) / 100
        }
        return NSColor(calibratedHue: hue, saturation: 0.68, brightness: 0.80, alpha: 0.94)
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}

final class DiskUsageViewController: NSViewController {
    private let rootURL: URL
    private let mapView = DiskTreemapView()
    private let pathLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let capacityProgress = NSProgressIndicator()
    private let backButton = NSButton()
    private var scanTask: Task<Void, Never>?
    private var scanWorkerTask: Task<DiskUsageNode, Error>?
    private var progressRelay: DiskUsageProgressRelay?
    private var scanGeneration = UUID()
    private var scanInProgress = false
    private var scannedItemCount = 0
    private var measuredByteCount: Int64 = 0
    private var scopeTotalByteCount: Int64 = 0
    private var volumeTotalByteCount: Int64 = 0
    private var volumeAvailableByteCount: Int64 = 0
    private var scopeIsVolumeRoot = false

    init(rootURL: URL) {
        self.rootURL = rootURL
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        progressRelay?.cancel()
        scanWorkerTask?.cancel()
        scanTask?.cancel()
    }

    override func loadView() {
        let root = NSView()
        let header = NSVisualEffectView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.material = .headerView
        header.blendingMode = .withinWindow
        root.addSubview(header)

        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: L10n.text("Back"))
        backButton.title = ""
        backButton.bezelStyle = .accessoryBarAction
        backButton.isBordered = false
        backButton.isEnabled = false
        backButton.target = self
        backButton.action = #selector(goBack(_:))
        header.addSubview(backButton)

        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.stringValue = rootURL.path
        header.addSubview(pathLabel)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        header.addSubview(spinner)

        mapView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(mapView)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        root.addSubview(statusLabel)

        capacityProgress.translatesAutoresizingMaskIntoConstraints = false
        capacityProgress.style = .bar
        capacityProgress.isIndeterminate = false
        capacityProgress.minValue = 0
        capacityProgress.maxValue = 1
        capacityProgress.doubleValue = 0
        root.addSubview(capacityProgress)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 42),
            backButton.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            backButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 28),
            backButton.heightAnchor.constraint(equalToConstant: 28),
            pathLabel.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 8),
            pathLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: spinner.leadingAnchor, constant: -8),
            spinner.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -14),
            spinner.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            mapView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            mapView.topAnchor.constraint(equalTo: header.bottomAnchor),
            mapView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -4),
            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: capacityProgress.leadingAnchor, constant: -12),
            statusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -7),
            statusLabel.heightAnchor.constraint(equalToConstant: 18),
            capacityProgress.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            capacityProgress.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            capacityProgress.widthAnchor.constraint(equalToConstant: 190),
            capacityProgress.heightAnchor.constraint(equalToConstant: 8)
        ])
        view = root

        loadVolumeCapacity()

        mapView.onHover = { [weak self] node in
            guard let self else { return }
            if let node {
                self.statusLabel.stringValue = "\(node.url.path)  ·  \(Self.byteFormatter.string(fromByteCount: node.byteCount))"
            } else {
                self.statusLabel.stringValue = self.defaultStatusText()
            }
        }
        mapView.onRootChanged = { [weak self] node, canGoBack in
            self?.pathLabel.stringValue = node.url.path
            self?.backButton.isEnabled = canGoBack
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        startScan()
    }

    private func startScan() {
        scanTask?.cancel()
        scanWorkerTask?.cancel()
        progressRelay?.cancel()
        scanGeneration = UUID()
        let generation = scanGeneration
        scanInProgress = true
        scannedItemCount = 0
        measuredByteCount = 0
        scopeTotalByteCount = 0
        spinner.isHidden = false
        spinner.startAnimation(nil)
        updateCapacityProgress()
        statusLabel.stringValue = L10n.text("Scanning folder sizes") + "…"
        let url = rootURL
        let relay = DiskUsageProgressRelay { [weak self] value in
            guard let self, self.scanGeneration == generation, self.scanInProgress else { return }
            self.scannedItemCount = value.itemCount
            self.measuredByteCount = value.root.byteCount
            self.mapView.display(rootNode: value.root, preservingNavigation: true)
            self.updateCapacityProgress()
            self.statusLabel.stringValue = self.defaultStatusText()
        }
        progressRelay = relay
        scanTask = Task { [weak self] in
            do {
                let progressHandler: @Sendable (DiskUsageNode, Int) -> Void = { partialRoot, itemCount in
                    relay.submit(root: partialRoot, itemCount: itemCount)
                }
                let worker = Task.detached(priority: .userInitiated) {
                    try DiskUsageScanner.scan(url, onProgress: progressHandler)
                }
                self?.scanWorkerTask = worker
                let rootNode = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled, let self, self.scanGeneration == generation else { return }
                self.scanWorkerTask = nil
                self.scanTask = nil
                self.progressRelay = nil
                relay.cancel()
                self.scanInProgress = false
                self.measuredByteCount = rootNode.byteCount
                self.scopeTotalByteCount = rootNode.byteCount
                self.spinner.stopAnimation(nil)
                self.spinner.isHidden = true
                self.mapView.display(rootNode: rootNode, preservingNavigation: true)
                self.updateCapacityProgress()
                self.statusLabel.stringValue = self.defaultStatusText()
            } catch {
                guard let self, self.scanGeneration == generation else { return }
                self.scanWorkerTask = nil
                self.scanTask = nil
                self.progressRelay = nil
                relay.cancel()
                self.scanInProgress = false
                self.spinner.stopAnimation(nil)
                self.spinner.isHidden = true
                self.capacityProgress.stopAnimation(nil)
                self.capacityProgress.isIndeterminate = false
                self.capacityProgress.doubleValue = 0
                self.statusLabel.stringValue = error.localizedDescription
            }
        }
    }

    private func defaultStatusText() -> String {
        let measured = Self.byteFormatter.string(fromByteCount: measuredByteCount)
        let total = Self.byteFormatter.string(fromByteCount: volumeTotalByteCount)
        let available = Self.byteFormatter.string(fromByteCount: volumeAvailableByteCount)
        let used = Self.byteFormatter.string(fromByteCount: volumeUsedByteCount)
        if !scopeIsVolumeRoot {
            if scanInProgress {
                return String(
                    format: L10n.text("Scanning: %d items · %@ measured in this folder · %@ free of %@ on drive"),
                    scannedItemCount,
                    measured,
                    available,
                    total
                )
            }
            let scopeTotal = Self.byteFormatter.string(fromByteCount: scopeTotalByteCount)
            return String(
                format: L10n.text("Measured: %@ of %@ in this folder · %@ free of %@ on drive"),
                measured,
                scopeTotal,
                available,
                total
            )
        }
        if scanInProgress {
            return String(
                format: L10n.text("Scanning: %d items · %@ measured of %@ used · %@ free of %@"),
                scannedItemCount,
                measured,
                used,
                available,
                total
            )
        }
        return String(
            format: L10n.text("Measured: %@ · %@ used · %@ free of %@"),
            measured,
            used,
            available,
            total
        )
    }

    func stopAndReleaseScan() {
        scanGeneration = UUID()
        scanInProgress = false
        progressRelay?.cancel()
        progressRelay = nil
        scanWorkerTask?.cancel()
        scanWorkerTask = nil
        scanTask?.cancel()
        scanTask = nil
        mapView.clear()
        spinner.stopAnimation(nil)
        capacityProgress.stopAnimation(nil)
    }

    private var volumeUsedByteCount: Int64 {
        max(0, volumeTotalByteCount - volumeAvailableByteCount)
    }

    private func loadVolumeCapacity() {
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]
        guard let values = try? rootURL.resourceValues(forKeys: keys) else { return }
        volumeTotalByteCount = Int64(values.volumeTotalCapacity ?? 0)
        volumeAvailableByteCount = values.volumeAvailableCapacityForImportantUsage
            ?? Int64(values.volumeAvailableCapacity ?? 0)
        let normalizedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        scopeIsVolumeRoot = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: []
        )?.contains { $0.resolvingSymlinksInPath().standardizedFileURL == normalizedRoot } == true
        updateCapacityProgress()
    }

    private func updateCapacityProgress() {
        if !scopeIsVolumeRoot, scanInProgress {
            if !capacityProgress.isIndeterminate {
                capacityProgress.isIndeterminate = true
                capacityProgress.startAnimation(nil)
            }
        } else {
            if capacityProgress.isIndeterminate {
                capacityProgress.stopAnimation(nil)
                capacityProgress.isIndeterminate = false
            }
            let denominator = scopeIsVolumeRoot ? volumeUsedByteCount : scopeTotalByteCount
            capacityProgress.doubleValue = denominator > 0
                ? min(1, Double(measuredByteCount) / Double(denominator))
                : (scanInProgress ? 0 : 1)
        }
        capacityProgress.toolTip = defaultStatusText()
    }

    @objc private func goBack(_ sender: Any?) {
        mapView.navigateBack()
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}

final class DiskUsageWindowController: NSWindowController, NSWindowDelegate {
    private static var openControllers: [DiskUsageWindowController] = []
    private let rootURL: URL

    static func present(url: URL) {
        if let existing = openControllers.first(where: { $0.rootURL == url.standardizedFileURL }) {
            if existing.window?.isMiniaturized == true { existing.window?.deminiaturize(nil) }
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = DiskUsageWindowController(url: url)
        openControllers.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init(url: URL) {
        rootURL = url.standardizedFileURL
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.text("Storage Map") + " — " + url.lastPathComponent
        window.minSize = NSSize(width: 560, height: 420)
        window.contentViewController = DiskUsageViewController(rootURL: url)
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        (contentViewController as? DiskUsageViewController)?.stopAndReleaseScan()
        contentViewController = nil
        Self.openControllers.removeAll { $0 === self }
    }
}
