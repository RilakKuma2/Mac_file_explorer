import AppKit
import UniformTypeIdentifiers

struct ZoomScrollStepResolver {
    private var accumulator: CGFloat = 0
    private var lastStepTimestamp = -Double.infinity
    private var lastDirection = 0

    mutating func consume(
        delta: CGFloat,
        precise: Bool,
        timestamp: TimeInterval
    ) -> Int? {
        guard delta.isFinite, delta != 0 else { return nil }
        let incomingDirection = delta > 0 ? 1 : -1
        if !precise {
            // A traditional wheel event is a notch, regardless of the numeric
            // scale chosen by a mouse utility. LinearMouse can emit small
            // asymmetric values, so magnitude must not make only one direction
            // work. Cap bursty synthetic streams without delaying a reversal.
            accumulator = 0
            guard incomingDirection != lastDirection
                    || timestamp - lastStepTimestamp >= 0.05 else { return nil }
            lastStepTimestamp = timestamp
            lastDirection = incomingDirection
            return incomingDirection
        }
        if accumulator != 0,
           (accumulator > 0 ? 1 : -1) != incomingDirection {
            // A small tail from the previous direction must not cancel the
            // first notch after the user reverses the wheel.
            accumulator = 0
        }
        accumulator += delta
        let threshold: CGFloat = 0.08
        guard abs(accumulator) >= threshold else { return nil }

        if incomingDirection == lastDirection,
           timestamp - lastStepTimestamp < 0.09 {
            accumulator = incomingDirection > 0 ? threshold : -threshold
            return nil
        }

        accumulator = 0
        lastStepTimestamp = timestamp
        lastDirection = incomingDirection
        return incomingDirection
    }
}

protocol FileListViewControllerDelegate: AnyObject {
    func fileList(_ fileList: FileListViewController, didActivate item: FileItem)
    func fileListSelectionDidChange(_ fileList: FileListViewController)
    func fileListDidRequestRename(_ fileList: FileListViewController)
    func fileList(_ fileList: FileListViewController, didRequestRename item: FileItem, to newName: String)
    func fileListDidRequestTrash(_ fileList: FileListViewController)
    func fileListDidRequestQuickLook(_ fileList: FileListViewController)
    func fileListDidRequestBack(_ fileList: FileListViewController)
    func fileListDidRequestForward(_ fileList: FileListViewController)
    func fileList(_ fileList: FileListViewController, didRequestImport urls: [URL], destination: URL, move: Bool)
    func fileList(_ fileList: FileListViewController, didChangeViewMode mode: FileViewMode)
}

enum FileViewMode: Int, Codable {
    case details
    case icons
}

enum FileDateGroupingMode: Int, CaseIterable, Codable {
    case automatic
    case enabled
    case disabled
}

enum FileFilterKind: Int, CaseIterable {
    case all
    case folders
    case images
    case documents
}

enum FileListContentState: Equatable {
    case content
    case loading(String)
    case empty(title: String, detail: String?)
    case failed(title: String, detail: String?)
}

private final class FileListStateOverlayView: NSView {
    var drawsBackground = true { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        if drawsBackground {
            NSColor.controlBackgroundColor.setFill()
            dirtyRect.fill()
        }
        super.draw(dirtyRect)
    }

    // Keep empty/loading/error surfaces behaving like Explorer's folder
    // background: contextual menus and blank-area clicks still reach the view.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

enum FolderSizeCalculator {
    static func logicalSize(
        of folderURL: URL,
        isCancelled: @escaping () -> Bool = { false }
    ) -> Int64? {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .totalFileSizeKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in !isCancelled() }
        ) else { return nil }

        var total: Int64 = 0
        for case let childURL as URL in enumerator {
            if isCancelled() { return nil }
            guard let values = try? childURL.resourceValues(forKeys: keys) else { continue }
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isDirectory == true { continue }

            let size = Int64(values.totalFileSize ?? values.fileSize ?? 0)
            let (sum, overflow) = total.addingReportingOverflow(size)
            total = overflow ? Int64.max : sum
        }
        return total
    }
}

private final class FolderSizeOperation: Operation, @unchecked Sendable {
    private let folderURL: URL
    private let completion: (Int64?) -> Void

    init(folderURL: URL, completion: @escaping (Int64?) -> Void) {
        self.folderURL = folderURL
        self.completion = completion
        super.init()
    }

    override func main() {
        guard !isCancelled else { return }
        let size = FolderSizeCalculator.logicalSize(of: folderURL) { [weak self] in
            self?.isCancelled ?? true
        }
        guard !isCancelled else { return }
        completion(size)
    }
}

final class ZoomScrollView: NSScrollView {
    var onCommandScroll: ((CGFloat, Bool) -> Void)?
    var onMagnify: ((CGFloat) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            onCommandScroll?(event.scrollingDeltaY, event.hasPreciseScrollingDeltas)
            return
        }
        super.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        onMagnify?(event.magnification)
    }
}

final class FileCollectionView: NSCollectionView {
    weak var keyDelegate: FileTableViewKeyDelegate?
    var onCommandScroll: ((CGFloat, Bool) -> Void)?
    var onMagnify: ((CGFloat) -> Void)?
    var onDoubleClick: ((IndexPath) -> Void)?
    var onMarqueeSelectionChanged: (() -> Void)?
    var onBlankClick: (() -> Void)?
    var onKeyDown: ((NSEvent) -> Bool)?
    var onShiftClick: ((IndexPath, Bool) -> Bool)?
    var onSelectionAnchorChanged: ((IndexPath) -> Void)?

    private var marqueeRect: NSRect? {
        didSet {
            if let oldValue { setNeedsDisplay(oldValue.insetBy(dx: -2, dy: -2)) }
            if let marqueeRect { setNeedsDisplay(marqueeRect.insetBy(dx: -2, dy: -2)) }
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            onCommandScroll?(event.scrollingDeltaY, event.hasPreciseScrollingDeltas)
            return
        }
        super.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        onMagnify?(event.magnification)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clickedPath = indexPathForItem(at: point)
        if let clickedPath {
            if event.modifierFlags.contains(.shift),
               onShiftClick?(clickedPath, event.modifierFlags.contains(.command)) == true {
                return
            }
            collapseMultipleSelectionForPlainClick(at: clickedPath, modifiers: event.modifierFlags)
            super.mouseDown(with: event)
            if !event.modifierFlags.contains(.shift) {
                onSelectionAnchorChanged?(clickedPath)
            }
            if event.clickCount == 2 { onDoubleClick?(clickedPath) }
            return
        }

        performLiveMarqueeSelection(startingAt: point, event: event)
    }

    func collapseMultipleSelectionForPlainClick(at indexPath: IndexPath, modifiers: NSEvent.ModifierFlags) {
        let selectionModifiers: NSEvent.ModifierFlags = [.command, .shift, .control]
        guard selectionIndexPaths.count > 1,
              selectionIndexPaths.contains(indexPath),
              modifiers.intersection(selectionModifiers).isEmpty else { return }
        // Avoid NSCollectionView's mouse-up delay after marquee selection.
        selectionIndexPaths = [indexPath]
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let marqueeRect, marqueeRect.intersects(dirtyRect) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
        marqueeRect.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.72).setStroke()
        let border = NSBezierPath(rect: marqueeRect.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func performLiveMarqueeSelection(startingAt startPoint: NSPoint, event: NSEvent) {
        window?.makeFirstResponder(self)
        let extendsSelection = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.shift)
        let originalSelection = extendsSelection ? selectionIndexPaths : []
        if !extendsSelection { selectionIndexPaths = [] }

        var selectionChanged = !extendsSelection
        var dragged = false
        while let window, let nextEvent = MouseTracking.nextEvent(in: window) {
            if nextEvent.type == .leftMouseUp { break }

            autoscroll(with: nextEvent)
            let currentPoint = convert(nextEvent.locationInWindow, from: nil)
            if hypot(currentPoint.x - startPoint.x, currentPoint.y - startPoint.y) >= 3 {
                dragged = true
            }
            let rect = NSRect(
                x: min(startPoint.x, currentPoint.x),
                y: min(startPoint.y, currentPoint.y),
                width: abs(currentPoint.x - startPoint.x),
                height: abs(currentPoint.y - startPoint.y)
            )
            marqueeRect = rect

            let hits = Set(
                (collectionViewLayout?.layoutAttributesForElements(in: rect) ?? [])
                    .filter { $0.representedElementCategory == .item }
                    .compactMap(\.indexPath)
            )
            let updated = originalSelection.union(hits)
            if updated != selectionIndexPaths {
                selectionIndexPaths = updated
                selectionChanged = true
            }
            window.displayIfNeeded()
        }

        marqueeRect = nil
        if selectionChanged { onMarqueeSelectionChanged?() }
        if !dragged, !extendsSelection, event.clickCount == 1 {
            onBlankClick?()
        }
    }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
        if [123, 124, 125, 126].contains(event.keyCode),
           !event.modifierFlags.contains(.shift),
           let selected = selectionIndexPaths.sorted(by: {
               $0.section == $1.section ? $0.item < $1.item : $0.section < $1.section
           }).first {
            onSelectionAnchorChanged?(selected)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let path = indexPathForItem(at: point), !selectionIndexPaths.contains(path) {
            selectionIndexPaths = [path]
            onSelectionAnchorChanged?(path)
        } else if indexPathForItem(at: point) == nil {
            selectionIndexPaths = []
        }
        return super.menu(for: event)
    }
}

private final class FileGroupDisclosureControl: NSControl {
    let disclosureImageView = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    private var isExpanded = true
    private var onToggle: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        disclosureImageView.translatesAutoresizingMaskIntoConstraints = false
        disclosureImageView.contentTintColor = .secondaryLabelColor
        disclosureImageView.imageScaling = .scaleProportionallyDown
        addSubview(disclosureImageView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            disclosureImageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            disclosureImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            disclosureImageView.widthAnchor.constraint(equalToConstant: 13),
            disclosureImageView.heightAnchor.constraint(equalToConstant: 13),
            titleLabel.leadingAnchor.constraint(equalTo: disclosureImageView.trailingAnchor, constant: 5),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.disclosureTriangle)
        setAccessibilityHelp(L10n.text("Date groups"))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, collapsed: Bool, onToggle: @escaping () -> Void) {
        titleLabel.stringValue = title
        isExpanded = !collapsed
        self.onToggle = onToggle
        disclosureImageView.image = NSImage(
            systemSymbolName: collapsed ? "chevron.right" : "chevron.down",
            accessibilityDescription: title
        )
        setAccessibilityLabel(title)
        setAccessibilityExpanded(isExpanded)
        setAccessibilityValue(isExpanded as NSNumber)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        performToggle()
    }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case 36, 49, 76: // Return, Space, keypad Enter
            performToggle()
        case 123 where isExpanded: // Left collapses
            performToggle()
        case 124 where !isExpanded: // Right expands
            performToggle()
        default:
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        performToggle()
        return true
    }

    private func performToggle() {
        onToggle?()
    }
}

private final class FileGroupTableCellView: NSTableCellView {
    let disclosureControl = FileGroupDisclosureControl()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        disclosureControl.translatesAutoresizingMaskIntoConstraints = false
        addSubview(disclosureControl)
        textField = disclosureControl.titleLabel
        imageView = disclosureControl.disclosureImageView
        setAccessibilityElement(false)
        NSLayoutConstraint.activate([
            disclosureControl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            disclosureControl.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -5),
            disclosureControl.topAnchor.constraint(equalTo: topAnchor),
            disclosureControl.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class FileGroupHeaderView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("FileGroupHeaderView")
    private let disclosureControl = FileGroupDisclosureControl()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        disclosureControl.translatesAutoresizingMaskIntoConstraints = false
        addSubview(disclosureControl)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        NSLayoutConstraint.activate([
            disclosureControl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            disclosureControl.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            disclosureControl.topAnchor.constraint(equalTo: topAnchor),
            disclosureControl.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, collapsed: Bool, onToggle: @escaping () -> Void) {
        setAccessibilityLabel(title)
        setAccessibilityChildren([disclosureControl])
        disclosureControl.configure(title: title, collapsed: collapsed, onToggle: onToggle)
    }

    func focusDisclosure() {
        window?.makeFirstResponder(disclosureControl)
    }
}

final class FileCollectionItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("FileCollectionItem")

    private let background = NSView()
    private let iconSelectionView = NSView()
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(wrappingLabelWithString: "")
    private let tagDotsView = FinderTagDotsView()
    private var iconWidthConstraint: NSLayoutConstraint?
    private var iconHeightConstraint: NSLayoutConstraint?
    private var representedURL: URL?
    private var representedItem: FileItem?
    private var requestedIconSize: CGFloat = 48
    private var thumbnailRequested = false
    private var thumbnailRequest: ThumbnailRequestToken?
    private var usesDesktopAppearance = false

    override var isSelected: Bool {
        didSet { updateSelectionAppearance() }
    }

    override func loadView() {
        let root = NSView()
        background.translatesAutoresizingMaskIntoConstraints = false
        background.wantsLayer = true
        background.layer?.cornerRadius = 7
        root.addSubview(background)

        iconSelectionView.translatesAutoresizingMaskIntoConstraints = false
        iconSelectionView.wantsLayer = true
        iconSelectionView.layer?.cornerRadius = 4
        iconSelectionView.isHidden = true
        background.addSubview(iconSelectionView)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        background.addSubview(iconView)
        imageView = iconView

        tagDotsView.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(tagDotsView)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.alignment = .center
        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.maximumNumberOfLines = 2
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.wantsLayer = true
        nameLabel.layer?.cornerRadius = 3
        nameLabel.setContentHuggingPriority(.required, for: .horizontal)
        background.addSubview(nameLabel)
        textField = nameLabel

        iconWidthConstraint = iconView.widthAnchor.constraint(equalToConstant: 48)
        iconHeightConstraint = iconView.heightAnchor.constraint(equalToConstant: 48)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 2),
            background.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -2),
            background.topAnchor.constraint(equalTo: root.topAnchor, constant: 2),
            background.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -2),
            iconView.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            iconView.topAnchor.constraint(equalTo: background.topAnchor, constant: 8),
            iconWidthConstraint!,
            iconHeightConstraint!,
            iconSelectionView.leadingAnchor.constraint(equalTo: iconView.leadingAnchor, constant: -6),
            iconSelectionView.trailingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            iconSelectionView.topAnchor.constraint(equalTo: iconView.topAnchor, constant: -5),
            iconSelectionView.bottomAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 5),
            tagDotsView.trailingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 3),
            tagDotsView.bottomAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 3),
            nameLabel.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            nameLabel.leadingAnchor.constraint(greaterThanOrEqualTo: background.leadingAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor, constant: -4),
            nameLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 4),
            nameLabel.bottomAnchor.constraint(lessThanOrEqualTo: background.bottomAnchor, constant: -4)
        ])
        view = root
    }

    func configure(
        item: FileItem,
        iconSize: CGFloat,
        displayName: String? = nil,
        desktopAppearance: Bool = false,
        isCut: Bool = false
    ) {
        cancelThumbnailRequest()
        representedURL = item.url
        representedItem = item
        usesDesktopAppearance = desktopAppearance
        requestedIconSize = iconSize
        thumbnailRequested = false
        iconWidthConstraint?.constant = iconSize
        iconHeightConstraint?.constant = iconSize
        iconView.image = FileIconProvider.shared.icon(for: item)
        tagDotsView.setColors(FinderTagPalette.colors(for: item))
        nameLabel.stringValue = displayName ?? item.name
        iconView.alphaValue = isCut ? 0.42 : 1
        tagDotsView.alphaValue = isCut ? 0.42 : 1
        nameLabel.alphaValue = isCut ? 0.52 : 1
        applyLabelAppearance()
        updateSelectionAppearance()
        view.toolTip = item.url.path
    }

    private func applyLabelAppearance() {
        guard !nameLabel.isEditable else { return }
        if usesDesktopAppearance {
            nameLabel.textColor = .white
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.92)
            shadow.shadowBlurRadius = 2
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            nameLabel.shadow = shadow
        } else {
            nameLabel.textColor = .labelColor
            nameLabel.shadow = nil
        }
    }

    private func updateSelectionAppearance() {
        guard isViewLoaded else { return }
        if usesDesktopAppearance {
            background.layer?.backgroundColor = NSColor.clear.cgColor
            iconSelectionView.isHidden = !isSelected
            iconSelectionView.layer?.backgroundColor = isSelected
                ? NSColor.black.withAlphaComponent(0.22).cgColor
                : NSColor.clear.cgColor
            iconSelectionView.layer?.borderWidth = isSelected ? 1 : 0
            iconSelectionView.layer?.borderColor = NSColor.white.withAlphaComponent(0.58).cgColor
            nameLabel.drawsBackground = isSelected && !nameLabel.isEditable
            nameLabel.backgroundColor = isSelected ? .selectedContentBackgroundColor : .clear
            nameLabel.textColor = .white
            if isSelected { nameLabel.shadow = nil }
            else { applyLabelAppearance() }
        } else {
            iconSelectionView.isHidden = true
            nameLabel.drawsBackground = false
            background.layer?.backgroundColor = isSelected
                ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.22).cgColor
                : NSColor.clear.cgColor
        }
    }

    func loadThumbnailIfNeeded() {
        guard let item = representedItem, !thumbnailRequested else { return }
        thumbnailRequested = true
        let size = requestedIconSize
        thumbnailRequest = FileIconProvider.shared.requestThumbnail(for: item, size: CGSize(width: size, height: size)) { [weak self] image in
            guard let self,
                  self.representedURL == item.url,
                  self.requestedIconSize == size,
                  let image else { return }
            self.iconView.image = image
        }
    }

    func cancelThumbnailRequest() {
        thumbnailRequest?.cancel()
        thumbnailRequest = nil
        thumbnailRequested = false
    }

    func updateTagMetadata(_ item: FileItem) {
        guard representedURL == item.url else { return }
        representedItem = item
        tagDotsView.setColors(FinderTagPalette.colors(for: item))
    }

    func beginRenaming(delegate: NSTextFieldDelegate, text: String) -> NSTextField {
        nameLabel.delegate = delegate
        nameLabel.stringValue = text
        nameLabel.isEditable = true
        nameLabel.isSelectable = true
        nameLabel.isBezeled = true
        nameLabel.bezelStyle = .squareBezel
        nameLabel.drawsBackground = true
        nameLabel.backgroundColor = .textBackgroundColor
        nameLabel.textColor = .textColor
        nameLabel.usesSingleLineMode = true
        nameLabel.maximumNumberOfLines = 1
        nameLabel.focusRingType = .exterior
        nameLabel.wantsLayer = true
        nameLabel.layer?.cornerRadius = 0
        nameLabel.layer?.borderWidth = 0
        nameLabel.layer?.borderColor = NSColor.controlAccentColor.cgColor
        nameLabel.layer?.shadowColor = NSColor.black.cgColor
        nameLabel.layer?.shadowOpacity = 0
        nameLabel.layer?.shadowRadius = 2
        nameLabel.layer?.shadowOffset = NSSize(width: 0, height: -1)
        return nameLabel
    }

    func finishRenaming(displayName: String) {
        nameLabel.delegate = nil
        nameLabel.stringValue = displayName
        nameLabel.isEditable = false
        nameLabel.isSelectable = false
        nameLabel.isBezeled = false
        nameLabel.drawsBackground = false
        nameLabel.backgroundColor = .clear
        applyLabelAppearance()
        nameLabel.usesSingleLineMode = false
        nameLabel.maximumNumberOfLines = 2
        nameLabel.focusRingType = .default
        nameLabel.layer?.borderWidth = 0
        nameLabel.layer?.shadowOpacity = 0
        updateSelectionAppearance()
    }

    func nameLabelContains(windowPoint: NSPoint) -> Bool {
        guard nameLabel.window != nil else { return false }
        return nameLabel.bounds.contains(nameLabel.convert(windowPoint, from: nil))
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelThumbnailRequest()
        nameLabel.delegate = nil
        nameLabel.isEditable = false
        nameLabel.isSelectable = false
        nameLabel.isBezeled = false
        nameLabel.drawsBackground = false
        nameLabel.backgroundColor = .clear
        nameLabel.textColor = .labelColor
        nameLabel.shadow = nil
        nameLabel.usesSingleLineMode = false
        nameLabel.maximumNumberOfLines = 2
        nameLabel.focusRingType = .default
        nameLabel.layer?.borderWidth = 0
        nameLabel.layer?.shadowOpacity = 0
        representedURL = nil
        representedItem = nil
        usesDesktopAppearance = false
        iconSelectionView.isHidden = true
        thumbnailRequested = false
        iconView.image = nil
        tagDotsView.setColors([])
    }
}

