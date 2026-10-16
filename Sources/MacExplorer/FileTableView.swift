import AppKit

protocol FileTableViewKeyDelegate: AnyObject {
    func fileTableDidPressOpen(_ tableView: NSView)
    func fileTableDidPressRename(_ tableView: NSView)
    func fileTableDidPressSpace(_ tableView: NSView)
    func fileTableDidPressDelete(_ tableView: NSView)
}

final class FileTableRowView: NSTableRowView {
    var selectionTrailingEdgeProvider: (() -> CGFloat)?
    var isRenaming = false { didSet { needsDisplay = true } }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        isRenaming ? .normal : super.interiorBackgroundStyle
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let trailingEdge = min(bounds.maxX, selectionTrailingEdgeProvider?() ?? bounds.maxX)
        guard trailingEdge > bounds.minX else { return }
        let selectionRect = NSRect(
            x: bounds.minX + 2,
            y: bounds.minY + 1,
            width: max(0, trailingEdge - bounds.minX - 4),
            height: max(0, bounds.height - 2)
        )
        let color = isEmphasized && !isRenaming
            ? NSColor.selectedContentBackgroundColor
            : NSColor.unemphasizedSelectedContentBackgroundColor
        color.setFill()
        NSBezierPath(roundedRect: selectionRect, xRadius: 5, yRadius: 5).fill()
    }
}

final class FileTableView: NSTableView {
    static let spacerColumnIdentifier = NSUserInterfaceItemIdentifier("selection-spacer")

    weak var keyDelegate: FileTableViewKeyDelegate?
    var onCommandScroll: ((CGFloat, Bool) -> Void)?
    var onMagnify: ((CGFloat) -> Void)?
    var onKeyDown: ((NSEvent) -> Bool)?
    var onShiftClick: ((Int, Bool) -> Bool)?
    var onSelectionAnchorChanged: ((Int) -> Void)?
    var onNonItemClick: ((Int) -> Bool)?
    var isItemRow: ((Int) -> Bool)?
    var onMarqueeSelectionChanged: (() -> Void)?
    var onBlankClick: (() -> Void)?

    private(set) var isPerformingMarqueeSelection = false
    private var marqueeRect: NSRect? {
        didSet {
            if let oldValue { setNeedsDisplay(oldValue.insetBy(dx: -2, dy: -2)) }
            if let marqueeRect { setNeedsDisplay(marqueeRect.insetBy(dx: -2, dy: -2)) }
        }
    }

    var selectionContentTrailingEdge: CGFloat {
        let sizeColumn = column(withIdentifier: NSUserInterfaceItemIdentifier("size"))
        guard sizeColumn >= 0 else { return bounds.maxX }
        return rect(ofColumn: sizeColumn).maxX
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

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
        if [123, 124, 125, 126].contains(event.keyCode),
           !event.modifierFlags.contains(.shift), selectedRow >= 0 {
            onSelectionAnchorChanged?(selectedRow)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clicked = row(at: point)
        if clicked >= 0, onNonItemClick?(clicked) == true {
            return
        }
        let clickedColumn = column(at: point)
        let isSpacer = clickedColumn < 0
            || tableColumns[clickedColumn].identifier == Self.spacerColumnIdentifier
        if clicked < 0 || isSpacer {
            performLiveMarqueeSelection(startingAt: point, event: event)
            return
        }
        if clicked >= 0,
           event.modifierFlags.contains(.shift),
           onShiftClick?(clicked, event.modifierFlags.contains(.command)) == true {
            return
        }
        collapseMultipleSelectionForPlainClick(at: clicked, modifiers: event.modifierFlags)
        super.mouseDown(with: event)
        if clicked >= 0, !event.modifierFlags.contains(.shift) {
            onSelectionAnchorChanged?(clicked)
        } else if clicked < 0, !event.modifierFlags.contains(.shift) {
            onBlankClick?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let marqueeRect, marqueeRect.intersects(dirtyRect) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        marqueeRect.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.72).setStroke()
        let border = NSBezierPath(rect: marqueeRect.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    func collapseMultipleSelectionForPlainClick(at row: Int, modifiers: NSEvent.ModifierFlags) {
        let selectionModifiers: NSEvent.ModifierFlags = [.command, .shift, .control]
        guard row >= 0,
              selectedRowIndexes.count > 1,
              selectedRowIndexes.contains(row),
              modifiers.intersection(selectionModifiers).isEmpty else { return }
        // NSTableView normally keeps the whole selection until mouse-up so it
        // can start a multi-item drag. Collapse it on mouse-down so a plain
        // click gives immediate feedback and drags only that item.
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    private func performLiveMarqueeSelection(startingAt startPoint: NSPoint, event: NSEvent) {
        window?.makeFirstResponder(self)
        let extendsSelection = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.shift)
        let originalSelection = extendsSelection ? selectedRowIndexes : []
        let previousSelection = selectedRowIndexes

        isPerformingMarqueeSelection = true
        if !extendsSelection { selectRowIndexes([], byExtendingSelection: false) }
        var selectionChanged = selectedRowIndexes != previousSelection
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

            var hits = IndexSet()
            if rect.minX <= selectionContentTrailingEdge {
                let range = rows(in: rect)
                if range.location != NSNotFound {
                    for row in range.location..<NSMaxRange(range)
                    where isItemRow?(row) != false {
                        hits.insert(row)
                    }
                }
            }
            let updated = originalSelection.union(hits)
            if updated != selectedRowIndexes {
                selectRowIndexes(updated, byExtendingSelection: false)
                selectionChanged = true
            }
            window.displayIfNeeded()
        }

        marqueeRect = nil
        isPerformingMarqueeSelection = false
        if selectionChanged { onMarqueeSelectionChanged?() }
        if !dragged, !extendsSelection, event.clickCount == 1 { onBlankClick?() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clicked = row(at: point)
        let clickedColumn = column(at: point)
        let isFile = clicked >= 0 && clickedColumn >= 0
            && tableColumns[clickedColumn].identifier != Self.spacerColumnIdentifier
            && (isItemRow?(clicked) ?? true)
        if isFile, !selectedRowIndexes.contains(clicked) {
            selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
            onSelectionAnchorChanged?(clicked)
        } else if !isFile {
            deselectAll(nil)
            onBlankClick?()
        }
        // NSTableView's default contextual selection uses only the row and can
        // select it again when the click was in our trailing blank column.
        return menu
    }
}
