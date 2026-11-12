import AppKit

enum NavigationClickDispatcher {
    /// Clicks routed here never reach NSWindow.sendEvent, which is what
    /// normally activates the application and makes the window key. Without
    /// both, the address field shows an inactive (grey) selection and typing or
    /// Copy still goes to the previously active app, and the next click in the
    /// file list is spent on activation instead of selecting.
    static func activateForDirectClick(in window: NSWindow) {
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
    }

    /// Called only from NSWindow.sendEvent, never from an event monitor or a
    /// dispatched main-queue block. Let the button own the complete mouse-down /
    /// mouse-up gesture before its action changes the breadcrumb view hierarchy.
    /// A popup opened by that action must also leave the main queue available
    /// for directory completions while AppKit runs its nested tracking loop.
    static func mouseDown(on button: NSButton, with event: NSEvent) {
        guard event.type == .leftMouseDown, button.isEnabled,
              !button.isHiddenOrHasHiddenAncestor,
              let window = button.window, event.window === window else { return }
        activateForDirectClick(in: window)
        let started = InputDiagnostics.now
        button.mouseDown(with: event)
        InputDiagnostics.log("  button tracking \(button.identifier?.rawValue ?? String(describing: type(of: button))) ms=\(InputDiagnostics.milliseconds(since: started)) stillInWindow=\(button.window != nil)")
    }
}