private final class FileNameTableCell: NSTableCellView {
    var representedURL: URL?
    let tagDotsView = FinderTagDotsView()
    private var thumbnailRequest: ThumbnailRequestToken?

    func loadThumbnail(for item: FileItem) {
        cancelThumbnailRequest()
        thumbnailRequest = FileIconProvider.shared.requestThumbnail(
            for: item,
            size: CGSize(width: 40, height: 40)
        ) { [weak self] image in
            guard let self, self.representedURL == item.url, let image else { return }
            self.imageView?.image = image
        }
    }

    func cancelThumbnailRequest() {
        thumbnailRequest?.cancel()
        thumbnailRequest = nil
    }

    func beginRenaming(delegate: NSTextFieldDelegate, text: String) -> NSTextField? {
        guard let textField else { return nil }
        textField.delegate = delegate
        textField.stringValue = text
        textField.isEditable = true
        textField.isSelectable = true
        textField.isBezeled = true
        textField.bezelStyle = .squareBezel
        textField.drawsBackground = true
        textField.backgroundColor = .textBackgroundColor
        textField.textColor = .textColor
        textField.usesSingleLineMode = true
        textField.focusRingType = .exterior
        textField.wantsLayer = true
        textField.layer?.cornerRadius = 0
        textField.layer?.borderWidth = 0
        textField.layer?.borderColor = NSColor.controlAccentColor.cgColor
        textField.layer?.shadowColor = NSColor.black.cgColor
        textField.layer?.shadowOpacity = 0
        textField.layer?.shadowRadius = 2
        textField.layer?.shadowOffset = NSSize(width: 0, height: -1)
        return textField
    }

    func finishRenaming(displayName: String) {
        textField?.delegate = nil
        textField?.stringValue = displayName
        textField?.isEditable = false
        textField?.isSelectable = false
        textField?.isBezeled = false
        textField?.drawsBackground = false
        textField?.backgroundColor = .clear
        textField?.textColor = .labelColor
        textField?.usesSingleLineMode = false
        textField?.focusRingType = .default
        textField?.layer?.borderWidth = 0
        textField?.layer?.shadowOpacity = 0
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelThumbnailRequest()
        textField?.delegate = nil
        textField?.isEditable = false
        textField?.isSelectable = false
        textField?.isBezeled = false
        textField?.drawsBackground = false
        textField?.backgroundColor = .clear
        textField?.textColor = .labelColor
        textField?.usesSingleLineMode = false
        textField?.focusRingType = .default
        textField?.layer?.borderWidth = 0
        textField?.layer?.shadowOpacity = 0
        representedURL = nil
        imageView?.image = nil
        tagDotsView.setColors([])
    }
}

private enum DateGroupBucket: Int, CaseIterable {
    case today
    case yesterday
    case previous7Days
    case previous30Days
    case earlier
    case noDate

    var title: String {
        switch self {
        case .today: return L10n.text("Today")
        case .yesterday: return L10n.text("Yesterday")
        case .previous7Days: return L10n.text("Previous 7 Days")
        case .previous30Days: return L10n.text("Previous 30 Days")
        case .earlier: return L10n.text("Earlier")
        case .noDate: return L10n.text("No Date")
        }
    }
}

private struct DateGroupingContext {
    let today: Date
    let tomorrow: Date
    let yesterday: Date
    let weekAgo: Date
    let monthAgo: Date

    init(now: Date = Date(), calendar: Calendar = .current) {
        today = calendar.startOfDay(for: now)
        tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        weekAgo = calendar.date(byAdding: .day, value: -7, to: today) ?? today
        monthAgo = calendar.date(byAdding: .day, value: -30, to: today) ?? weekAgo
    }

    func bucket(for date: Date?) -> DateGroupBucket {
        guard let date else { return .noDate }
        if date >= today, date < tomorrow { return .today }
        if date >= yesterday, date < today { return .yesterday }
        if date >= weekAgo { return .previous7Days }
        if date >= monthAgo { return .previous30Days }
        return .earlier
    }
}

private struct FileDisplayGroup {
    let bucket: DateGroupBucket?
    let title: String
    var items: [FileItem]
}

private enum FileTableRow {
    case group(DateGroupBucket, title: String, collapsed: Bool)
    case item(FileItem)
}

private struct FolderSizeCacheEntry {
    let modifiedAt: Date?
    let size: Int64?
    let calculatedAt: Date
}

private struct FolderSizeOperationEntry {
    let id: UUID
    let modifiedAt: Date?
    let operation: FolderSizeOperation
}

enum FileDateGroupingPolicy {
    static func shouldEnable(
        for items: [FileItem],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        let dates = items.compactMap(\.modifiedAt)
        guard dates.count >= 50 else { return false }

        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: today) ?? today
        let monthAgo = calendar.date(byAdding: .day, value: -30, to: today) ?? weekAgo
        let buckets = Set(dates.map { date -> Int in
            if date >= today, date < tomorrow { return 0 }
            if date >= yesterday, date < today { return 1 }
            if date >= weekAgo { return 2 }
            if date >= monthAgo { return 3 }
            return 4
        })
        return buckets.count >= 2
    }
}

