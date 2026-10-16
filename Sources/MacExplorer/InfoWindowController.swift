import AppKit

/// Each request creates a separate nonmodal window so multiple property sets can
/// remain visible at the same time.
final class InfoWindowController: NSWindowController, NSWindowDelegate {
    private static var openControllers: [InfoWindowController] = []
    private let detailsController = DetailsPaneViewController()

    static func present(items: [FileItem]) {
        guard !items.isEmpty else { return }
        let controller = InfoWindowController(items: items)
        openControllers.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init(items: [FileItem]) {
        let title: String
        if items.count == 1 {
            title = String(format: L10n.text("%@ Properties"), items[0].name)
        } else {
            title = String(format: L10n.text("%d Items Properties"), items.count)
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.minSize = NSSize(width: 380, height: 440)
        window.contentViewController = detailsController
        super.init(window: window)
        window.delegate = self
        window.center()
        _ = detailsController.view
        detailsController.display(items: items)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        Self.openControllers.removeAll { $0 === self }
    }
}
