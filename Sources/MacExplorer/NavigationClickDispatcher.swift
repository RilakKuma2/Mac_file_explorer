import AppKit

enum NavigationClickDispatcher {
    /// Called only from NSWindow.sendEvent, never from an event monitor or a
    /// dispatched main-queue block. Let the button own the complete mouse-down /
    /// mouse-up gesture before its action changes the breadcrumb view hierarchy.
    /// A popup opened by that action must also leave the main queue available
    /// for directory completions while AppKit runs its nested tracking loop.
    static func mouseDown(on button: NSButton, with event: NSEvent) {
        guard event.type == .leftMouseDown, button.isEnabled,
              !button.isHiddenOrHasHiddenAncestor,
              let window = button.window, event.window === window else { return }
        // This route bypasses NSWindow's normal control hit testing. Preserve
        // its click-to-focus behavior, including clicks in an inactive window.
        if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
        button.mouseDown(with: event)
    }
}
