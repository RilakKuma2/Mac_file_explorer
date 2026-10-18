import AppKit
import Testing
@testable import MacExplorer

private final class NavigationActionRecorder: NSObject {
    var count = 0
    @objc func clicked(_ sender: Any?) {
        count += 1
    }
}

private final class NavigationMouseButton: NSButton {
    var mouseEvents: [NSEvent] = []
    override func mouseDown(with event: NSEvent) {
        mouseEvents.append(event)
    }
}

@Suite(.serialized)
struct NavigationClickDispatcherTests {
    @Test("Navigation delivers the original gesture to the native button without synthesizing an action")
    @MainActor
    func forwardsMouseGesture() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        let recorder = NavigationActionRecorder()
        let button = NavigationMouseButton(frame: NSRect(x: 20, y: 60, width: 100, height: 30))
        button.target = recorder
        button.action = #selector(NavigationActionRecorder.clicked(_:))
        window.contentView?.addSubview(button)
        let point = button.convert(NSPoint(x: 50, y: 15), to: nil)
        let down = try mouseEvent(.leftMouseDown, at: point, in: window)
        NavigationClickDispatcher.mouseDown(on: button, with: down)
        #expect(button.mouseEvents.count == 1)
        #expect(button.mouseEvents.first === down)
        #expect(recorder.count == 0)
        button.isEnabled = false
        NavigationClickDispatcher.mouseDown(on: button, with: down)
        #expect(button.mouseEvents.count == 1)
    }

    @Test("A navigation action cannot leave a queued action after its view is detached")
    @MainActor
    func removedButtonDoesNotRunLater() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let button = NSButton(frame: NSRect(x: 20, y: 60, width: 100, height: 30))
        let recorder = NavigationActionRecorder()
        button.target = recorder
        button.action = #selector(NavigationActionRecorder.clicked(_:))
        window.contentView?.addSubview(button)
        let event = try mouseEvent(.leftMouseDown, at: NSPoint(x: 50, y: 75), in: window)
        button.removeFromSuperview()
        NavigationClickDispatcher.mouseDown(on: button, with: event)
        #expect(recorder.count == 0)
    }

    @MainActor
    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
    }
}
