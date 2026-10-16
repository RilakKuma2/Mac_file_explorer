import AppKit
import Testing
@testable import MacExplorer

struct MouseTrackingTests {
    @Test @MainActor
    func closedWindowEndsTracking() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        #expect(MouseTracking.nextEvent(in: window) == nil)
    }

    @Test @MainActor
    func edgeTextFieldIsInteractive() {
        let window = ExplorerWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                    styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let field = NSTextField(frame: NSRect(x: 0, y: 30, width: 100, height: 24))
        window.contentView?.addSubview(field)
        let point = field.convert(NSPoint(x: 4, y: 12), to: nil)
        #expect(window.isInteractiveControl(at: point))
    }
}
