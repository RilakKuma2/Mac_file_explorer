import AppKit

enum NavigationClickDispatcher {
    /// Local event monitors run before normal mouse dispatch. Starting AppKit
    /// button/menu tracking there can re-enter the same event stream. Dispatch
    /// the action only after the monitor has returned, without performClick's
    /// synthetic tracking/highlight delay.
    static func enqueue(_ button: NSButton) {
        guard button.isEnabled, let window = button.window else { return }
        DispatchQueue.main.async { [weak button, weak window] in
            guard let button, let window, button.window === window,
                  button.isEnabled, !button.isHiddenOrHasHiddenAncestor,
                  let action = button.action else { return }
            button.sendAction(action, to: button.target)
        }
    }
}
