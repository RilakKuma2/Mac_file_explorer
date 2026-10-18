import AppKit

/// Keeps the native resizable window behavior while making the inside edge a
/// little easier to grab on full-size-content windows.
final class ExplorerWindow: NSWindow {
    private struct ResizeEdges: OptionSet {
        let rawValue: Int

        static let left = ResizeEdges(rawValue: 1 << 0)
        static let right = ResizeEdges(rawValue: 1 << 1)
        static let bottom = ResizeEdges(rawValue: 1 << 2)
        static let top = ResizeEdges(rawValue: 1 << 3)
    }

    private let resizeGrabInset: CGFloat = 8
    private let resizeGrabOutset: CGFloat = 5
    private var sizeObserver: NSObjectProtocol?

    /// Use our own size preference: AppKit frame autosave names cannot be
    /// shared reliably by several simultaneously open windows.
    func restoreAndRememberSize(defaults: UserDefaults = .standard) {
        let key = "ExplorerWindowLastSize"
        if let saved = defaults.array(forKey: key) as? [Double], saved.count == 2,
           saved.allSatisfy({ $0.isFinite && $0 > 0 }) {
            let available = screen?.visibleFrame.size ?? NSScreen.main?.visibleFrame.size ?? frame.size
            var restored = frame
            restored.size = NSSize(
                width: max(minSize.width, min(CGFloat(saved[0]), available.width)),
                height: max(minSize.height, min(CGFloat(saved[1]), available.height))
            )
            setFrame(restored, display: false)
        }
        if let sizeObserver { NotificationCenter.default.removeObserver(sizeObserver) }
        sizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: self, queue: .main
        ) { [weak self] _ in
            guard let self, !self.styleMask.contains(.fullScreen), !self.isZoomed else { return }
            defaults.set([Double(self.frame.width), Double(self.frame.height)], forKey: key)
        }
    }

    deinit {
        if let sizeObserver { NotificationCenter.default.removeObserver(sizeObserver) }
    }

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        acceptsMouseMovedEvents = true
    }

    override func sendEvent(_ event: NSEvent) {
        if attachedSheet == nil,
           (contentViewController as? ExplorerWindowViewController)?.handlePaneMouseDown(event) == true {
            return
        }
        if event.type == .leftMouseDown,
           event.clickCount == 1,
           styleMask.contains(.resizable),
           !styleMask.contains(.fullScreen),
           !isZoomed {
            let edges = resizeEdges(at: event.locationInWindow)
            if !edges.isEmpty, !isInteractiveControl(at: event.locationInWindow) {
                trackResize(from: event, edges: edges)
                return
            }
        }

        super.sendEvent(event)

        if event.type == .mouseMoved || event.type == .mouseEntered || event.type == .cursorUpdate {
            let edges = resizeEdges(at: event.locationInWindow)
            if !edges.isEmpty {
                resizeCursor(for: edges).set()
            }
        }
    }

    private func resizeEdges(at point: NSPoint) -> ResizeEdges {
        let size = frame.size
        guard point.x >= -resizeGrabOutset,
              point.y >= -resizeGrabOutset,
              point.x <= size.width + resizeGrabOutset,
              point.y <= size.height + resizeGrabOutset else {
            return []
        }

        var edges: ResizeEdges = []
        if point.x <= resizeGrabInset { edges.insert(.left) }
        if point.x >= size.width - resizeGrabInset { edges.insert(.right) }
        if point.y <= resizeGrabInset { edges.insert(.bottom) }
        if point.y >= size.height - resizeGrabInset { edges.insert(.top) }
        return edges
    }

    func isInteractiveControl(at windowPoint: NSPoint) -> Bool {
        guard let contentView else { return false }
        // hitTest takes a point in the receiver's superview, not its own bounds.
        let point = contentView.superview?.convert(windowPoint, from: nil) ?? windowPoint
        var candidate: NSView? = contentView.hitTest(point)
        while let view = candidate {
            if view is NSControl || view is NSTextView || view is NSCollectionView {
                return true
            }
            candidate = view.superview
        }
        return false
    }

    private func resizeCursor(for edges: ResizeEdges) -> NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            switch (edges.contains(.top), edges.contains(.bottom), edges.contains(.left), edges.contains(.right)) {
            case (true, _, true, _): position = .topLeft
            case (true, _, _, true): position = .topRight
            case (_, true, true, _): position = .bottomLeft
            case (_, true, _, true): position = .bottomRight
            case (true, _, _, _): position = .top
            case (_, true, _, _): position = .bottom
            case (_, _, true, _): position = .left
            default: position = .right
            }
            return .frameResize(position: position, directions: .all)
        }
        if edges.contains(.left) || edges.contains(.right) {
            return .resizeLeftRight
        }
        return .resizeUpDown
    }

    private func trackResize(from event: NSEvent, edges: ResizeEdges) {
        let initialFrame = frame
        let initialPointer = NSEvent.mouseLocation
        let minimum = minSize
        resizeCursor(for: edges).set()

        while let next = MouseTracking.nextEvent(in: self) {
            if next.type == .leftMouseUp { break }

            let pointer = NSEvent.mouseLocation
            let dx = pointer.x - initialPointer.x
            let dy = pointer.y - initialPointer.y
            var candidate = initialFrame

            if edges.contains(.left) {
                candidate.origin.x = initialFrame.origin.x + dx
                candidate.size.width = initialFrame.width - dx
            } else if edges.contains(.right) {
                candidate.size.width = initialFrame.width + dx
            }

            if edges.contains(.bottom) {
                candidate.origin.y = initialFrame.origin.y + dy
                candidate.size.height = initialFrame.height - dy
            } else if edges.contains(.top) {
                candidate.size.height = initialFrame.height + dy
            }

            if candidate.width < minimum.width {
                candidate.size.width = minimum.width
                if edges.contains(.left) { candidate.origin.x = initialFrame.maxX - minimum.width }
            }
            if candidate.height < minimum.height {
                candidate.size.height = minimum.height
                if edges.contains(.bottom) { candidate.origin.y = initialFrame.maxY - minimum.height }
            }

            setFrame(candidate, display: true)
        }
    }
}