final class FileListViewController: NSViewController,
    NSTableViewDataSource,
    NSTableViewDelegate,
    NSCollectionViewDataSource,
    NSCollectionViewDelegate,
    NSMenuDelegate,
    NSTextFieldDelegate,
    FileTableViewKeyDelegate {

    weak var delegate: FileListViewControllerDelegate?
    var onBlankClick: (() -> Void)?
    var onMetadataPrefetchRequested: (([FileItem]) -> Void)?

    private(set) var directoryURL = FileManager.default.homeDirectoryForCurrentUser
    private(set) var allItems: [FileItem] = []
    private(set) var visibleItems: [FileItem] = []

    private let tableView = FileTableView()
    private let tableScrollView = ZoomScrollView()
    private let collectionView = FileCollectionView()
    private let collectionScrollView = ZoomScrollView()
    private let stateOverlay = FileListStateOverlayView()
    private let stateImageView = NSImageView()
    private let stateSpinner = NSProgressIndicator()
    private let stateTitleLabel = NSTextField(labelWithString: "")
    private let stateDetailLabel = NSTextField(wrappingLabelWithString: "")
    private var filterText = ""
    private var kindFilter = FileFilterKind.all
    private var sort = FileSortDescriptor()
    private var suppressSortDescriptorChanges = false
    private(set) var viewMode = FileViewMode.details
    private var compactSpacing = false
    private var sessionDefaultViewProfile = FolderViewProfile(
        viewMode: .details,
        zoomLevel: 1,
        sortKey: .name,
        sortAscending: true,
        compactSpacing: false,
        showsFileExtensions: false,
        dateGroupingMode: .automatic,
        showsFolderSizes: false
    )
    private var appliedFolderViewProfile: FolderViewProfileMatch?
    private(set) var dateGroupingMode = FileDateGroupingMode.automatic
    private var automaticDateGroupingEnabled = false
    private var dateGroupingDirectoryPath: String?
    private var collapsedDateGroups: Set<DateGroupBucket> = []
    private var displayGroups: [FileDisplayGroup] = []
    private var tableRows: [FileTableRow] = []
    private var allItemIndexByPath: [String: Int] = [:]
    private var visibleItemIndexByPath: [String: Int] = [:]
    private var tableRowByPath: [String: Int] = [:]
    private var collectionIndexPathByPath: [String: IndexPath] = [:]
    private var tableOrderedItems: [FileItem] = []
    private var tableOrderIndexByPath: [String: Int] = [:]
    private var displayOrderedItems: [FileItem] = []
    private var displayOrderIndexByPath: [String: Int] = [:]
    private var selectionAnchorURL: URL?
    private var selectionExtentURL: URL?
    private var typeSelectionBuffer = ""
    private var lastTypeSelectionTime: TimeInterval = 0
    private(set) var zoomLevel = 1
    private var iconSize: CGFloat = 56
    private var zoomScrollStepResolver = ZoomScrollStepResolver()
    private var magnifyAccumulator: CGFloat = 0
    private var suppressSelectionNotifications = false
    private var zoomEventMonitor: Any?
    private var pressureActionTriggered = false
    private var lastSwipeTimestamp: TimeInterval = 0
    private weak var renamingField: NSTextField?
    private weak var renamingTableCell: FileNameTableCell?
    private weak var renamingRowView: FileTableRowView?
    private weak var renamingCollectionItem: FileCollectionItem?
    private var renamingItem: FileItem?
    private var renamingDisplayName = ""
    private var loadingOverlayWork: DispatchWorkItem?

    override func viewDidLayout() {
        super.viewDidLayout()
        clampScrollPosition()
    }

    private func clampScrollPosition() {
        guard isViewLoaded else { return }
        let scroll = viewMode == .details ? tableScrollView : collectionScrollView
        let clip = scroll.contentView
        guard clip.bounds.width > 0, clip.bounds.height > 0 else { return }
        let height: CGFloat
        if viewMode == .details {
            height = tableView.numberOfRows > 0 ? tableView.rect(ofRow: tableView.numberOfRows - 1).maxY : 0
        } else {
            height = collectionView.collectionViewLayout?.collectionViewContentSize.height ?? 0
        }
        // Headers can overlay the clip view: the actual top is negative, not 0.
        let minY = -clip.contentInsets.top
        let maxY = max(minY, height - clip.bounds.height + clip.contentInsets.bottom)
        let y = min(max(minY, clip.bounds.origin.y), maxY)
        var proposed = clip.bounds
        proposed.origin.y = y
        let constrained = clip.constrainBoundsRect(proposed).origin
        if abs(constrained.y - clip.bounds.origin.y) > 0.5 {
            clip.scroll(to: constrained)
            scroll.reflectScrolledClipView(clip)
        }
    }
    private var pendingRenameRefresh: (() -> Void)?
    private var needsReloadAfterRename = false
    private(set) var showsFileExtensions = false
    private var usesDesktopAppearance = false
    private var cutItemPaths: Set<String> = []
    private(set) var showsFolderSizes = false
    private var isContentVisible = true
    private let folderSizeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "app.macexplorer.visible-folder-sizes"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private var folderSizeCache: [String: FolderSizeCacheEntry] = [:]
    private var folderSizeOperations: [String: FolderSizeOperationEntry] = [:]
    private var metadataPrefetchWorkItem: DispatchWorkItem?
    private var cachedFileDropSources: (
        sequenceNumber: Int,
        urls: [URL],
        sources: [FileDropSource]
    )?
    private var baseEmptyTitle = L10n.text("This folder is empty.")
    private var baseEmptyDetail: String?
    private(set) var contentState = FileListContentState.content
    private static let columnWidthsKey = "ExplorerDetailsColumnWidths"
    private static let dateGroupingPreferencesKey = "ExplorerDateGroupingPreferences"
    private static let collapsedDateGroupsPreferencesKey = "ExplorerCollapsedDateGroupsPreferences"

    var isDateGroupingEnabled: Bool {
        switch dateGroupingMode {
        case .automatic:
            return automaticDateGroupingEnabled
        case .enabled:
            return true
        case .disabled:
            return false
        }
    }

    var currentKindFilter: FileFilterKind { kindFilter }

    var isReadyForFolderCommands: Bool {
        switch contentState {
        case .content, .empty: return true
        case .loading, .failed: return false
        }
    }

    var currentFolderViewProfile: FolderViewProfile {
        FolderViewProfile(
            viewMode: viewMode,
            zoomLevel: zoomLevel,
            sortKey: sort.key,
            sortAscending: sort.ascending,
            compactSpacing: compactSpacing,
            showsFileExtensions: showsFileExtensions,
            dateGroupingMode: dateGroupingMode,
            showsFolderSizes: showsFolderSizes
        )
    }

    var hasSavedViewForCurrentFolder: Bool {
        ExplorerPreferences.hasLocalFolderViewProfile(for: directoryURL)
    }

    func setCutItems(_ urls: [URL]) {
        let paths = Set(urls.map { $0.standardizedFileURL.path })
        guard paths != cutItemPaths else { return }
        cutItemPaths = paths
        guard isViewLoaded else { return }
        reloadActiveViewData()
    }

    private func isCut(_ item: FileItem) -> Bool {
        cutItemPaths.contains(item.url.standardizedFileURL.path)
    }

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.includesUnit = true
        return formatter
    }()

    var selectedItems: [FileItem] {
        switch viewMode {
        case .details:
            return tableView.selectedRowIndexes.compactMap { row in
                guard tableRows.indices.contains(row), case let .item(item) = tableRows[row] else { return nil }
                return item
            }
        case .icons:
            return collectionView.selectionIndexPaths
                .sorted {
                    $0.section == $1.section ? $0.item < $1.item : $0.section < $1.section
                }
                .compactMap(collectionItem(at:))
        }
    }

    override func loadView() {
        let root = NSView()

        tableScrollView.translatesAutoresizingMaskIntoConstraints = false
        tableScrollView.hasVerticalScroller = true
        tableScrollView.hasHorizontalScroller = true
        tableScrollView.autohidesScrollers = true
        tableScrollView.borderType = .noBorder
        tableScrollView.onCommandScroll = { [weak self] delta, precise in
            self?.handleCommandScroll(delta: delta, precise: precise)
        }
        tableScrollView.onMagnify = { [weak self] amount in self?.handleMagnify(amount) }
        tableScrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(tableViewportDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: tableScrollView.contentView
        )
        root.addSubview(tableScrollView)

        configureColumns()
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.allowsColumnResizing = true
        tableView.delegate = self
        tableView.dataSource = self
        tableView.keyDelegate = self
        tableView.onCommandScroll = { [weak self] delta, precise in
            self?.handleCommandScroll(delta: delta, precise: precise)
        }
        tableView.onMagnify = { [weak self] amount in self?.handleMagnify(amount) }
        tableView.onKeyDown = { [weak self] event in self?.handleListKeyDown(event) == true }
        tableView.onShiftClick = { [weak self] row, extending in
            guard let self,
                  self.tableRows.indices.contains(row),
                  case let .item(item) = self.tableRows[row] else { return false }
            self.selectRange(to: item, extendingSelection: extending)
            return true
        }
        tableView.onSelectionAnchorChanged = { [weak self] row in
            guard let self,
                  self.tableRows.indices.contains(row),
                  case let .item(item) = self.tableRows[row] else { return }
            if self.tableView.selectedRowIndexes.contains(row) {
                self.setSelectionAnchor(item)
            } else {
                self.synchronizeSelectionAnchorWithSelection()
            }
        }
        tableView.onNonItemClick = { [weak self] row in
            guard let self,
                  self.tableRows.indices.contains(row),
                  case let .group(bucket, _, _) = self.tableRows[row] else { return false }
            self.activateDateGroup(bucket)
            return true
        }
        tableView.isItemRow = { [weak self] row in
            guard let self, self.tableRows.indices.contains(row) else { return false }
            if case .item = self.tableRows[row] { return true }
            return false
        }
        tableView.onMarqueeSelectionChanged = { [weak self] in
            guard let self else { return }
            if let item = self.selectedItems.first { self.setSelectionAnchor(item) }
            else { self.clearSelectionAnchor() }
            self.delegate?.fileListSelectionDidChange(self)
        }
        tableView.onBlankClick = { [weak self] in
            self?.clearSelectionAnchor()
            self?.onBlankClick?()
        }
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.rowHeight = 29
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.doubleAction = #selector(didDoubleClickTable(_:))
        tableView.target = self
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.menu = makeContextMenu()
        tableScrollView.documentView = tableView

        collectionScrollView.translatesAutoresizingMaskIntoConstraints = false
        collectionScrollView.hasVerticalScroller = true
        collectionScrollView.autohidesScrollers = true
        collectionScrollView.borderType = .noBorder
        collectionScrollView.drawsBackground = !usesDesktopAppearance
        collectionScrollView.backgroundColor = usesDesktopAppearance ? .clear : .controlBackgroundColor
        collectionScrollView.onCommandScroll = { [weak self] delta, precise in
            self?.handleCommandScroll(delta: delta, precise: precise)
        }
        collectionScrollView.onMagnify = { [weak self] amount in self?.handleMagnify(amount) }
        collectionScrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(collectionViewportDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: collectionScrollView.contentView
        )
        root.addSubview(collectionScrollView)

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 112, height: 94)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.keyDelegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [usesDesktopAppearance ? .clear : .controlBackgroundColor]
        collectionView.registerForDraggedTypes([.fileURL])
        collectionView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: false)
        collectionView.register(FileCollectionItem.self, forItemWithIdentifier: FileCollectionItem.identifier)
        collectionView.register(
            FileGroupHeaderView.self,
            forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
            withIdentifier: FileGroupHeaderView.identifier
        )
        collectionView.menu = makeContextMenu()
        collectionView.onCommandScroll = { [weak self] delta, precise in
            self?.handleCommandScroll(delta: delta, precise: precise)
        }
        collectionView.onMagnify = { [weak self] amount in self?.handleMagnify(amount) }
        collectionView.onKeyDown = { [weak self] event in self?.handleListKeyDown(event) == true }
        collectionView.onShiftClick = { [weak self] indexPath, extending in
            guard let self, let item = self.collectionItem(at: indexPath) else { return false }
            self.selectRange(to: item, extendingSelection: extending)
            return true
        }
        collectionView.onSelectionAnchorChanged = { [weak self] indexPath in
            guard let self, let item = self.collectionItem(at: indexPath) else { return }
            if self.collectionView.selectionIndexPaths.contains(indexPath) {
                self.setSelectionAnchor(item)
            } else {
                self.synchronizeSelectionAnchorWithSelection()
            }
        }
        collectionView.onDoubleClick = { [weak self] indexPath in
            guard let self, let item = self.collectionItem(at: indexPath) else { return }
            self.delegate?.fileList(self, didActivate: item)
        }
        collectionView.onMarqueeSelectionChanged = { [weak self] in
            guard let self else { return }
            if let item = self.selectedItems.first { self.setSelectionAnchor(item) }
            self.delegate?.fileListSelectionDidChange(self)
        }
        collectionView.onBlankClick = { [weak self] in
            self?.clearSelectionAnchor()
            self?.onBlankClick?()
        }
        collectionScrollView.documentView = collectionView
        collectionScrollView.isHidden = true

        for scrollView in [tableScrollView, collectionScrollView] {
            NSLayoutConstraint.activate([
                scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                scrollView.topAnchor.constraint(equalTo: root.topAnchor),
                scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
            ])
        }

        configureStateOverlay(in: root)
        view = root
        installZoomEventMonitorIfNeeded()
    }

    private func configureStateOverlay(in root: NSView) {
        stateOverlay.translatesAutoresizingMaskIntoConstraints = false
        stateOverlay.isHidden = true
        stateOverlay.setAccessibilityElement(true)
        stateOverlay.setAccessibilityRole(.group)
        root.addSubview(stateOverlay)

        stateImageView.translatesAutoresizingMaskIntoConstraints = false
        stateImageView.imageScaling = .scaleProportionallyDown
        stateImageView.contentTintColor = .tertiaryLabelColor

        stateSpinner.translatesAutoresizingMaskIntoConstraints = false
        stateSpinner.style = .spinning
        stateSpinner.controlSize = .regular
        stateSpinner.isDisplayedWhenStopped = false

        stateTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        stateTitleLabel.alignment = .center
        stateTitleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        stateTitleLabel.textColor = .secondaryLabelColor

        stateDetailLabel.translatesAutoresizingMaskIntoConstraints = false
        stateDetailLabel.alignment = .center
        stateDetailLabel.font = .systemFont(ofSize: 12)
        stateDetailLabel.textColor = .tertiaryLabelColor
        stateDetailLabel.maximumNumberOfLines = 3

        let stack = NSStackView(views: [stateImageView, stateSpinner, stateTitleLabel, stateDetailLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stateOverlay.addSubview(stack)

        NSLayoutConstraint.activate([
            stateOverlay.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stateOverlay.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stateOverlay.topAnchor.constraint(equalTo: root.topAnchor),
            stateOverlay.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: stateOverlay.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: stateOverlay.centerYAnchor, constant: -18),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: stateOverlay.leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: stateOverlay.trailingAnchor, constant: -30),
            stateImageView.widthAnchor.constraint(equalToConstant: 40),
            stateImageView.heightAnchor.constraint(equalToConstant: 40),
            stateDetailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420)
        ])
    }

    func setDesktopAppearance(_ enabled: Bool) {
        usesDesktopAppearance = enabled
        guard isViewLoaded else { return }
        collectionScrollView.drawsBackground = !enabled
        collectionScrollView.backgroundColor = enabled ? .clear : .controlBackgroundColor
        collectionView.backgroundColors = [enabled ? .clear : .controlBackgroundColor]
        stateOverlay.drawsBackground = !enabled
        stateOverlay.isHidden = enabled || contentState == .content
        collectionView.reloadData()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        metadataPrefetchWorkItem?.cancel()
        cancelVisibleThumbnailRequests()
        cancelFolderSizeOperations(clearCache: true)
        removeZoomEventMonitor()
    }

    private func installZoomEventMonitorIfNeeded() {
        guard zoomEventMonitor == nil else { return }
        zoomEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.scrollWheel, .magnify, .swipe, .smartMagnify, .pressure]
        ) { [weak self] event in
            guard let self,
                  event.window === self.view.window,
                  !self.view.isHidden,
                  self.view.bounds.contains(self.view.convert(event.locationInWindow, from: nil)) else {
                return event
            }
            if event.type == .magnify {
                self.handleMagnify(event.magnification)
                return nil
            }
            if event.type == .swipe {
                self.handleSwipe(event)
                return nil
            }
            if event.type == .smartMagnify {
                self.setZoomLevel(self.viewMode == .details ? 3 : 1, focusContent: false)
                return nil
            }
            if event.type == .pressure {
                return self.handlePressure(event) ? nil : event
            }
            if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
                self.handleCommandScroll(delta: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas)
                return nil
            }
            return event
        }
    }

    private func removeZoomEventMonitor() {
        guard let zoomEventMonitor else { return }
        NSEvent.removeMonitor(zoomEventMonitor)
        self.zoomEventMonitor = nil
    }

    func showLoading(
        title: String,
        clearCurrentItems: Bool
    ) {
        if clearCurrentItems {
            cancelVisibleThumbnailRequests()
            cancelFolderSizeOperations(clearCache: true)
            allItems = []
            applyFilter(preservingSelection: [])
            clearSelectionAnchor()
        }
        setContentState(.loading(title))
    }

    func showFailure(title: String, detail: String?) {
        cancelVisibleThumbnailRequests()
        cancelFolderSizeOperations(clearCache: true)
        allItems = []
        applyFilter(preservingSelection: [])
        clearSelectionAnchor()
        setContentState(.failed(title: title, detail: detail))
    }

    func display(
        items: [FileItem],
        in directory: URL,
        preservingSelection urls: Set<URL> = [],
        emptyTitle: String? = nil,
        emptyDetail: String? = nil
    ) {
        if renamingItem != nil {
            if directoryURL.standardizedFileURL == directory.standardizedFileURL {
                pendingRenameRefresh = { [weak self] in
                    self?.display(items: items, in: directory, preservingSelection: urls,
                                  emptyTitle: emptyTitle, emptyDetail: emptyDetail)
                }
                return
            }
            pendingRenameRefresh = nil
            finishInlineRename(commit: false)
        }
        baseEmptyTitle = emptyTitle ?? L10n.text("This folder is empty.")
        baseEmptyDetail = emptyDetail
        contentState = .content
        let changedDirectory = directoryURL.standardizedFileURL != directory.standardizedFileURL
        if changedDirectory {
            cancelVisibleThumbnailRequests()
            cancelFolderSizeOperations(clearCache: true)
        }
        directoryURL = directory
        let groupingPath = directory.standardizedFileURL.path
        if dateGroupingDirectoryPath != groupingPath {
            dateGroupingDirectoryPath = groupingPath
            appliedFolderViewProfile = ExplorerPreferences.folderViewProfile(for: directory)
            var profile = appliedFolderViewProfile?.profile ?? sessionDefaultViewProfile
            if appliedFolderViewProfile == nil {
                // Keep the pre-existing folder-specific date preference as the
                // fallback. A new explicit profile always takes precedence.
                profile.dateGroupingMode = storedDateGroupingMode(for: directory)
            }
            applyFolderViewProfilePresentation(profile)
            collapsedDateGroups = storedCollapsedDateGroups(for: directory)
            selectionAnchorURL = nil
            selectionExtentURL = nil
            typeSelectionBuffer = ""
        }
        allItems = items
        automaticDateGroupingEnabled = FileDateGroupingPolicy.shouldEnable(for: items)
        applyFilter(preservingSelection: urls)
        if changedDirectory {
            if view.bounds.width > 0 { view.layoutSubtreeIfNeeded() }
            for scroll in [tableScrollView, collectionScrollView] {
                let clip = scroll.contentView
                clip.scroll(to: NSPoint(x: -clip.contentInsets.left, y: -clip.contentInsets.top))
                scroll.reflectScrolledClipView(clip)
            }
        }
        clampScrollPosition()
        scheduleVisibleFolderSizesAfterLayout()
        scheduleMetadataPrefetchAfterLayout()
    }

    private func updateEmptyState() {
        guard visibleItems.isEmpty else {
            setContentState(.content)
            return
        }
        if !allItems.isEmpty || !filterText.isEmpty || kindFilter != .all {
            setContentState(.empty(
                title: L10n.text("No items match the current filter."),
                detail: L10n.text("Try a different name or filter.")
            ))
        } else {
            setContentState(.empty(title: baseEmptyTitle, detail: baseEmptyDetail))
        }
    }

    private func setContentState(_ state: FileListContentState) {
        contentState = state
        loadingOverlayWork?.cancel()
        loadingOverlayWork = nil
        if case .loading = state {
            stateOverlay.isHidden = true
            stateSpinner.stopAnimation(nil)
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.contentState == state else { return }
                self.renderContentState(state)
                self.loadingOverlayWork = nil
            }
            loadingOverlayWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            return
        }
        renderContentState(state)
    }

    private func renderContentState(_ state: FileListContentState) {
        guard isViewLoaded else { return }
        guard !usesDesktopAppearance, state != .content else {
            stateSpinner.stopAnimation(nil)
            stateOverlay.isHidden = true
            return
        }

        let symbolName: String?
        let title: String
        let detail: String?
        switch state {
        case .content:
            return
        case .loading(let value):
            symbolName = nil
            title = value
            detail = nil
            stateSpinner.startAnimation(nil)
        case let .empty(value, stateDetail):
            symbolName = "folder"
            title = value
            detail = stateDetail
            stateSpinner.stopAnimation(nil)
        case let .failed(value, stateDetail):
            symbolName = "exclamationmark.triangle"
            title = value
            detail = stateDetail
            stateSpinner.stopAnimation(nil)
        }

        stateImageView.image = symbolName.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: title)
        }
        stateImageView.isHidden = symbolName == nil
        stateTitleLabel.stringValue = title
        stateDetailLabel.stringValue = detail ?? ""
        stateDetailLabel.isHidden = detail?.isEmpty != false
        stateOverlay.setAccessibilityLabel([title, detail].compactMap { $0 }.joined(separator: ". "))
        stateOverlay.isHidden = false
        view.addSubview(stateOverlay, positioned: .above, relativeTo: nil)
    }

    func updateTagMetadata(items: [FileItem], in directory: URL) {
        guard directoryURL.standardizedFileURL == directory.standardizedFileURL else { return }
        guard !items.isEmpty else { return }
        var changedRows = IndexSet()

        for item in items {
            let path = item.url.standardizedFileURL.path
            if let index = allItemIndexByPath[path], allItems.indices.contains(index) {
                allItems[index] = allItems[index].replacingTagMetadata(
                    tagNames: item.tagNames,
                    labelNumber: item.labelNumber
                )
            }
            if let index = visibleItemIndexByPath[path], visibleItems.indices.contains(index) {
                visibleItems[index] = visibleItems[index].replacingTagMetadata(
                    tagNames: item.tagNames,
                    labelNumber: item.labelNumber
                )
            }
            if let row = tableRowByPath[path], tableRows.indices.contains(row) {
                if case let .item(current) = tableRows[row] {
                    tableRows[row] = .item(current.replacingTagMetadata(
                        tagNames: item.tagNames,
                        labelNumber: item.labelNumber
                    ))
                    changedRows.insert(row)
                }
            }
            if let indexPath = collectionIndexPathByPath[path],
               displayGroups.indices.contains(indexPath.section),
               displayGroups[indexPath.section].items.indices.contains(indexPath.item) {
                let current = displayGroups[indexPath.section].items[indexPath.item]
                displayGroups[indexPath.section].items[indexPath.item] = current.replacingTagMetadata(
                    tagNames: item.tagNames,
                    labelNumber: item.labelNumber
                )
            }
        }

        switch viewMode {
        case .details:
            let nameColumn = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
            if let item = renamingItem,
               let row = tableRowByPath[item.url.standardizedFileURL.path] {
                changedRows.remove(row)
                if let index = allItemIndexByPath[item.url.standardizedFileURL.path],
                   allItems.indices.contains(index) {
                    renamingTableCell?.tagDotsView.setColors(FinderTagPalette.colors(for: allItems[index]))
                }
            }
            guard nameColumn >= 0, !changedRows.isEmpty else { return }
            tableView.reloadData(
                forRowIndexes: changedRows,
                columnIndexes: IndexSet(integer: nameColumn)
            )
        case .icons:
            refreshVisibleCollectionTagMetadata()
        }
    }

    private func refreshVisibleCollectionTagMetadata() {
        for case let collectionItem as FileCollectionItem in collectionView.visibleItems() {
            guard let indexPath = collectionView.indexPath(for: collectionItem),
                  let item = self.collectionItem(at: indexPath) else { continue }
            collectionItem.updateTagMetadata(item)
        }
    }

    func setFilter(_ text: String) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard filterText != normalized else { return }
        filterText = normalized
        applyFilter(preservingSelection: Set(selectedItems.map(\.url)))
    }

    func setKindFilter(_ filter: FileFilterKind) {
        kindFilter = filter
        applyFilter(preservingSelection: Set(selectedItems.map(\.url)))
    }

    func setSort(key: FileSortKey) {
        sort.key = key
        synchronizeTableSortDescriptor()
        recordSessionDefaultViewIfUnprofiled()
        applyFilter(preservingSelection: Set(selectedItems.map(\.url)))
    }

    func setSort(ascending: Bool) {
        sort.ascending = ascending
        synchronizeTableSortDescriptor()
        recordSessionDefaultViewIfUnprofiled()
        applyFilter(preservingSelection: Set(selectedItems.map(\.url)))
    }

    func setViewMode(_ mode: FileViewMode) {
        guard mode != viewMode else {
            focus()
            return
        }
        setZoomLevel(mode == .details ? 1 : max(zoomLevel, 3), focusContent: true)
    }

    func toggleCompactSpacing() {
        if viewMode == .details {
            setZoomLevel(zoomLevel == 0 ? 1 : 0, focusContent: true)
            return
        }
        compactSpacing.toggle()
        if let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout {
            layout.minimumLineSpacing = compactSpacing ? 2 : 8
            layout.minimumInteritemSpacing = compactSpacing ? 2 : 8
            layout.invalidateLayout()
        }
        recordSessionDefaultViewIfUnprofiled()
    }

    func setDateGroupingMode(_ mode: FileDateGroupingMode) {
        let preserved = Set(selectedItems.map(\.url))
        dateGroupingMode = mode
        if appliedFolderViewProfile == nil {
            persistDateGroupingMode(mode, for: directoryURL)
        }
        recordSessionDefaultViewIfUnprofiled()
        rebuildDisplayGroups()
        updateGroupLayout()
        reloadActiveViewData()
        restoreSelection(urls: preserved)
        scheduleVisibleFolderSizesAfterLayout()
        scheduleMetadataPrefetchAfterLayout()
    }

    private func handleCommandScroll(delta: CGFloat, precise: Bool) {
        guard let direction = zoomScrollStepResolver.consume(
            delta: delta,
            precise: precise,
            timestamp: ProcessInfo.processInfo.systemUptime
        ) else { return }
        adjustZoomStep(direction)
    }

    func adjustZoomStep(_ direction: Int) {
        setZoomLevel(zoomLevel + direction, focusContent: false)
    }

    func setZoomLevel(_ level: Int) {
        setZoomLevel(level, focusContent: false)
    }

    func resetZoom() {
        setZoomLevel(1, focusContent: false)
    }

    func toggleFileExtensions() {
        showsFileExtensions.toggle()
        recordSessionDefaultViewIfUnprofiled()
        reloadActiveViewData()
    }

    func toggleFolderSizes() {
        setShowsFolderSizes(!showsFolderSizes)
    }

    func setShowsFolderSizes(_ enabled: Bool) {
        guard enabled != showsFolderSizes else { return }
        showsFolderSizes = enabled
        recordSessionDefaultViewIfUnprofiled()
        cancelFolderSizeOperations(clearCache: !enabled)
        reloadSizeColumn()
        if enabled { scheduleVisibleFolderSizesAfterLayout() }
    }

    func invalidateFolderSizeCache() {
        cancelFolderSizeOperations(clearCache: true)
        guard showsFolderSizes else { return }
        reloadSizeColumn()
        scheduleVisibleFolderSizesAfterLayout()
    }

    @discardableResult
    func saveCurrentFolderView(scope: FolderViewProfileScope) -> Bool {
        let changed = ExplorerPreferences.saveFolderViewProfile(
            currentFolderViewProfile,
            for: directoryURL,
            scope: scope
        )
        // Even if the serialized value was already identical, this controller
        // should treat the current folder as profile-managed from now on.
        appliedFolderViewProfile = ExplorerPreferences.folderViewProfile(for: directoryURL)
        return changed
    }

    @discardableResult
    func resetCurrentFolderView() -> Bool {
        guard ExplorerPreferences.resetFolderViewProfile(for: directoryURL) else { return false }
        let preserved = Set(selectedItems.map(\.url))
        appliedFolderViewProfile = ExplorerPreferences.folderViewProfile(for: directoryURL)
        var fallback = appliedFolderViewProfile?.profile ?? sessionDefaultViewProfile
        if appliedFolderViewProfile == nil {
            fallback.dateGroupingMode = storedDateGroupingMode(for: directoryURL)
        }
        applyFolderViewProfilePresentation(fallback)
        applyFilter(preservingSelection: preserved)
        scheduleVisibleFolderSizesAfterLayout()
        delegate?.fileList(self, didChangeViewMode: viewMode)
        return true
    }

    private func recordSessionDefaultViewIfUnprofiled() {
        guard appliedFolderViewProfile == nil else { return }
        sessionDefaultViewProfile = currentFolderViewProfile
    }

    private func applyFolderViewProfilePresentation(_ profile: FolderViewProfile) {
        sort.key = profile.sortKey
        sort.ascending = profile.sortAscending
        synchronizeTableSortDescriptor()
        showsFileExtensions = profile.showsFileExtensions
        dateGroupingMode = profile.dateGroupingMode

        let folderSizeSettingChanged = showsFolderSizes != profile.showsFolderSizes
        showsFolderSizes = profile.showsFolderSizes
        if folderSizeSettingChanged {
            cancelFolderSizeOperations(clearCache: !showsFolderSizes)
        }

        viewMode = profile.viewMode
        switch profile.viewMode {
        case .details:
            compactSpacing = profile.compactSpacing
            zoomLevel = compactSpacing ? 0 : min(max(profile.zoomLevel, 0), 1)
            tableView.rowHeight = compactSpacing ? 22 : 29
        case .icons:
            compactSpacing = profile.compactSpacing
            zoomLevel = min(max(profile.zoomLevel, 2), 5)
            let sizes: [(icon: CGFloat, item: NSSize)] = [
                (48, NSSize(width: 104, height: 96)),
                (72, NSSize(width: 136, height: 124)),
                (112, NSSize(width: 180, height: 168)),
                (160, NSSize(width: 236, height: 220))
            ]
            let size = sizes[zoomLevel - 2]
            iconSize = size.icon
            if let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout {
                layout.itemSize = size.item
            }
        }

        if let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout {
            layout.minimumLineSpacing = compactSpacing ? 2 : 8
            layout.minimumInteritemSpacing = compactSpacing ? 2 : 8
            layout.invalidateLayout()
        }
        tableScrollView.isHidden = viewMode != .details
        collectionScrollView.isHidden = viewMode != .icons
        if viewMode == .details { cancelVisibleThumbnailRequests() }
    }

    func setContentVisible(_ visible: Bool) {
        guard visible != isContentVisible else { return }
        isContentVisible = visible
        if visible {
            reloadSizeColumn()
            scheduleVisibleFolderSizesAfterLayout()
            scheduleMetadataPrefetchAfterLayout()
        } else {
            metadataPrefetchWorkItem?.cancel()
            cancelFolderSizeOperations(clearCache: false)
        }
    }

    @objc private func tableViewportDidChange(_ notification: Notification) {
        refreshVisibleFolderSizeRequests()
        scheduleMetadataPrefetchAfterLayout()
    }

    @objc private func collectionViewportDidChange(_ notification: Notification) {
        scheduleMetadataPrefetchAfterLayout()
    }

    private func scheduleMetadataPrefetchAfterLayout() {
        guard isContentVisible else { return }
        metadataPrefetchWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isContentVisible else { return }
            let candidates = self.metadataPrefetchCandidates()
            if !candidates.isEmpty { self.onMetadataPrefetchRequested?(candidates) }
        }
        metadataPrefetchWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.075, execute: workItem)
    }

    private func metadataPrefetchCandidates(limit: Int = 150) -> [FileItem] {
        let orderedItems = flattenedItems
        guard !orderedItems.isEmpty else { return [] }
        if orderedItems.count <= limit { return orderedItems }

        let visiblePaths: Set<String>
        switch viewMode {
        case .details:
            let rows = tableView.rows(in: tableView.visibleRect)
            guard rows.location != NSNotFound, rows.length > 0 else {
                return Array(orderedItems.prefix(min(32, limit)))
            }
            let upperBound = min(tableRows.count, rows.location + rows.length)
            visiblePaths = Set(tableRows[rows.location..<upperBound].compactMap { row in
                guard case let .item(item) = row else { return nil }
                return item.url.standardizedFileURL.path
            })
        case .icons:
            visiblePaths = Set(collectionView.visibleItems().compactMap { collectionItem in
                guard let indexPath = collectionView.indexPath(for: collectionItem),
                      let item = self.collectionItem(at: indexPath) else { return nil }
                return item.url.standardizedFileURL.path
            })
        }

        guard !visiblePaths.isEmpty else { return Array(orderedItems.prefix(min(32, limit))) }
        let orderIndexes = viewMode == .details ? tableOrderIndexByPath : displayOrderIndexByPath
        let visibleIndexes = visiblePaths.compactMap { orderIndexes[$0] }.sorted()
        guard let firstVisible = visibleIndexes.first, let lastVisible = visibleIndexes.last else {
            return Array(orderedItems.prefix(min(32, limit)))
        }

        let viewportCount = max(1, visibleIndexes.count)
        var lowerBound = max(0, firstVisible - viewportCount)
        var upperBound = min(orderedItems.count, lastVisible + viewportCount + 1)
        if upperBound - lowerBound > limit {
            let center = (firstVisible + lastVisible) / 2
            lowerBound = max(0, center - limit / 2)
            upperBound = min(orderedItems.count, lowerBound + limit)
            lowerBound = max(0, upperBound - limit)
        }
        var candidates = visibleIndexes.prefix(limit).map { orderedItems[$0] }
        if candidates.count < limit {
            for index in lowerBound..<upperBound where !visiblePaths.contains(
                orderedItems[index].url.standardizedFileURL.path
            ) {
                candidates.append(orderedItems[index])
                if candidates.count == limit { break }
            }
        }
        return candidates
    }

    private func scheduleVisibleFolderSizesAfterLayout() {
        guard showsFolderSizes, isContentVisible, viewMode == .details else { return }
        DispatchQueue.main.async { [weak self] in
            self?.refreshVisibleFolderSizeRequests()
        }
    }

    private func refreshVisibleFolderSizeRequests() {
        guard showsFolderSizes, isContentVisible, viewMode == .details else {
            cancelFolderSizeOperations(clearCache: false)
            return
        }

        let visibleRows = tableView.rows(in: tableView.visibleRect)
        guard visibleRows.location != NSNotFound, visibleRows.length > 0 else {
            cancelFolderSizeOperations(clearCache: false)
            return
        }
        let upperBound = min(tableRows.count, visibleRows.location + visibleRows.length)
        guard visibleRows.location < upperBound else {
            cancelFolderSizeOperations(clearCache: false)
            return
        }

        let items = tableRows[visibleRows.location..<upperBound].compactMap { row -> FileItem? in
            guard case let .item(item) = row, item.isDirectory, !item.isSymbolicLink else { return nil }
            return item
        }
        let visiblePaths = Set(items.map { $0.url.standardizedFileURL.path })
        let hiddenPaths = folderSizeOperations.keys.filter { !visiblePaths.contains($0) }
        for path in hiddenPaths {
            folderSizeOperations[path]?.operation.cancel()
            folderSizeOperations.removeValue(forKey: path)
        }
        for item in items { requestFolderSizeIfNeeded(for: item) }
    }

    private func requestFolderSizeIfNeeded(for item: FileItem) {
        guard showsFolderSizes,
              isContentVisible,
              viewMode == .details,
              item.isDirectory,
              item.isOnLocalVolume,
              !item.isSymbolicLink else { return }
        let path = item.url.standardizedFileURL.path
        if let cached = folderSizeCache[path], isValid(cached, for: item) { return }
        folderSizeCache.removeValue(forKey: path)

        if let current = folderSizeOperations[path] {
            if current.modifiedAt == item.modifiedAt { return }
            current.operation.cancel()
            folderSizeOperations.removeValue(forKey: path)
        }

        let requestID = UUID()
        let operation = FolderSizeOperation(folderURL: item.url) { [weak self] size in
            DispatchQueue.main.async {
                guard let self,
                      self.showsFolderSizes,
                      let current = self.folderSizeOperations[path],
                      current.id == requestID else { return }
                self.folderSizeOperations.removeValue(forKey: path)
                self.folderSizeCache[path] = FolderSizeCacheEntry(
                    modifiedAt: item.modifiedAt,
                    size: size,
                    calculatedAt: Date()
                )
                self.reloadSizeCell(forPath: path)
            }
        }
        folderSizeOperations[path] = FolderSizeOperationEntry(
            id: requestID,
            modifiedAt: item.modifiedAt,
            operation: operation
        )
        folderSizeQueue.addOperation(operation)
    }

    private func folderSizeText(for item: FileItem) -> String {
        guard item.isDirectory else {
            return item.byteCount.map(byteFormatter.string(fromByteCount:)) ?? "—"
        }
        guard showsFolderSizes, !item.isSymbolicLink else { return "" }
        guard item.isOnLocalVolume else { return "—" }
        requestFolderSizeIfNeeded(for: item)
        let path = item.url.standardizedFileURL.path
        if let cached = folderSizeCache[path], isValid(cached, for: item) {
            return cached.size.map(byteFormatter.string(fromByteCount:)) ?? "—"
        }
        return folderSizeOperations[path] == nil ? "—" : L10n.text("Calculating") + "…"
    }

    private func cancelFolderSizeOperations(clearCache: Bool) {
        folderSizeQueue.cancelAllOperations()
        for entry in folderSizeOperations.values { entry.operation.cancel() }
        folderSizeOperations.removeAll()
        if clearCache { folderSizeCache.removeAll() }
    }

    private func isValid(_ entry: FolderSizeCacheEntry, for item: FileItem) -> Bool {
        entry.modifiedAt == item.modifiedAt
            && Date().timeIntervalSince(entry.calculatedAt) < 30
    }

    private func reloadSizeColumn() {
        guard isViewLoaded else { return }
        let column = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier("size"))
        guard column >= 0, !tableRows.isEmpty else { return }
        tableView.reloadData(
            forRowIndexes: IndexSet(integersIn: tableRows.indices),
            columnIndexes: IndexSet(integer: column)
        )
    }

    private func reloadSizeCell(forPath path: String) {
        guard isContentVisible,
              let row = tableRowByPath[path] else { return }
        let column = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier("size"))
        guard column >= 0 else { return }
        tableView.reloadData(
            forRowIndexes: IndexSet(integer: row),
            columnIndexes: IndexSet(integer: column)
        )
    }

    func cachedFolderSize(for url: URL) -> Int64? {
        folderSizeCache[url.standardizedFileURL.path]?.size
    }

    private func handleMagnify(_ amount: CGFloat) {
        magnifyAccumulator += amount
        guard abs(magnifyAccumulator) >= 0.075 else { return }
        let direction = magnifyAccumulator > 0 ? 1 : -1
        magnifyAccumulator = 0
        adjustZoomStep(direction)
    }

    private func handleSwipe(_ event: NSEvent) {
        guard abs(event.deltaX) > abs(event.deltaY), abs(event.deltaX) >= 0.5 else { return }
        guard event.timestamp - lastSwipeTimestamp > 0.35 else { return }
        lastSwipeTimestamp = event.timestamp
        if event.deltaX < 0 { delegate?.fileListDidRequestBack(self) }
        else { delegate?.fileListDidRequestForward(self) }
    }

    private func handlePressure(_ event: NSEvent) -> Bool {
        if event.stage == 0 {
            pressureActionTriggered = false
            return false
        }
        guard event.stage >= 2, !pressureActionTriggered else { return false }
        pressureActionTriggered = true

        let overName: Bool
        switch viewMode {
        case .details:
            let point = tableView.convert(event.locationInWindow, from: nil)
            let row = tableView.row(at: point)
            guard tableRows.indices.contains(row), case .item = tableRows[row] else { return false }
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            let nameColumn = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
            if nameColumn >= 0,
               let cell = tableView.view(atColumn: nameColumn, row: row, makeIfNecessary: true) as? FileNameTableCell,
               let field = cell.textField {
                overName = field.bounds.contains(field.convert(event.locationInWindow, from: nil))
            } else {
                overName = false
            }
        case .icons:
            let point = collectionView.convert(event.locationInWindow, from: nil)
            guard let indexPath = collectionView.indexPathForItem(at: point) else { return false }
            collectionView.selectionIndexPaths = [indexPath]
            overName = (collectionView.item(at: indexPath) as? FileCollectionItem)?
                .nameLabelContains(windowPoint: event.locationInWindow) == true
        }

        delegate?.fileListSelectionDidChange(self)
        if overName { beginInlineRename() }
        else { delegate?.fileListDidRequestQuickLook(self) }
        return true
    }

    private func setZoomLevel(_ requestedLevel: Int, focusContent: Bool) {
        let newLevel = min(max(requestedLevel, 0), 5)
        guard newLevel != zoomLevel || (newLevel <= 1 && viewMode != .details) || (newLevel >= 2 && viewMode != .icons) else { return }

        let preserved = Set(selectedItems.map(\.url))
        zoomLevel = newLevel
        viewMode = newLevel <= 1 ? .details : .icons
        tableScrollView.isHidden = viewMode != .details
        collectionScrollView.isHidden = viewMode != .icons

        if viewMode == .details {
            compactSpacing = newLevel == 0
            tableView.rowHeight = compactSpacing ? 22 : 29
            tableView.reloadData()
        } else if let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout {
            let sizes: [(icon: CGFloat, item: NSSize)] = [
                (48, NSSize(width: 104, height: 96)),
                (72, NSSize(width: 136, height: 124)),
                (112, NSSize(width: 180, height: 168)),
                (160, NSSize(width: 236, height: 220))
            ]
            let size = sizes[newLevel - 2]
            iconSize = size.icon
            layout.itemSize = size.item
            layout.invalidateLayout()
            collectionView.reloadData()
            collectionView.layoutSubtreeIfNeeded()
            refreshVisibleCollectionItems()
        }

        recordSessionDefaultViewIfUnprofiled()

        restoreSelection(urls: preserved)
        if viewMode == .details {
            reloadSizeColumn()
            scheduleVisibleFolderSizesAfterLayout()
        } else {
            cancelFolderSizeOperations(clearCache: false)
        }
        scheduleMetadataPrefetchAfterLayout()
        if focusContent { focus() }
        delegate?.fileList(self, didChangeViewMode: viewMode)
        delegate?.fileListSelectionDidChange(self)
    }

    private func refreshVisibleCollectionItems() {
        for case let collectionItem as FileCollectionItem in collectionView.visibleItems() {
            guard let indexPath = collectionView.indexPath(for: collectionItem),
                  let item = self.collectionItem(at: indexPath) else { continue }
            collectionItem.configure(
                item: item,
                iconSize: iconSize,
                displayName: displayName(for: item),
                desktopAppearance: usesDesktopAppearance,
                isCut: isCut(item)
            )
            collectionItem.loadThumbnailIfNeeded()
        }
    }

    private func cancelVisibleThumbnailRequests() {
        for case let item as FileCollectionItem in collectionView.visibleItems() {
            item.cancelThumbnailRequest()
        }
        for rowView in tableView.subviews {
            cancelThumbnailRequests(in: rowView)
        }
    }

    private func cancelThumbnailRequests(in view: NSView) {
        (view as? FileNameTableCell)?.cancelThumbnailRequest()
        for subview in view.subviews {
            cancelThumbnailRequests(in: subview)
        }
    }

    func select(url: URL) {
        let path = url.standardizedFileURL.path
        if viewMode == .details {
            guard let row = tableRowByPath[path] else { return }
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        } else {
            guard let indexPath = collectionIndexPathByPath[path] else { return }
            collectionView.selectionIndexPaths = [indexPath]
            collectionView.scrollToItems(
                at: [indexPath],
                scrollPosition: [.nearestHorizontalEdge, .nearestVerticalEdge]
            )
        }
        if let item = visibleItemIndexByPath[path].flatMap({ visibleItems.indices.contains($0) ? visibleItems[$0] : nil }) {
            setSelectionAnchor(item)
        }
    }

    func select(urls: [URL]) {
        let paths = Set(urls.map { $0.standardizedFileURL.path })
        guard !paths.isEmpty else { return }

        if isDateGroupingEnabled {
            let context = DateGroupingContext()
            let groupsToReveal = Set(allItems.compactMap { item -> DateGroupBucket? in
                guard paths.contains(item.url.standardizedFileURL.path) else { return nil }
                return context.bucket(for: item.modifiedAt)
            })
            if !collapsedDateGroups.isDisjoint(with: groupsToReveal) {
                collapsedDateGroups.subtract(groupsToReveal)
                persistCollapsedDateGroups(for: directoryURL)
                rebuildDisplayGroups()
                reloadActiveViewData()
                scheduleMetadataPrefetchAfterLayout()
            }
        }

        let matchingURLs = Set(paths.compactMap { path -> URL? in
            guard let index = allItemIndexByPath[path], allItems.indices.contains(index) else { return nil }
            return allItems[index].url
        })
        restoreSelection(urls: matchingURLs)
        if let index = paths.compactMap({ visibleItemIndexByPath[$0] }).min(),
           visibleItems.indices.contains(index) {
            let first = visibleItems[index]
            setSelectionAnchor(first)
            scrollItemToVisible(first)
        }
        delegate?.fileListSelectionDidChange(self)
    }

    private var flattenedItems: [FileItem] {
        viewMode == .details ? tableOrderedItems : displayOrderedItems
    }

    private func setSelectionAnchor(_ item: FileItem) {
        selectionAnchorURL = item.url
        selectionExtentURL = item.url
        typeSelectionBuffer = ""
    }

    private func clearSelectionAnchor() {
        selectionAnchorURL = nil
        selectionExtentURL = nil
        typeSelectionBuffer = ""
    }

    private func synchronizeSelectionAnchorWithSelection() {
        let selection = selectedItems
        guard !selection.isEmpty else {
            clearSelectionAnchor()
            return
        }

        let selectedPaths = Set(selection.map { $0.url.standardizedFileURL.path })
        if let selectionAnchorURL,
           selectedPaths.contains(selectionAnchorURL.standardizedFileURL.path) {
            if let selectionExtentURL,
               selectedPaths.contains(selectionExtentURL.standardizedFileURL.path) {
                return
            }
            self.selectionExtentURL = selectionAnchorURL
            return
        }
        setSelectionAnchor(selection[0])
    }

    private func selectRange(to target: FileItem, extendingSelection: Bool) {
        let items = flattenedItems
        guard let targetIndex = items.firstIndex(where: { $0.url == target.url }) else { return }
        let anchorURL = selectionAnchorURL ?? selectedItems.first?.url ?? target.url
        guard let anchorIndex = items.firstIndex(where: { $0.url == anchorURL }) else {
            select(url: target.url)
            delegate?.fileListSelectionDidChange(self)
            return
        }

        let bounds = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
        var urls = Set(bounds.map { items[$0].url })
        if extendingSelection { urls.formUnion(selectedItems.map(\.url)) }
        selectionAnchorURL = items[anchorIndex].url
        selectionExtentURL = target.url
        restoreSelection(urls: urls)
        scrollItemToVisible(target)
        delegate?.fileListSelectionDidChange(self)
    }

    private func scrollItemToVisible(_ item: FileItem) {
        let path = item.url.standardizedFileURL.path
        if viewMode == .details {
            if let row = tableRowByPath[path] {
                tableView.scrollRowToVisible(row)
            }
        } else if let indexPath = collectionIndexPathByPath[path] {
            collectionView.scrollToItems(
                at: [indexPath],
                scrollPosition: [.nearestHorizontalEdge, .nearestVerticalEdge]
            )
        }
    }

    private func handleListKeyDown(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.shift), handleShiftNavigation(event) { return true }
        guard let fragment = typeSelectionFragment(from: event) else { return false }
        performTypeSelection(with: fragment, timestamp: event.timestamp)
        return true
    }

    private func handleShiftNavigation(_ event: NSEvent) -> Bool {
        let delta: Int
        switch (viewMode, event.keyCode) {
        case (.details, 125): delta = 1
        case (.details, 126): delta = -1
        case (.icons, 123): delta = -1
        case (.icons, 124): delta = 1
        case (.icons, 125): delta = collectionColumnCount
        case (.icons, 126): delta = -collectionColumnCount
        default: return false
        }

        let items = flattenedItems
        guard !items.isEmpty else { return true }
        let currentURL = selectionExtentURL ?? selectedItems.last?.url
        let currentIndex = currentURL.flatMap { url in items.firstIndex(where: { $0.url == url }) }
            ?? (delta < 0 ? items.count : -1)
        let targetIndex = min(items.count - 1, max(0, currentIndex + delta))
        if selectionAnchorURL == nil {
            let anchorIndex = min(items.count - 1, max(0, currentIndex))
            selectionAnchorURL = items[anchorIndex].url
        }
        selectRange(to: items[targetIndex], extendingSelection: event.modifierFlags.contains(.command))
        return true
    }

    private var collectionColumnCount: Int {
        guard let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout else { return 1 }
        let width = max(1, collectionView.visibleRect.width - layout.sectionInset.left - layout.sectionInset.right)
        let stride = max(1, layout.itemSize.width + layout.minimumInteritemSpacing)
        return max(1, Int((width + layout.minimumInteritemSpacing) / stride))
    }

    private func typeSelectionFragment(from event: NSEvent) -> String? {
        let blockedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        guard event.modifierFlags.intersection(blockedModifiers).isEmpty,
              ![36, 48, 49, 51, 53, 76, 117, 123, 124, 125, 126].contains(event.keyCode),
              let characters = event.characters,
              !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({
                  !CharacterSet.whitespacesAndNewlines.contains($0)
                      && !CharacterSet.controlCharacters.contains($0)
              }) else {
            return nil
        }
        return characters
    }

    private func performTypeSelection(with fragment: String, timestamp: TimeInterval) {
        let items = flattenedItems
        guard !items.isEmpty else { return }
        let expired = timestamp - lastTypeSelectionTime > 0.9
        let normalizedFragment = normalizedTypeSelectionText(fragment)
        let repeatedSingleCharacter = !expired
            && normalizedTypeSelectionText(typeSelectionBuffer) == normalizedFragment
            && normalizedFragment.count == 1

        if expired || typeSelectionBuffer.isEmpty {
            typeSelectionBuffer = fragment
        } else if !repeatedSingleCharacter {
            typeSelectionBuffer += fragment
        }
        lastTypeSelectionTime = timestamp

        let currentIndex = selectedItems.first.flatMap { selected in
            items.firstIndex(where: { $0.url == selected.url })
        } ?? -1
        let startIndex = repeatedSingleCharacter ? currentIndex + 1 : 0

        func match(for query: String, startingAt start: Int) -> FileItem? {
            let normalizedQuery = normalizedTypeSelectionText(query)
            guard !normalizedQuery.isEmpty else { return nil }
            for offset in 0..<items.count {
                let index = (max(0, start) + offset) % items.count
                if normalizedTypeSelectionText(displayName(for: items[index])).hasPrefix(normalizedQuery) {
                    return items[index]
                }
            }
            return nil
        }

        var matched = match(for: typeSelectionBuffer, startingAt: startIndex)
        if matched == nil, typeSelectionBuffer != fragment {
            typeSelectionBuffer = fragment
            matched = match(for: fragment, startingAt: currentIndex + 1)
        }
        guard let matched else { return }
        let activeBuffer = typeSelectionBuffer
        select(url: matched.url)
        typeSelectionBuffer = activeBuffer
        delegate?.fileListSelectionDidChange(self)
    }

    private func normalizedTypeSelectionText(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }

    func focus() {
        view.window?.makeFirstResponder(viewMode == .details ? tableView : collectionView)
    }

    func beginInlineRename() {
        guard let item = selectedItems.first, selectedItems.count == 1 else { return }
        finishInlineRename(commit: false)

        let fullName = item.url.lastPathComponent
        let fileExtension = item.isDirectory ? "" : item.url.pathExtension
        let editingText = fullName
        let field: NSTextField?

        switch viewMode {
        case .details:
            guard let row = tableRows.firstIndex(where: {
                guard case let .item(candidate) = $0 else { return false }
                return candidate.url.standardizedFileURL == item.url.standardizedFileURL
            }),
            let column = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("name")) else { return }
            tableView.scrollRowToVisible(row)
            let columnIndex = tableView.tableColumns.firstIndex(of: column) ?? 0
            guard let cell = tableView.view(atColumn: columnIndex, row: row, makeIfNecessary: true) as? FileNameTableCell else { return }
            renamingTableCell = cell
            renamingRowView = tableView.rowView(atRow: row, makeIfNecessary: true) as? FileTableRowView
            renamingRowView?.isRenaming = true
            field = cell.beginRenaming(delegate: self, text: editingText)
        case .icons:
            guard let indexPath = collectionIndexPath(for: item.url) else { return }
            collectionView.scrollToItems(at: [indexPath], scrollPosition: .nearestHorizontalEdge)
            collectionView.layoutSubtreeIfNeeded()
            guard let collectionItem = collectionView.item(at: indexPath) as? FileCollectionItem else { return }
            renamingCollectionItem = collectionItem
            field = collectionItem.beginRenaming(delegate: self, text: editingText)
        }

        guard let field else { return }
        renamingField = field
        renamingItem = item
        renamingDisplayName = displayName(for: item)
        view.window?.makeFirstResponder(field)
        // makeFirstResponder already starts field editing. Calling selectText
        // again ends that session and runs our rename completion delegate.
        if let editor = field.currentEditor() as? NSTextView {
            editor.drawsBackground = true
            editor.backgroundColor = .textBackgroundColor
            editor.textColor = .textColor
            editor.insertionPointColor = .textColor
            let selectionLength = !item.isDirectory && !fileExtension.isEmpty
                ? max(0, (fullName as NSString).length - (fileExtension as NSString).length - 1)
                : (editingText as NSString).length
            editor.selectedRange = NSRange(location: 0, length: selectionLength)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === renamingField else { return false }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            finishInlineRename(commit: false)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            finishInlineRename(commit: true)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === renamingField else { return }
        let movement = (obj.userInfo?[NSText.movementUserInfoKey] as? NSNumber)?.intValue
        finishInlineRename(commit: movement != NSTextMovement.cancel.rawValue)
    }

    private func finishInlineRename(commit: Bool) {
        guard let field = renamingField, let item = renamingItem else { return }
        let proposedName = (field.currentEditor()?.string ?? field.stringValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let originalName = item.url.lastPathComponent

        let tableCell = renamingTableCell
        let collectionItem = renamingCollectionItem
        let oldDisplayName = renamingDisplayName
        renamingField = nil
        renamingRowView?.isRenaming = false
        renamingRowView = nil
        renamingTableCell = nil
        renamingCollectionItem = nil
        renamingItem = nil
        renamingDisplayName = ""
        field.delegate = nil
        if field.currentEditor() != nil { focus() }
        tableCell?.finishRenaming(displayName: oldDisplayName)
        collectionItem?.finishRenaming(displayName: oldDisplayName)
        let refresh = pendingRenameRefresh
        pendingRenameRefresh = nil
        if needsReloadAfterRename {
            needsReloadAfterRename = false
            reloadActiveViewData()
        }
        refresh?()

        if commit, !proposedName.isEmpty, proposedName != originalName {
            delegate?.fileList(self, didRequestRename: item, to: proposedName)
        } else {
            focus()
        }
    }

    func selectAllItems() {
        if viewMode == .details {
            let rows = tableRows.indices.filter {
                if case .item = tableRows[$0] { return true }
                return false
            }
            tableView.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
        } else {
            collectionView.selectionIndexPaths = Set(collectionIndexPathByPath.values)
            delegate?.fileListSelectionDidChange(self)
        }
    }

    func invertSelection() {
        let selectedURLs = Set(selectedItems.map(\.url))
        let inverted = Set(visibleItems.map(\.url).filter { !selectedURLs.contains($0) })
        restoreSelection(urls: inverted)
        delegate?.fileListSelectionDidChange(self)
    }

    func selectItemsWithSameExtension() {
        guard let reference = selectedItems.first, !reference.isDirectory else { return }
        let fileExtension = reference.url.pathExtension.lowercased()
        let matching = Set(visibleItems.filter {
            !$0.isDirectory && $0.url.pathExtension.lowercased() == fileExtension
        }.map(\.url))
        restoreSelection(urls: matching)
        delegate?.fileListSelectionDidChange(self)
    }

    @discardableResult
    func selectItems(
        matching pattern: String,
        usesRegularExpression: Bool,
        caseSensitive: Bool,
        includesFolders: Bool
    ) throws -> Int {
        let expression: String
        if usesRegularExpression {
            expression = pattern
        } else {
            let masks = pattern
                .split(whereSeparator: { $0 == ";" || $0 == "," })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !masks.isEmpty else { return 0 }
            expression = masks.map { mask in
                let escaped = NSRegularExpression.escapedPattern(for: mask)
                    .replacingOccurrences(of: "\\*", with: ".*")
                    .replacingOccurrences(of: "\\?", with: ".")
                return "(?:\(escaped))"
            }.joined(separator: "|")
        }

        let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
        let regex = try NSRegularExpression(pattern: "^(?:\(expression))$", options: options)
        let matches = Set(visibleItems.compactMap { item -> URL? in
            guard includesFolders || !item.isDirectory else { return nil }
            let range = NSRange(item.name.startIndex..<item.name.endIndex, in: item.name)
            return regex.firstMatch(in: item.name, range: range) == nil ? nil : item.url
        })
        restoreSelection(urls: matches)
        delegate?.fileListSelectionDidChange(self)
        return matches.count
    }

    private func collectionItem(at indexPath: IndexPath) -> FileItem? {
        guard displayGroups.indices.contains(indexPath.section),
              displayGroups[indexPath.section].items.indices.contains(indexPath.item) else { return nil }
        return displayGroups[indexPath.section].items[indexPath.item]
    }

    private func collectionIndexPath(for url: URL) -> IndexPath? {
        collectionIndexPathByPath[url.standardizedFileURL.path]
    }

    private func rebuildDisplayGroups() {
        guard isDateGroupingEnabled else {
            displayGroups = [FileDisplayGroup(bucket: nil, title: "", items: visibleItems)]
            tableRows = visibleItems.map(FileTableRow.item)
            rebuildPathIndexes()
            return
        }

        let context = DateGroupingContext()
        var buckets: [DateGroupBucket: [FileItem]] = [:]
        for item in visibleItems {
            buckets[context.bucket(for: item.modifiedAt), default: []].append(item)
        }
        displayGroups = DateGroupBucket.allCases.compactMap { bucket in
            guard let items = buckets[bucket], !items.isEmpty else { return nil }
            return FileDisplayGroup(bucket: bucket, title: bucket.title, items: items)
        }
        tableRows = displayGroups.flatMap { group in
            guard let bucket = group.bucket else { return group.items.map(FileTableRow.item) }
            let collapsed = collapsedDateGroups.contains(bucket)
            return [FileTableRow.group(bucket, title: group.title, collapsed: collapsed)]
                + (collapsed ? [] : group.items.map(FileTableRow.item))
        }
        rebuildPathIndexes()
    }

    private func rebuildPathIndexes() {
        allItemIndexByPath = Dictionary(uniqueKeysWithValues: allItems.indices.map {
            (allItems[$0].pathKey, $0)
        })
        visibleItemIndexByPath = Dictionary(uniqueKeysWithValues: visibleItems.indices.map {
            (visibleItems[$0].pathKey, $0)
        })
        var tableRowsByPath: [String: Int] = [:]
        var orderedTableItems: [FileItem] = []
        orderedTableItems.reserveCapacity(visibleItems.count)
        for row in tableRows.indices {
            guard case let .item(item) = tableRows[row] else { continue }
            tableRowsByPath[item.pathKey] = row
            orderedTableItems.append(item)
        }
        tableRowByPath = tableRowsByPath
        tableOrderedItems = orderedTableItems
        tableOrderIndexByPath = Dictionary(uniqueKeysWithValues: orderedTableItems.indices.map {
            (orderedTableItems[$0].pathKey, $0)
        })
        var collectionIndexes: [String: IndexPath] = [:]
        collectionIndexes.reserveCapacity(visibleItems.count)
        var orderedItems: [FileItem] = []
        orderedItems.reserveCapacity(visibleItems.count)
        for section in displayGroups.indices {
            if let bucket = displayGroups[section].bucket,
               collapsedDateGroups.contains(bucket) {
                continue
            }
            for itemIndex in displayGroups[section].items.indices {
                let item = displayGroups[section].items[itemIndex]
                collectionIndexes[item.pathKey] = IndexPath(item: itemIndex, section: section)
                orderedItems.append(item)
            }
        }
        collectionIndexPathByPath = collectionIndexes
        displayOrderedItems = orderedItems
        displayOrderIndexByPath = Dictionary(uniqueKeysWithValues: orderedItems.indices.map {
            (orderedItems[$0].pathKey, $0)
        })
    }

    private func toggleDateGroup(_ bucket: DateGroupBucket) {
        if collapsedDateGroups.contains(bucket) { collapsedDateGroups.remove(bucket) }
        else { collapsedDateGroups.insert(bucket) }
        persistCollapsedDateGroups(for: directoryURL)
        rebuildDisplayGroups()
        reloadActiveViewData()
        scheduleVisibleFolderSizesAfterLayout()
        scheduleMetadataPrefetchAfterLayout()
    }

    private func activateDateGroup(_ bucket: DateGroupBucket) {
        suppressSelectionNotifications = true
        tableView.deselectAll(nil)
        collectionView.selectionIndexPaths = []
        suppressSelectionNotifications = false
        clearSelectionAnchor()
        toggleDateGroup(bucket)
        delegate?.fileListSelectionDidChange(self)
        DispatchQueue.main.async { [weak self] in
            self?.focusDateGroupDisclosure(bucket)
        }
    }

    private func focusDateGroupDisclosure(_ bucket: DateGroupBucket) {
        guard let section = displayGroups.firstIndex(where: { $0.bucket == bucket }) else { return }
        switch viewMode {
        case .details:
            guard let row = tableRows.firstIndex(where: { row in
                guard case let .group(rowBucket, _, _) = row else { return false }
                return rowBucket == bucket
            }),
            let cell = tableView.view(
                atColumn: max(0, tableView.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))),
                row: row,
                makeIfNecessary: true
            ) as? FileGroupTableCellView else { return }
            tableView.window?.makeFirstResponder(cell.disclosureControl)
        case .icons:
            collectionView.layoutSubtreeIfNeeded()
            let indexPath = IndexPath(item: 0, section: section)
            let supplementaryView: NSView? = collectionView.supplementaryView(
                forElementKind: NSCollectionView.elementKindSectionHeader,
                at: indexPath
            )
            (supplementaryView as? FileGroupHeaderView)?.focusDisclosure()
        }
    }

    private func storedDateGroupingMode(for directory: URL) -> FileDateGroupingMode {
        let path = directory.standardizedFileURL.path
        let preferences = UserDefaults.standard.dictionary(forKey: Self.dateGroupingPreferencesKey) ?? [:]
        guard let rawValue = (preferences[path] as? NSNumber)?.intValue else { return .automatic }
        return FileDateGroupingMode(rawValue: rawValue) ?? .automatic
    }

    private func persistDateGroupingMode(_ mode: FileDateGroupingMode, for directory: URL) {
        let path = directory.standardizedFileURL.path
        var preferences = UserDefaults.standard.dictionary(forKey: Self.dateGroupingPreferencesKey) ?? [:]
        if mode == .automatic {
            preferences.removeValue(forKey: path)
        } else {
            preferences[path] = mode.rawValue
        }
        UserDefaults.standard.set(preferences, forKey: Self.dateGroupingPreferencesKey)
    }

    private func storedCollapsedDateGroups(for directory: URL) -> Set<DateGroupBucket> {
        let path = directory.standardizedFileURL.path
        let preferences = UserDefaults.standard.dictionary(forKey: Self.collapsedDateGroupsPreferencesKey) ?? [:]
        let values = preferences[path] as? [Int] ?? []
        return Set(values.compactMap(DateGroupBucket.init(rawValue:)))
    }

    private func persistCollapsedDateGroups(for directory: URL) {
        let path = directory.standardizedFileURL.path
        var preferences = UserDefaults.standard.dictionary(forKey: Self.collapsedDateGroupsPreferencesKey) ?? [:]
        if collapsedDateGroups.isEmpty {
            preferences.removeValue(forKey: path)
        } else {
            preferences[path] = collapsedDateGroups.map(\.rawValue).sorted()
        }
        UserDefaults.standard.set(preferences, forKey: Self.collapsedDateGroupsPreferencesKey)
    }

    private func updateGroupLayout() {
        guard let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout else { return }
        layout.headerReferenceSize = isDateGroupingEnabled ? NSSize(width: 100, height: 32) : .zero
        layout.sectionInset = NSEdgeInsets(
            top: isDateGroupingEnabled ? 6 : 16,
            left: 18,
            bottom: 16,
            right: 18
        )
    }

    private func configureColumns() {
        let definitions: [(String, String, CGFloat, CGFloat)] = [
            ("name", L10n.text("Name"), 320, 80),
            ("modified", L10n.text("Date modified"), 180, 95),
            ("kind", L10n.text("Type"), 170, 75),
            ("size", L10n.text("Size"), 110, 65)
        ]
        let savedWidths = UserDefaults.standard.dictionary(forKey: Self.columnWidthsKey) ?? [:]

        for (identifier, title, width, minWidth) in definitions {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = (savedWidths[identifier] as? NSNumber).map { CGFloat($0.doubleValue) } ?? width
            column.minWidth = minWidth
            column.maxWidth = 1_200
            column.resizingMask = .userResizingMask
            column.sortDescriptorPrototype = NSSortDescriptor(key: identifier, ascending: true)
            tableView.addTableColumn(column)
        }

        // Keep the document view at least as wide as its viewport without
        // stretching the data columns. This trailing blank column is also the
        // Windows-style marquee-selection surface.
        let spacer = NSTableColumn(identifier: FileTableView.spacerColumnIdentifier)
        spacer.title = ""
        spacer.width = 40
        spacer.minWidth = 1
        spacer.maxWidth = 100_000
        spacer.resizingMask = .autoresizingMask
        tableView.addTableColumn(spacer)
        synchronizeTableSortDescriptor()
    }

    private func synchronizeTableSortDescriptor() {
        let key: String
        switch sort.key {
        case .name: key = "name"
        case .modifiedAt: key = "modified"
        case .kind: key = "kind"
        case .size: key = "size"
        }
        if let current = tableView.sortDescriptors.first,
           current.key == key,
           current.ascending == sort.ascending,
           tableView.sortDescriptors.count == 1 {
            return
        }
        suppressSortDescriptorChanges = true
        tableView.sortDescriptors = [NSSortDescriptor(key: key, ascending: sort.ascending)]
        suppressSortDescriptorChanges = false
    }

    private func applyFilter(preservingSelection urls: Set<URL>) {
        let filtered = allItems.filter { item in
            let matchesText = filterText.isEmpty
                || item.name.localizedCaseInsensitiveContains(filterText)
                || item.kind.localizedCaseInsensitiveContains(filterText)
            let matchesKind: Bool
            switch kindFilter {
            case .all:
                matchesKind = true
            case .folders:
                matchesKind = item.isDirectory
            case .images:
                matchesKind = ["png", "jpg", "jpeg", "gif", "heic", "tiff", "webp", "svg"].contains(item.url.pathExtension.lowercased())
            case .documents:
                matchesKind = ["txt", "rtf", "pdf", "doc", "docx", "pages", "md", "csv", "xls", "xlsx"].contains(item.url.pathExtension.lowercased())
            }
            return matchesText && matchesKind
        }
        visibleItems = sort.sort(filtered)
        rebuildDisplayGroups()
        updateGroupLayout()
        reloadActiveViewData()
        restoreSelection(urls: urls)
        updateEmptyState()
        delegate?.fileListSelectionDidChange(self)
        scheduleVisibleFolderSizesAfterLayout()
        scheduleMetadataPrefetchAfterLayout()
    }

    private func reloadActiveViewData() {
        guard renamingItem == nil else {
            needsReloadAfterRename = true
            return
        }
        switch viewMode {
        case .details:
            tableView.reloadData()
        case .icons:
            collectionView.reloadData()
            collectionView.collectionViewLayout?.invalidateLayout()
            collectionView.needsLayout = true
            collectionView.needsDisplay = true
            collectionScrollView.contentView.needsDisplay = true
            collectionScrollView.needsDisplay = true
        }
    }

    private func restoreSelection(urls: Set<URL>) {
        suppressSelectionNotifications = true
        let paths = urls.map { $0.standardizedFileURL.path }
        if viewMode == .details {
            let rows = paths.compactMap { tableRowByPath[$0] }
            tableView.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
        } else {
            collectionView.selectionIndexPaths = Set(paths.compactMap { collectionIndexPathByPath[$0] })
        }
        suppressSelectionNotifications = false
    }

    @objc private func didDoubleClickTable(_ sender: Any?) {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard tableRows.indices.contains(row), case let .item(item) = tableRows[row] else { return }
        delegate?.fileList(self, didActivate: item)
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        // AppKit may append a second contextual Services plug-in after the
        // delegate has built the menu. We provide the native Services submenu
        // ourselves so its placement relative to Get Info stays deterministic.
        menu.allowsContextMenuPlugIns = false
        menu.delegate = self
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let items = selectedItems
        let urls = items.map(\.url)

        if items.isEmpty {
            addItem(to: menu, title: L10n.text("New Folder"), symbol: "folder.badge.plus", action: #selector(MainViewController.newFolder(_:)), enabled: true)
            let canPaste = NSPasteboard.general.types?.contains(.fileURL) == true
            if canPaste {
                addItem(to: menu, title: L10n.text("Paste"), symbol: "clipboard", action: #selector(MainViewController.paste(_:)), enabled: true)
            }
            menu.addItem(.separator())

            let viewMenu = NSMenu(title: L10n.text("View"))
            viewMenu.autoenablesItems = false
            let icons = NSMenuItem(title: L10n.text("as Icons"), action: #selector(MainViewController.showIconView(_:)), keyEquivalent: "")
            icons.state = viewMode == .icons ? .on : .off
            viewMenu.addItem(icons)
            let list = NSMenuItem(title: L10n.text("as List"), action: #selector(MainViewController.showDetailsView(_:)), keyEquivalent: "")
            list.state = viewMode == .details ? .on : .off
            viewMenu.addItem(list)
            let folderSizes = NSMenuItem(
                title: L10n.text("Show folder sizes"),
                action: #selector(MainViewController.toggleFolderSizes(_:)),
                keyEquivalent: ""
            )
            folderSizes.state = showsFolderSizes ? .on : .off
            folderSizes.isEnabled = viewMode == .details && isReadyForFolderCommands
            viewMenu.addItem(folderSizes)
            viewMenu.addItem(.separator())
            let saveView = NSMenuItem(
                title: L10n.text("Save View for This Folder"),
                action: #selector(MainViewController.saveViewForThisFolder(_:)),
                keyEquivalent: ""
            )
            saveView.isEnabled = isReadyForFolderCommands
            viewMenu.addItem(saveView)
            let applySubfolders = NSMenuItem(
                title: L10n.text("Apply View to Subfolders"),
                action: #selector(MainViewController.applyViewToSubfolders(_:)),
                keyEquivalent: ""
            )
            applySubfolders.isEnabled = isReadyForFolderCommands
            viewMenu.addItem(applySubfolders)
            let resetView = NSMenuItem(
                title: L10n.text("Reset Folder View"),
                action: #selector(MainViewController.resetFolderView(_:)),
                keyEquivalent: ""
            )
            resetView.isEnabled = isReadyForFolderCommands && hasSavedViewForCurrentFolder
            viewMenu.addItem(resetView)
            let viewItem = NSMenuItem(title: L10n.text("View"), action: nil, keyEquivalent: "")
            viewItem.submenu = viewMenu
            menu.addItem(viewItem)

            let groupingMenu = NSMenu(title: L10n.text("Date groups"))
            groupingMenu.autoenablesItems = false
            [(L10n.text("Automatic"), FileDateGroupingMode.automatic),
             (L10n.text("On"), FileDateGroupingMode.enabled),
             (L10n.text("Off"), FileDateGroupingMode.disabled)].forEach { title, mode in
                let item = NSMenuItem(title: title, action: #selector(setDateGroupingModeFromContextMenu(_:)), keyEquivalent: "")
                item.target = self
                item.tag = mode.rawValue
                item.state = dateGroupingMode == mode ? .on : .off
                item.isEnabled = true
                groupingMenu.addItem(item)
            }
            let groupingItem = NSMenuItem(title: L10n.text("Date groups"), action: nil, keyEquivalent: "")
            groupingItem.submenu = groupingMenu
            menu.addItem(groupingItem)

            let sortMenu = NSMenu(title: L10n.text("Sort By"))
            sortMenu.autoenablesItems = false
            [(L10n.text("Name"), FileSortKey.name),
             (L10n.text("Date modified"), FileSortKey.modifiedAt),
             (L10n.text("Type"), FileSortKey.kind),
             (L10n.text("Size"), FileSortKey.size)].forEach { title, key in
                let item = NSMenuItem(title: title, action: #selector(selectSortKeyFromContextMenu(_:)), keyEquivalent: "")
                item.target = self
                item.tag = key.rawValue
                item.state = sort.key == key ? .on : .off
                item.isEnabled = true
                sortMenu.addItem(item)
            }
            sortMenu.addItem(.separator())
            let ascending = NSMenuItem(title: L10n.text("Ascending"), action: #selector(selectSortDirectionFromContextMenu(_:)), keyEquivalent: "")
            ascending.target = self
            ascending.tag = 1
            ascending.state = sort.ascending ? .on : .off
            ascending.isEnabled = true
            sortMenu.addItem(ascending)
            let descending = NSMenuItem(title: L10n.text("Descending"), action: #selector(selectSortDirectionFromContextMenu(_:)), keyEquivalent: "")
            descending.target = self
            descending.tag = 0
            descending.state = sort.ascending ? .off : .on
            descending.isEnabled = true
            sortMenu.addItem(descending)
            let sortItem = NSMenuItem(title: L10n.text("Sort By"), action: nil, keyEquivalent: "")
            sortItem.submenu = sortMenu
            menu.addItem(sortItem)

            addItem(to: menu, title: L10n.text("Show View Options"), symbol: "slider.horizontal.3", action: #selector(MainViewController.showViewOptions(_:)), enabled: true)
            if let browser = parent as? MainViewController {
                let hidden = NSMenuItem(title: L10n.text("Show hidden files"), action: #selector(MainViewController.toggleHiddenFiles(_:)), keyEquivalent: "")
                hidden.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: nil)
                hidden.state = browser.isShowingHiddenFiles ? .on : .off
                hidden.isEnabled = true
                menu.addItem(hidden)
            }
            menu.addItem(.separator())
            addItem(to: menu, title: L10n.text("Refresh"), symbol: "arrow.clockwise", action: #selector(MainViewController.refresh(_:)), enabled: true)
            addItem(to: menu, title: L10n.text("Open in Terminal"), symbol: "terminal", action: #selector(MainViewController.openInTerminal(_:)), enabled: true)
            if let currentFolder = (parent as? MainViewController)?.currentLocation.folderURL {
                let pinned = ExplorerPreferences.isFolderPinned(currentFolder)
                addItem(
                    to: menu,
                    title: L10n.text(pinned ? "Unpin from Quick access" : "Pin to Quick access"),
                    symbol: pinned ? "pin.slash" : "pin",
                    action: #selector(MainViewController.toggleQuickAccessPin(_:)),
                    enabled: true
                )
            }
            addItem(to: menu, title: L10n.text("Quick Select") + "…", symbol: "checkmark.circle", action: #selector(MainViewController.quickSelect(_:)), enabled: true)
            addItem(to: menu, title: L10n.text("File Shelf"), symbol: "tray.full", action: #selector(MainViewController.showFileShelf(_:)), enabled: true)
            menu.addItem(.separator())
            addItem(to: menu, title: L10n.text("Get Info"), symbol: "info.circle", action: #selector(MainViewController.showCurrentFolderDetails(_:)), enabled: true)
            return
        }

        addItem(to: menu, title: L10n.text("Open"), symbol: "arrow.up.forward.app", action: #selector(MainViewController.openSelection(_:)), enabled: !items.isEmpty)
        if items.count == 1, items[0].isDirectory, !items[0].isPackage {
            addItem(to: menu, title: L10n.text("Open in New Tab"), symbol: "plus.rectangle.on.rectangle", action: #selector(MainViewController.openSelectionInNewTab(_:)), enabled: true)
            addItem(to: menu, title: L10n.text("Open in New Window"), symbol: "macwindow.badge.plus", action: #selector(MainViewController.openSelectionInNewWindow(_:)), enabled: true)
            let pinned = ExplorerPreferences.isFolderPinned(items[0].url)
            addItem(
                to: menu,
                title: L10n.text(pinned ? "Unpin from Quick access" : "Pin to Quick access"),
                symbol: pinned ? "pin.slash" : "pin",
                action: #selector(MainViewController.toggleQuickAccessPin(_:)),
                enabled: true
            )
        } else if items.count == 1, items[0].isPackage {
            addItem(to: menu, title: L10n.text("Show Package Contents"), symbol: "folder", action: #selector(MainViewController.showPackageContents(_:)), enabled: true)
        }
        addItem(to: menu, title: L10n.text("Open in Terminal"), symbol: "terminal", action: #selector(MainViewController.openInTerminal(_:)), enabled: true)
        if let item = items.first, items.count == 1, !item.isDirectory {
            let openWith = NSMenu(title: L10n.text("Open With"))
            openWith.autoenablesItems = false
            for applicationURL in NSWorkspace.shared.urlsForApplications(toOpen: item.url).prefix(12) {
                let application = NSMenuItem(
                    title: applicationURL.deletingPathExtension().lastPathComponent,
                    action: #selector(MainViewController.openSelectionWithApplication(_:)),
                    keyEquivalent: ""
                )
                application.image = NSWorkspace.shared.icon(forFile: applicationURL.path)
                application.image?.size = NSSize(width: 16, height: 16)
                application.representedObject = applicationURL
                openWith.addItem(application)
            }
            let openWithItem = NSMenuItem(title: L10n.text("Open With"), action: nil, keyEquivalent: "")
            openWithItem.submenu = openWith
            menu.addItem(openWithItem)
        }
        addItem(to: menu, title: L10n.text("Quick Look"), symbol: "eye", action: #selector(MainViewController.quickLook(_:)), enabled: !items.isEmpty)
        if items.count == 1, !items[0].isDirectory {
            addItem(to: menu, title: L10n.text("View Contents"), symbol: "doc.text.magnifyingglass", action: #selector(MainViewController.viewContents(_:)), enabled: true)
        }
        if items.count == 1, items[0].isExtractableArchive {
            addItem(to: menu, title: L10n.text("Extract"), symbol: "archivebox", action: #selector(MainViewController.extractSelection(_:)), enabled: true)
        }

        menu.addItem(.separator())
        addItem(to: menu, title: L10n.text("Cut"), symbol: "scissors", action: #selector(MainViewController.cut(_:)), enabled: !items.isEmpty)
        addItem(to: menu, title: L10n.text("Copy"), symbol: "doc.on.doc", action: #selector(MainViewController.copy(_:)), enabled: !items.isEmpty)
        addItem(to: menu, title: L10n.text("Paste"), symbol: "clipboard", action: #selector(MainViewController.paste(_:)), enabled: true)
        addItem(to: menu, title: L10n.text("Duplicate"), symbol: "plus.square.on.square", action: #selector(MainViewController.duplicate(_:)), enabled: !items.isEmpty)
        addItem(to: menu, title: items.count > 1 ? L10n.text("Rename Items") : L10n.text("Rename"), symbol: "character.cursor.ibeam", action: #selector(MainViewController.rename(_:)), enabled: !items.isEmpty)
        addItem(
            to: menu,
            title: L10n.text("Compress") + "…",
            symbol: "archivebox",
            action: #selector(MainViewController.compressSelection(_:)),
            enabled: !items.isEmpty
        )
        addItem(to: menu, title: L10n.text("New Folder with Selection"), symbol: "folder.badge.plus", action: #selector(MainViewController.newFolderWithSelection(_:)), enabled: !items.isEmpty)
        addItem(to: menu, title: L10n.text("Add to File Shelf"), symbol: "tray.and.arrow.down", action: #selector(MainViewController.addSelectionToShelf(_:)), enabled: !items.isEmpty)
        if items.count == 1 {
            addItem(to: menu, title: L10n.text("Create Link") + "…", symbol: "link", action: #selector(MainViewController.createLink(_:)), enabled: true)
        }

        if items.count == 1, items[0].isDirectory, !items[0].isPackage {
            addItem(to: menu, title: L10n.text("Open in Other Pane"), symbol: "rectangle.split.2x1", action: #selector(MainViewController.openInOtherPane(_:)), enabled: true)
        }

        if let browser = parent as? MainViewController, browser.canTransferToOtherPane {
            menu.addItem(.separator())
            addItem(to: menu, title: L10n.text("Copy to Other Pane"), symbol: "arrow.right.doc.on.clipboard", action: #selector(MainViewController.copyToOtherPane(_:)), enabled: true)
            addItem(to: menu, title: L10n.text("Move to Other Pane"), symbol: "arrow.right", action: #selector(MainViewController.moveToOtherPane(_:)), enabled: true)
        }

        if items.contains(where: { !$0.isDirectory }) {
            addItem(to: menu, title: L10n.text("Select Same Extension"), symbol: "checkmark.circle", action: #selector(MainViewController.selectSameExtension(_:)), enabled: true)
        }

        menu.addItem(.separator())
        addItem(to: menu, title: L10n.text("Copy Path"), symbol: "document.on.clipboard", action: #selector(MainViewController.copyPath(_:)), enabled: true)
        addItem(to: menu, title: L10n.text("Copy Name"), symbol: "textformat", action: #selector(MainViewController.copyName(_:)), enabled: true)
        if items.allSatisfy({ !$0.isDirectory }) {
            addItem(to: menu, title: L10n.text("Calculate SHA-256"), symbol: "number", action: #selector(MainViewController.calculateSHA256(_:)), enabled: true)
        }
        menu.addItem(.separator())
        if !urls.isEmpty {
            let shareItem = NSSharingServicePicker(items: urls).standardShareMenuItem
            shareItem.title = L10n.text("Share")
            menu.addItem(shareItem)
        }

        let quickActions = NSMenu(title: L10n.text("Quick Actions"))
        quickActions.autoenablesItems = false
        let imageItems = items.filter { $0.contentType?.conforms(to: .image) == true }
        if imageItems.count == items.count {
            addItem(to: quickActions, title: L10n.text("Rotate Left"), symbol: "rotate.left", action: #selector(MainViewController.rotateImagesLeft(_:)), enabled: true)
            addItem(to: quickActions, title: L10n.text("Rotate Right"), symbol: "rotate.right", action: #selector(MainViewController.rotateImagesRight(_:)), enabled: true)
            if items.count == 1 {
                addItem(to: quickActions, title: L10n.text("Markup"), symbol: "pencil.tip.crop.circle", action: #selector(MainViewController.markupImage(_:)), enabled: true)
            }
            addItem(to: quickActions, title: L10n.text("Create PDF"), symbol: "doc", action: #selector(MainViewController.createPDFFromImages(_:)), enabled: true)
            addItem(to: quickActions, title: L10n.text("Convert Image"), symbol: "photo.on.rectangle.angled", action: #selector(MainViewController.convertImages(_:)), enabled: true)
            addItem(to: quickActions, title: L10n.text("Remove Background"), symbol: "square.dashed", action: #selector(MainViewController.removeImageBackgrounds(_:)), enabled: true)
            if items.count == 1 {
                addItem(to: quickActions, title: L10n.text("Set as Desktop Picture"), symbol: "desktopcomputer", action: #selector(MainViewController.setAsDesktopPicture(_:)), enabled: true)
            }
        }
        if !quickActions.items.isEmpty { quickActions.addItem(.separator()) }
        addItem(to: quickActions, title: L10n.text("Customize"), symbol: "slider.horizontal.3", action: #selector(MainViewController.customizeQuickActions(_:)), enabled: true)
        let quickActionsItem = NSMenuItem(title: L10n.text("Quick Actions"), action: nil, keyEquivalent: "")
        quickActionsItem.submenu = quickActions
        menu.addItem(quickActionsItem)

        if !items.isEmpty {
            let tagsMenu = NSMenu(title: L10n.text("Tags"))
            tagsMenu.autoenablesItems = false
            for tag in FinderTagPalette.favoriteTags {
                let tagIndex = tag.colorIndex
                let tagName = tag.name
                let tagItem = NSMenuItem(
                    title: tagName,
                    action: #selector(MainViewController.applyTag(_:)),
                    keyEquivalent: ""
                )
                tagItem.representedObject = tagName
                tagItem.tag = tagIndex
                tagItem.image = FinderTagPalette.menuImage(forColorAt: tagIndex)
                tagItem.state = items.allSatisfy { item in
                    item.tagNames.contains {
                        FinderTagPalette.displayName(for: $0)
                            .localizedCaseInsensitiveCompare(tagName) == .orderedSame
                    }
                        || item.labelNumber == tagIndex
                } ? .on : .off
                tagItem.isEnabled = true
                tagsMenu.addItem(tagItem)
            }
            tagsMenu.addItem(.separator())
            let clearTags = NSMenuItem(
                title: L10n.text("Remove Tags"),
                action: #selector(MainViewController.applyTag(_:)),
                keyEquivalent: ""
            )
            clearTags.isEnabled = true
            tagsMenu.addItem(clearTags)
            let tagsItem = NSMenuItem(title: L10n.text("Tags"), action: nil, keyEquivalent: "")
            tagsItem.submenu = tagsMenu
            menu.addItem(tagsItem)
        }

        menu.addItem(.separator())
        addItem(to: menu, title: L10n.text("Move to Trash"), symbol: "trash", action: #selector(MainViewController.moveToTrash(_:)), enabled: !items.isEmpty)
        addItem(to: menu, title: L10n.text("Reveal in Finder"), symbol: "finder", action: #selector(MainViewController.showInFinder(_:)), enabled: !items.isEmpty)

        let servicesMenu = NSMenu(title: L10n.text("Services"))
        NSApp.servicesMenu = servicesMenu
        NSApp.registerServicesMenuSendTypes([.fileURL, .URL, .string], returnTypes: [])
        NSUpdateDynamicServices()
        let servicesItem = NSMenuItem(title: L10n.text("Services"), action: nil, keyEquivalent: "")
        servicesItem.submenu = servicesMenu
        menu.addItem(servicesItem)

        menu.addItem(.separator())
        addItem(to: menu, title: L10n.text("Get Info"), symbol: "info.circle", action: #selector(MainViewController.showSelectionDetails(_:)), enabled: !items.isEmpty)
    }

    func menuWillOpen(_ menu: NSMenu) {
        synchronizeSelectionAnchorWithSelection()
        normalizeContextMenuFooter(menu)
        DispatchQueue.main.async { [weak self, weak menu] in
            guard let self, let menu else { return }
            self.normalizeContextMenuFooter(menu)
        }
    }

    private func normalizeContextMenuFooter(_ menu: NSMenu) {
        let servicesTitle = L10n.text("Services")
        let serviceItems = menu.items.filter { $0.title == servicesTitle }
        for duplicate in serviceItems.dropFirst() {
            menu.removeItem(duplicate)
        }

        guard let infoItem = menu.items.first(where: {
            $0.action == #selector(MainViewController.showSelectionDetails(_:))
                || $0.action == #selector(MainViewController.showCurrentFolderDetails(_:))
        }) else { return }
        menu.removeItem(infoItem)
        while menu.items.last?.isSeparatorItem == true {
            menu.removeItem(at: menu.items.count - 1)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(infoItem)
    }

    private func addItem(to menu: NSMenu, title: String, symbol: String, action: Selector, enabled: Bool) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        item.isEnabled = enabled
        menu.addItem(item)
    }

    @objc private func setDateGroupingModeFromContextMenu(_ sender: NSMenuItem) {
        guard let mode = FileDateGroupingMode(rawValue: sender.tag) else { return }
        setDateGroupingMode(mode)
    }

    @objc private func selectSortKeyFromContextMenu(_ sender: NSMenuItem) {
        guard let key = FileSortKey(rawValue: sender.tag) else { return }
        setSort(key: key)
    }

    @objc private func selectSortDirectionFromContextMenu(_ sender: NSMenuItem) {
        setSort(ascending: sender.tag == 1)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { tableRows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard tableRows.indices.contains(row) else { return nil }

        if case let .group(_, title, collapsed) = tableRows[row] {
            let groupIdentifier = NSUserInterfaceItemIdentifier("group-row")
            let cell = (tableView.makeView(withIdentifier: groupIdentifier, owner: self) as? FileGroupTableCellView)
                ?? makeGroupCell(identifier: groupIdentifier)
            if case let .group(bucket, _, _) = tableRows[row] {
                cell.disclosureControl.configure(title: title, collapsed: collapsed) { [weak self] in
                    self?.activateDateGroup(bucket)
                }
            }
            return cell
        }

        guard let tableColumn else { return nil }
        let identifier = tableColumn.identifier
        guard case let .item(item) = tableRows[row] else { return nil }

        if identifier.rawValue == "name" {
            let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? FileNameTableCell) ?? makeNameCell(identifier: identifier)
            cell.cancelThumbnailRequest()
            cell.alphaValue = isCut(item) ? 0.48 : 1
            cell.representedURL = item.url
            // Recursive search results can contain identical or truncated names.
            // Match Explorer/Finder by exposing the unambiguous full location on hover.
            cell.toolTip = item.url.path
            cell.textField?.stringValue = displayName(for: item)
            cell.imageView?.image = FileIconProvider.shared.icon(for: item)
            cell.imageView?.imageScaling = .scaleProportionallyDown
            cell.tagDotsView.setColors(FinderTagPalette.colors(for: item))

            cell.loadThumbnail(for: item)
            return cell
        }

        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? makeTextCell(identifier: identifier)
        cell.alphaValue = isCut(item) ? 0.48 : 1
        switch identifier.rawValue {
        case "modified": cell.textField?.stringValue = item.modifiedAt.map(dateFormatter.string(from:)) ?? "—"
        case "kind": cell.textField?.stringValue = item.kind
        case "size":
            cell.textField?.stringValue = folderSizeText(for: item)
            cell.textField?.alignment = .right
        default: cell.textField?.stringValue = ""
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard tableRows.indices.contains(row) else { return false }
        if case .group = tableRows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard tableRows.indices.contains(row) else { return false }
        if case .item = tableRows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = FileTableRowView()
        rowView.selectionTrailingEdgeProvider = { [weak tableView] in
            (tableView as? FileTableView)?.selectionContentTrailingEdge ?? 0
        }
        return rowView
    }

    private func makeGroupCell(identifier: NSUserInterfaceItemIdentifier) -> FileGroupTableCellView {
        let cell = FileGroupTableCellView()
        cell.identifier = identifier
        return cell
    }

    private func makeNameCell(identifier: NSUserInterfaceItemIdentifier) -> FileNameTableCell {
        let cell = FileNameTableCell()
        cell.identifier = identifier
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        cell.tagDotsView.translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView(views: [icon, cell.tagDotsView, label])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 7
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cell.imageView = icon
        cell.textField = label
        cell.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 7),
            row.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5),
            row.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 19),
            icon.heightAnchor.constraint(equalToConstant: 19)
        ])
        return cell
    }

    private func makeTextCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        cell.textField = label
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionNotifications, !tableView.isPerformingMarqueeSelection else { return }
        synchronizeSelectionAnchorWithSelection()
        delegate?.fileListSelectionDidChange(self)
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        let widths = Dictionary(uniqueKeysWithValues: tableView.tableColumns
            .filter { $0.identifier != FileTableView.spacerColumnIdentifier }
            .map {
            ($0.identifier.rawValue, Double($0.width))
        })
        UserDefaults.standard.set(widths, forKey: Self.columnWidthsKey)
        tableView.needsDisplay = true
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !suppressSortDescriptorChanges else { return }
        guard let descriptor = tableView.sortDescriptors.first else { return }
        switch descriptor.key {
        case "modified": sort.key = .modifiedAt
        case "kind": sort.key = .kind
        case "size": sort.key = .size
        default: sort.key = .name
        }
        sort.ascending = descriptor.ascending
        recordSessionDefaultViewIfUnprofiled()
        applyFilter(preservingSelection: Set(selectedItems.map(\.url)))
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { displayGroups.count }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        guard displayGroups.indices.contains(section) else { return 0 }
        if let bucket = displayGroups[section].bucket,
           collapsedDateGroups.contains(bucket) {
            return 0
        }
        return displayGroups[section].items.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: FileCollectionItem.identifier, for: indexPath)
        if let fileItem = item as? FileCollectionItem, let representedItem = collectionItem(at: indexPath) {
            fileItem.configure(
                item: representedItem,
                iconSize: iconSize,
                displayName: displayName(for: representedItem),
                desktopAppearance: usesDesktopAppearance,
                isCut: isCut(representedItem)
            )
        }
        return item
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
        at indexPath: IndexPath
    ) -> NSView {
        let view = collectionView.makeSupplementaryView(
            ofKind: kind,
            withIdentifier: FileGroupHeaderView.identifier,
            for: indexPath
        )
        if let header = view as? FileGroupHeaderView, displayGroups.indices.contains(indexPath.section) {
            let group = displayGroups[indexPath.section]
            if let bucket = group.bucket {
                header.configure(
                    title: group.title,
                    collapsed: collapsedDateGroups.contains(bucket)
                ) { [weak self] in
                    self?.activateDateGroup(bucket)
                }
            }
        }
        return view
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        willDisplay item: NSCollectionViewItem,
        forRepresentedObjectAt indexPath: IndexPath
    ) {
        (item as? FileCollectionItem)?.loadThumbnailIfNeeded()
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        didEndDisplaying item: NSCollectionViewItem,
        forRepresentedObjectAt indexPath: IndexPath
    ) {
        (item as? FileCollectionItem)?.cancelThumbnailRequest()
    }

    func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
        cancelThumbnailRequests(in: rowView)
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard !suppressSelectionNotifications else { return }
        synchronizeSelectionAnchorWithSelection()
        delegate?.fileListSelectionDidChange(self)
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        guard !suppressSelectionNotifications else { return }
        synchronizeSelectionAnchorWithSelection()
        delegate?.fileListSelectionDidChange(self)
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        canDragItemsAt indexPaths: Set<IndexPath>,
        with event: NSEvent
    ) -> Bool {
        !indexPaths.isEmpty
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard let item = collectionItem(at: indexPath) else { return nil }
        return item.url as NSURL
    }

    private func fileDropURLs(from draggingInfo: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return draggingInfo.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) as? [URL] ?? []
    }

    private func fileDropSources(
        for urls: [URL],
        sequenceNumber: Int
    ) -> [FileDropSource]? {
        if let cachedFileDropSources,
           cachedFileDropSources.sequenceNumber == sequenceNumber,
           cachedFileDropSources.urls == urls {
            return cachedFileDropSources.sources
        }

        var sources: [FileDropSource] = []
        sources.reserveCapacity(urls.count)

        for url in urls {
            let path = url.standardizedFileURL.path
            if let index = allItemIndexByPath[path], allItems.indices.contains(index) {
                sources.append(FileDropSource(url: url, isDirectory: allItems[index].isDirectory))
                continue
            }

            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                  let isDirectory = values.isDirectory else { return nil }
            sources.append(FileDropSource(url: url, isDirectory: isDirectory))
        }
        cachedFileDropSources = (sequenceNumber, urls, sources)
        return sources
    }

    private func fileDropTarget(on item: FileItem?) -> FileDropTarget {
        guard let item, item.isDirectory else { return .background(directoryURL) }
        return .folder(item.url, isPackage: item.isPackage)
    }

    private func fileDropDecision(
        for draggingInfo: NSDraggingInfo,
        target: FileDropTarget
    ) -> (urls: [URL], decision: FileDropDecision)? {
        let urls = fileDropURLs(from: draggingInfo)
        guard let sources = fileDropSources(
            for: urls,
            sequenceNumber: draggingInfo.draggingSequenceNumber
        ) else { return nil }
        let origin: FileDropOrigin = draggingInfo.draggingSource == nil
            ? .externalDrag
            : .internalDrag
        let decision = FileDropPolicy.decision(
            sources: sources,
            target: target,
            origin: origin,
            sourceOperationMask: draggingInfo.draggingSourceOperationMask,
            copyRequested: NSEvent.modifierFlags.contains(.option)
        )
        return (urls, decision)
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        validateDrop draggingInfo: NSDraggingInfo,
        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
    ) -> NSDragOperation {
        let indexPath = proposedDropIndexPath.pointee as IndexPath
        let target: FileDropTarget
        if proposedDropOperation.pointee == .on,
           let item = collectionItem(at: indexPath) {
            target = fileDropTarget(on: item)
            if item.isDirectory && item.isPackage {
                return []
            }
            if !item.isDirectory {
                proposedDropOperation.pointee = .before
            }
        } else {
            proposedDropOperation.pointee = .before
            target = .background(directoryURL)
        }
        return fileDropDecision(for: draggingInfo, target: target)?.decision.operation ?? []
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        acceptDrop draggingInfo: NSDraggingInfo,
        indexPath: IndexPath,
        dropOperation: NSCollectionView.DropOperation
    ) -> Bool {
        let target: FileDropTarget
        if dropOperation == .on,
           let item = collectionItem(at: indexPath) {
            target = fileDropTarget(on: item)
        } else {
            target = .background(directoryURL)
        }
        guard let result = fileDropDecision(for: draggingInfo, target: target),
              result.decision.isAccepted,
              let destination = result.decision.destination else { return false }
        delegate?.fileList(
            self,
            didRequestImport: result.urls,
            destination: destination,
            move: result.decision.shouldMove
        )
        return true
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard tableRows.indices.contains(row), case let .item(item) = tableRows[row] else { return nil }
        return item.url as NSURL
    }

    func tableView(
        _ tableView: NSTableView,
        draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint,
        forRowIndexes rowIndexes: IndexSet
    ) {
        let rows = Array(rowIndexes)
        let nameColumn = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
        guard nameColumn >= 0, !rows.isEmpty else { return }

        session.draggingFormation = rows.count > 1 ? .stack : .none
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        session.enumerateDraggingItems(
            options: [],
            for: tableView,
            classes: [NSURL.self],
            searchOptions: options
        ) { draggingItem, index, _ in
            guard rows.indices.contains(index),
                  let cell = tableView.view(
                      atColumn: nameColumn,
                      row: rows[index],
                      makeIfNecessary: true
                  ) as? NSTableCellView else { return }
            let frame = tableView.convert(cell.bounds, from: cell)
            let components = cell.draggingImageComponents
            draggingItem.draggingFrame = frame
            draggingItem.imageComponentsProvider = { components }
        }
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        let target: FileDropTarget
        if dropOperation == .on,
           tableRows.indices.contains(row),
           case let .item(item) = tableRows[row],
           item.isDirectory {
            target = fileDropTarget(on: item)
            if item.isPackage { return [] }
        } else {
            target = .background(directoryURL)
            tableView.setDropRow(-1, dropOperation: .on)
        }
        return fileDropDecision(for: info, target: target)?.decision.operation ?? []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let target: FileDropTarget
        if dropOperation == .on,
           tableRows.indices.contains(row),
           case let .item(item) = tableRows[row],
           item.isDirectory {
            target = fileDropTarget(on: item)
        } else {
            target = .background(directoryURL)
        }
        guard let result = fileDropDecision(for: info, target: target),
              result.decision.isAccepted,
              let destination = result.decision.destination else { return false }
        delegate?.fileList(
            self,
            didRequestImport: result.urls,
            destination: destination,
            move: result.decision.shouldMove
        )
        return true
    }

    func fileTableDidPressOpen(_ tableView: NSView) {
        for item in selectedItems { delegate?.fileList(self, didActivate: item) }
    }
    func fileTableDidPressRename(_ tableView: NSView) {
        if selectedItems.count == 1 { beginInlineRename() }
        else if !selectedItems.isEmpty { delegate?.fileListDidRequestRename(self) }
    }
    func fileTableDidPressSpace(_ tableView: NSView) { delegate?.fileListDidRequestQuickLook(self) }
    func fileTableDidPressDelete(_ tableView: NSView) { delegate?.fileListDidRequestTrash(self) }

    private func displayName(for item: FileItem) -> String {
        showsFileExtensions ? item.url.lastPathComponent : item.name
    }
}
