// Native event integration check. Link against the debug target's objects (apart
// from main.swift.o). AppKit tracking needs an actual NSApplication.run loop;
// Swift Testing's async command-line runner does not provide that lifecycle.
import AppKit
@testable import MacExplorer

final class NavigationInteractionCheck: NSObject, NSApplicationDelegate {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BreadcrumbClicks-\(UUID())")
    var parent: URL { root.appendingPathComponent("Parent", isDirectory: true) }
    var child: URL { parent.appendingPathComponent("Child", isDirectory: true) }
    var window: ExplorerWindow!
    var controller: ExplorerWindowViewController!
    var browser: MainViewController!
    var list: FileListViewController!
    var timer: Timer?
    var phase = 0
    var passes = 0
    var started = Date()
    var menuCompletionDelivered = false
    var otherWindow: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            try Data().write(to: parent.appendingPathComponent("Example.txt"))
        } catch { finish("Fixture error: \(error)") }
        controller = ExplorerWindowViewController(initialURL: child)
        window = ExplorerWindow(contentRect: NSRect(x: 100, y: 100, width: 1200, height: 700),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        otherWindow = NSWindow(contentRect: NSRect(x: 10, y: 10, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        otherWindow.isReleasedWhenClosed = false
        browser = controller.currentBrowser!
        list = browser.children.compactMap { $0 as? FileListViewController }.first!
        list.setViewMode(.details)
        started = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in self?.step() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func step() {
        if Date().timeIntervalSince(started) > 20 { finish("Timed out at phase \(phase), pass \(passes)") }
        guard NSApp.isActive, list.isReadyForFolderCommands else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        switch phase {
        case 0:
            guard list.directoryURL.standardizedFileURL == child.standardizedFileURL else { return }
            guard let bar = descendants(browser.view).compactMap({ $0 as? BreadcrumbBarView }).first,
                  let button = descendants(bar).compactMap({ $0 as? NSButton }).first(where: {
                      $0.identifier?.rawValue == "breadcrumbCrumb" && $0.title == "Parent"
                  }) else { finish("Missing parent breadcrumb") }
            phase = 1
            otherWindow.makeKeyAndOrderFront(nil)
            click(button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil))
            guard window.isKeyWindow else { finish("Breadcrumb did not activate its window") }
        case 1:
            guard list.directoryURL.standardizedFileURL == parent.standardizedFileURL else { return }
            list.setViewMode(.details)
            window.contentView?.layoutSubtreeIfNeeded()
            guard let table = descendants(list.view).compactMap({ $0 as? FileTableView }).first,
                  table.numberOfRows == 2 else { finish("Parent list is not ready") }
            let point = table.convert(NSPoint(x: 90, y: table.rect(ofRow: 0).midY), to: nil)
            click(point)
            guard list.selectedItems.map(\.name) == ["Child"] else { finish("First click after navigation was lost") }
            phase = 2
            click(point, count: 2)
        default:
            guard list.directoryURL.standardizedFileURL == child.standardizedFileURL else { return }
            passes += 1
            if passes == 5 {
                timer?.invalidate()
                checkMenuCompletion()
                finish(menuCompletionDelivered ? nil : "Popup blocked main-queue directory completion")
            }
            phase = 0
        }
    }

    func click(_ point: NSPoint, count: Int = 1) {
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: count, pressure: type == .leftMouseDown ? 1 : 0)!
        }
        NSApp.postEvent(event(.leftMouseUp), atStart: true)
        window.sendEvent(event(.leftMouseDown))
    }

    func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }

    func checkMenuCompletion() {
        let button = NSButton(frame: NSRect(x: 20, y: 20, width: 100, height: 30))
        button.target = self
        button.action = #selector(openTestMenu(_:))
        window.contentView!.addSubview(button)
        let point = button.convert(NSPoint(x: 50, y: 15), to: nil)
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        NSApp.postEvent(up, atStart: true)
        NavigationClickDispatcher.mouseDown(on: button, with: down)
        button.removeFromSuperview()
    }

    @objc func openTestMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Example folder", action: nil, keyEquivalent: "")
        let timeout = Timer(timeInterval: 1, repeats: false) { _ in menu.cancelTracking() }
        RunLoop.main.add(timeout, forMode: .common)
        RunLoop.main.add(timeout, forMode: .eventTracking)
        DispatchQueue.main.async {
            self.menuCompletionDelivered = true
            menu.cancelTracking()
        }
        menu.popUp(positioning: nil, at: .zero, in: sender)
        timeout.invalidate()
    }

    func finish(_ error: String?) -> Never {
        timer?.invalidate()
        window?.orderOut(nil)
        otherWindow?.orderOut(nil)
        window?.contentViewController = nil
        try? FileManager.default.removeItem(at: root)
        print(error.map { "FAIL: " + $0 } ?? "PASS: 5 parent breadcrumb / immediate file selection / folder open cycles, inactive-window focus, and popup completion")
        exit(error == nil ? 0 : 1)
    }
}

let app = NSApplication.shared
let check = NavigationInteractionCheck()
app.delegate = check
app.setActivationPolicy(.accessory)
app.run()
