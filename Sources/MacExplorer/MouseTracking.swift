import AppKit

enum MouseTracking {
    /// A mouse-up can be lost when another application or a system panel takes
    /// over a gesture. Never leave our custom tracking loops waiting forever.
    static func nextEvent(in window: NSWindow) -> NSEvent? {
        while window.isVisible {
            if let event = window.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: Date(timeIntervalSinceNow: 0.1),
                inMode: .eventTracking,
                dequeue: true
            ) {
                return event
            }
            if NSEvent.pressedMouseButtons & 1 == 0 { return nil }
        }
        return nil
    }
}
