import AppKit
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private static let fullDiskAccessPromptSuppressedKey = "FullDiskAccessPromptSuppressed"

    private var windowControllers: [NSWindowController] = []
    private var windowCloseObservers: [ObjectIdentifier: NSObjectProtocol] = [:]
    private var settingsWindowController: SettingsWindowController?
    private var keyMonitor: Any?
    private var hasFinishedInitialLaunch = false
    private let appUpdater = AppUpdater()

    func applicationWillFinishLaunching(_ notification: Notification) {
        for eventID in DefaultFileViewer.revealEventIDs {
            NSAppleEventManager.shared().setEventHandler(self,
                andSelector: #selector(revealFiles(_:withReplyEvent:)),
                forEventClass: DefaultFileViewer.revealEventClass, andEventID: eventID)
        }
    }

    @objc private func revealFiles(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let direct = event.paramDescriptor(forKeyword: keyDirectObject) else {
            DefaultFileViewer.requestLogger.error("Reveal rejected: missing direct object")
            reply.setParam(NSAppleEventDescriptor(int32: -1701), forKeyword: keyErrorNumber)
            return
        }
        let urls = DefaultFileViewer.revealedURLs(from: direct)
        let shape = DefaultFileViewer.descriptorSummary(direct)
        let existingCount = urls.filter { FileSystemService.entryExists(at: $0) }.count
        DefaultFileViewer.requestLogger.notice("Reveal received: event=\(event.eventID) shape=\(shape, privacy: .public) decoded=\(urls.count) existing=\(existingCount)")
        guard !urls.isEmpty else {
            // Report unsupported requests instead of acknowledging a silent no-op.
            reply.setParam(NSAppleEventDescriptor(int32: -1700), forKeyword: keyErrorNumber)
            return
        }
        for (folder, files) in Dictionary(grouping: urls, by: { $0.deletingLastPathComponent() }) {
            let controller = createWindow(at: folder)
            let browser = (controller.contentViewController as? ExplorerWindowViewController)?.currentBrowser
            browser?.selectRevealedFiles(files)
        }
    }

    @objc private func configureDefaultFileViewer(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = L10n.text("Default File Manager")
        alert.informativeText = L10n.text("Use Mac Explorer for opening folders and Show in Finder requests. System Open/Save dialogs and apps that explicitly use Finder are unchanged. Restart other apps or log out if the change is not reflected immediately.")
        alert.addButton(withTitle: L10n.text("Use Mac Explorer"))
        alert.addButton(withTitle: L10n.text("Restore Finder"))
        alert.addButton(withTitle: L10n.text("Cancel"))
        let response = alert.runModal()
        guard response != .alertThirdButtonReturn else { return }
        DefaultFileViewer.configure(useExplorer: response == .alertFirstButtonReturn) { error in
            if let error { NSAlert(error: error).runModal() }
            else {
                let done = NSAlert()
                done.messageText = L10n.text("Default file manager updated.")
                done.runModal()
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        FolderAccessManager.shared.restoreAccess()
        let mainMenu = makeMainMenu()
        ShortcutRegistry.shared.resetDefinitions()
        ShortcutRegistry.shared.registerMenuShortcuts(in: mainMenu)
        registerExplorerShortcutAliases()
        NSApp.mainMenu = mainMenu
        installExplorerKeyMonitor()
        let controller = windowControllers.last ?? createWindow()
        // Finder owns the Desktop again. This also repairs the state left by an
        // interrupted build that used the old replacement Desktop.
        ExplorerDesktopManager.shared.setEnabled(false)
        FinderDesktopOpenInterceptor.shared.restoreLegacyGlobalFolderRegistrationIfNeeded()
        FinderDesktopOpenInterceptor.shared.setEnabled(
            ExplorerPreferences.openFinderDesktopFoldersInExplorer,
            presentingWindow: controller.window
        )
        // Launch Services can finish activating the app after this delegate
        // callback. Re-presenting on the next run-loop turn prevents the first
        // window from remaining ordered out when the app is opened from Finder.
        DispatchQueue.main.async { [self, controller] in
            self.presentInitialWindowIfNeeded(controller)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self, controller] in
            self.presentInitialWindowIfNeeded(controller)
        }
        hasFinishedInitialLaunch = true
        showFullDiskAccessPromptIfNeeded(in: controller.window)
        appUpdater.start()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard hasFinishedInitialLaunch else { return }
        DispatchQueue.main.async { [self] in
            // Merely activating the application (for example by closing a
            // settings panel or switching Spaces) must not restore, move, or
            // steal focus for a browser window the user left minimized. A
            // deliberate Dock reopen is handled by
            // applicationShouldHandleReopen(_:hasVisibleWindows:) below.
            let hasVisibleAuxiliaryWindow = settingsWindowController?.window?.isVisible == true
            if windowControllers.isEmpty && !hasVisibleAuxiliaryWindow {
                createWindow()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        windowCloseObservers.values.forEach(NotificationCenter.default.removeObserver)
        windowCloseObservers.removeAll()
        FinderDesktopOpenInterceptor.shared.stop()
        ExplorerDesktopManager.shared.prepareForApplicationTermination()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !ExplorerPreferences.openFinderDesktopFoldersInExplorer
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let controller = windowControllers.last(where: { $0.window?.isVisible == true && $0.window?.isMiniaturized == false }) {
            presentWindow(controller)
        } else if let controller = windowControllers.last {
            presentWindow(controller)
        } else {
            createWindow()
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        DefaultFileViewer.requestLogger.notice("Open received: count=\(urls.count) fileURLs=\(urls.filter(\.isFileURL).count)")
        var selections: [URL: [URL]] = [:]
        var missingFileCount = 0
        for incomingURL in urls where incomingURL.isFileURL {
            let url = DefaultFileViewer.filePathURL(incomingURL)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                missingFileCount += 1
                continue
            }
            let destination = isDirectory.boolValue ? url : url.deletingLastPathComponent()
            if selections[destination] == nil { selections[destination] = [] }
            if !isDirectory.boolValue { selections[destination]?.append(url) }
        }
        for (destination, files) in selections {
            let controller = createWindow(at: destination)
            if !files.isEmpty {
                (controller.contentViewController as? ExplorerWindowViewController)?
                    .currentBrowser?.selectRevealedFiles(files)
            }
        }
        DefaultFileViewer.requestLogger.notice("Open finished: windows=\(selections.count) missingOrInaccessible=\(missingFileCount)")
    }

    @discardableResult
    func createWindow(at url: URL? = nil) -> NSWindowController {
        let browser = ExplorerWindowViewController(initialURL: url)
        return createWindow(with: browser, near: nil)
    }

    @discardableResult
    func createWindow(with browser: ExplorerWindowViewController, near screenPoint: NSPoint?) -> NSWindowController {
        let window = ExplorerWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Mac Explorer"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 320, height: 420)
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.contentViewController = browser
        window.restoreAndRememberSize()

        if let screenPoint {
            let screen = NSScreen.screens.first(where: { $0.frame.contains(screenPoint) }) ?? NSScreen.main
            let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
            let origin = NSPoint(
                x: min(max(screenPoint.x - 220, visibleFrame.minX), visibleFrame.maxX - window.frame.width),
                y: min(max(screenPoint.y - window.frame.height + 42, visibleFrame.minY), visibleFrame.maxY - window.frame.height)
            )
            window.setFrameOrigin(origin)
        } else {
            window.center()
        }

        let controller = NSWindowController(window: window)
        windowControllers.append(controller)
        observeWindowClosure(of: controller)
        presentWindow(controller)
        return controller
    }

    private func presentWindow(_ controller: NSWindowController) {
        guard let window = controller.window else { return }
        NSApp.setActivationPolicy(.regular)
        if NSApp.isActive {
            window.collectionBehavior.remove(.canJoinAllSpaces)
            window.collectionBehavior.insert(.moveToActiveSpace)
        } else {
            window.collectionBehavior.remove(.moveToActiveSpace)
            window.collectionBehavior.insert(.canJoinAllSpaces)
        }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        if NSApp.isHidden {
            NSApp.unhideWithoutActivation()
        }
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        // Activate only the requested window, not every existing browser window.
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
    }

    private func presentInitialWindowIfNeeded(_ controller: NSWindowController) {
        guard let window = controller.window,
              !window.isVisible,
              !window.isMiniaturized else { return }
        presentWindow(controller)
    }

    private func observeWindowClosure(of controller: NSWindowController) {
        guard let window = controller.window else { return }
        let identifier = ObjectIdentifier(controller)
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self, weak controller] _ in
            guard let self else { return }
            if let controller {
                self.windowControllers.removeAll { $0 === controller }
            }
            if let observer = self.windowCloseObservers.removeValue(forKey: identifier) {
                NotificationCenter.default.removeObserver(observer)
            }
        }
        windowCloseObservers[identifier] = observer
    }

    private var currentContainer: ExplorerWindowViewController? {
        if let container = NSApp.keyWindow?.contentViewController as? ExplorerWindowViewController { return container }
        if let container = NSApp.mainWindow?.contentViewController as? ExplorerWindowViewController { return container }
        return NSApp.windows.lazy
            .filter(\.isVisible)
            .compactMap { $0.contentViewController as? ExplorerWindowViewController }
            .first
    }

    private var currentBrowser: MainViewController? {
        if let desktopBrowser = NSApp.keyWindow?.contentViewController as? MainViewController {
            return desktopBrowser
        }
        return currentContainer?.currentBrowser
    }

    @objc private func newWindow(_ sender: Any?) {
        createWindow(at: currentBrowser?.currentLocation.folderURL)
    }

    @objc private func newTab(_ sender: Any?) {
        currentContainer?.addTab()
    }

    @objc private func reopenClosedTab(_ sender: Any?) {
        currentContainer?.reopenClosedTab()
    }

    @objc private func closeWindow(_ sender: Any?) {
        NSApp.keyWindow?.performClose(sender)
    }

    @objc private func closeCurrentTab(_ sender: Any?) {
        if let settingsWindow = settingsWindowController?.window,
           settingsWindow.isVisible,
           settingsWindow.isKeyWindow {
            settingsWindow.performClose(sender)
            return
        }
        let targetWindow = NSApp.keyWindow ?? NSApp.mainWindow
        if let container = targetWindow?.contentViewController as? ExplorerWindowViewController {
            container.closeCurrentTab()
        } else {
            targetWindow?.performClose(sender)
        }
    }

    @objc private func focusAddressBar(_ sender: Any?) {
        currentBrowser?.focusAddressBar(sender)
    }

    @objc private func focusSearch(_ sender: Any?) {
        currentBrowser?.focusSearch(sender)
    }

    @objc private func refresh(_ sender: Any?) { currentBrowser?.refresh(sender) }
    @objc private func zoomIn(_ sender: Any?) { currentBrowser?.zoomIn(sender) }
    @objc private func zoomOut(_ sender: Any?) { currentBrowser?.zoomOut(sender) }
    @objc private func actualSize(_ sender: Any?) { currentBrowser?.actualSize(sender) }
    @objc private func togglePreviewPane(_ sender: Any?) { currentBrowser?.toggleDetailsPane(sender) }
    @objc private func goBackExplorer(_ sender: Any?) { currentBrowser?.goBack(sender) }
    @objc private func goForwardExplorer(_ sender: Any?) { currentBrowser?.goForward(sender) }
    @objc private func goUpExplorer(_ sender: Any?) { currentBrowser?.goUp(sender) }
    @objc private func connectToServer(_ sender: Any?) { currentBrowser?.connectToServer(sender) }
    @objc private func toggleTabBar(_ sender: Any?) { currentContainer?.toggleTabBar() }
    @objc private func toggleSplitView(_ sender: Any?) { currentContainer?.toggleSplitView() }
    @objc private func showActionPanel(_ sender: Any?) { ActionPanelWindowController.shared.present() }
    @objc private func showFileShelf(_ sender: Any?) {
        guard let browser = currentBrowser else { return }
        FileShelfWindowController.shared.present(for: browser)
    }

    @objc private func cutProxy(_ sender: Any?) {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView { editor.cut(sender) }
        else { currentBrowser?.cut(sender) }
    }

    @objc private func undoProxy(_ sender: Any?) {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
            editor.undoManager?.undo()
        } else {
            currentBrowser?.undoLastFileOperation(sender)
        }
    }

    @objc private func redoProxy(_ sender: Any?) {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
            editor.undoManager?.redo()
        } else {
            currentBrowser?.redoLastFileOperation(sender)
        }
    }

    @objc private func copyProxy(_ sender: Any?) {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView { editor.copy(sender) }
        else { currentBrowser?.copy(sender) }
    }

    @objc private func pasteProxy(_ sender: Any?) {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView { editor.paste(sender) }
        else { currentBrowser?.paste(sender) }
    }

    @objc private func pasteAndMoveProxy(_ sender: Any?) { currentBrowser?.pasteAndMove(sender) }

    private func showFullDiskAccessPromptIfNeeded(in window: NSWindow?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let accessManager = FullDiskAccessManager.shared
            accessManager.requestFullDiskAccessListRegistration { status in
                accessManager.requestProtectedAppDataAccess()
                let effectiveStatus = status == .unknown ? accessManager.probeStatus() : status
                guard effectiveStatus != .granted else { return }
                guard !UserDefaults.standard.bool(forKey: Self.fullDiskAccessPromptSuppressedKey) else { return }
                self.presentFullDiskAccessPrompt(in: window)
            }
        }
    }

    private func presentFullDiskAccessPrompt(in window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text("Full Disk Access Required")
        alert.informativeText = L10n.text("Mac Explorer has requested Full Disk Access and should now appear in the list with its switch off. Open System Settings, turn it on, then restart the app. If it is not listed, use the draggable app icon in the guide.")
        alert.addButton(withTitle: L10n.text("Open Full Disk Access"))
        alert.addButton(withTitle: L10n.text("Not Now"))
        alert.addButton(withTitle: L10n.text("Don't Show Again"))

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn {
                FullDiskAccessManager.shared.openSystemSettings()
            } else if response == .alertThirdButtonReturn {
                UserDefaults.standard.set(true, forKey: Self.fullDiskAccessPromptSuppressedKey)
            }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: completion) }
        else { completion(alert.runModal()) }
    }

    @objc private func openFullDiskAccess(_ sender: Any?) {
        FullDiskAccessManager.shared.openSystemSettings()
    }

    private var isFileListFocused: Bool {
        NSApp.keyWindow?.firstResponder is FileTableView
            || NSApp.keyWindow?.firstResponder is FileCollectionView
    }

    private func registerExplorerShortcutAliases() {
        let registry = ShortcutRegistry.shared
        let file = L10n.text("File")
        let view = L10n.text("View")
        let go = L10n.text("Go")
        let tabs = L10n.text("Tabs")

        func binding(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = []) -> ShortcutBinding {
            ShortcutBinding(keyCode: keyCode, modifiers: modifiers)
        }
        func register(
            _ id: String,
            _ title: String,
            _ category: String,
            mac: ShortcutBinding?,
            windows: ShortcutBinding?,
            allowsWhileEditingText: Bool = false,
            handler: @escaping () -> Bool
        ) {
            registry.register(ShortcutDefinition(
                id: id,
                title: title,
                category: category,
                macOSDefault: mac,
                windowsDefault: windows,
                allowsWhileEditingText: allowsWhileEditingText,
                handler: handler
            ))
        }
        func withBrowser(_ action: @escaping (MainViewController) -> Void) -> () -> Bool {
            { [weak self] in
                guard let browser = self?.currentBrowser else { return false }
                action(browser)
                return true
            }
        }
        func withFileList(_ action: @escaping (MainViewController) -> Void) -> () -> Bool {
            { [weak self] in
                guard let self, self.isFileListFocused, let browser = self.currentBrowser else { return false }
                action(browser)
                return true
            }
        }

        // These menu shortcuts must also pass through the local key monitor.
        // AppKit's menu-key dispatch is unreliable while the collection view is
        // first responder, especially with non-Roman input sources.
        registry.routeMenuShortcut(action: #selector(zoomIn(_:)), through: withBrowser { $0.zoomIn(nil) })
        registry.routeMenuShortcut(action: #selector(zoomOut(_:)), through: withBrowser { $0.zoomOut(nil) })
        registry.routeMenuShortcut(action: #selector(actualSize(_:)), through: withBrowser { $0.actualSize(nil) })
        registry.routeMenuShortcut(action: #selector(reopenClosedTab(_:))) { [weak self] in
            self?.currentContainer?.reopenClosedTab() == true
        }
        registry.routeMenuShortcut(action: #selector(undoProxy(_:))) { [weak self] in
            guard let browser = self?.currentBrowser else { return false }
            browser.undoLastFileOperation(nil)
            return true
        }
        registry.routeMenuShortcut(action: #selector(redoProxy(_:))) { [weak self] in
            guard let browser = self?.currentBrowser else { return false }
            browser.redoLastFileOperation(nil)
            return true
        }

        register("file.rename.f2", L10n.text("Rename (F2)"), file,
                 mac: binding(120), windows: binding(120), handler: withFileList { $0.rename(nil) })
        register("file.rename.return", L10n.text("Rename (Return)"), file,
                 mac: binding(36), windows: nil, handler: withFileList { $0.rename(nil) })
        register("file.rename.keypadReturn", L10n.text("Rename (Keypad Enter)"), file,
                 mac: binding(76), windows: nil, handler: withFileList { $0.rename(nil) })
        register("file.open.return", L10n.text("Open (Return)"), file,
                 mac: nil, windows: binding(36), handler: withFileList { $0.openSelection(nil) })
        register("file.open.keypadReturn", L10n.text("Open (Keypad Enter)"), file,
                 mac: nil, windows: binding(76), handler: withFileList { $0.openSelection(nil) })
        register("file.open.commandDown", L10n.text("Open (Command-Down Arrow)"), file,
                 mac: binding(125, .command), windows: binding(125, .command), handler: withFileList { $0.openSelection(nil) })
        register("file.quickLook.space", L10n.text("Quick Look (Space)"), file,
                 mac: binding(49), windows: binding(49), handler: withFileList { $0.quickLook(nil) })
        register("file.trash.forwardDelete", L10n.text("Move to Trash (Delete)"), file,
                 mac: binding(117), windows: binding(117), handler: withFileList { $0.moveToTrash(nil) })
        register("file.info.optionReturn", L10n.text("Get Info (Option-Return)"), file,
                 mac: binding(36, .option), windows: binding(36, .option), handler: withFileList { $0.showSelectionDetails(nil) })

        register("view.refresh.f5", L10n.text("Refresh (F5)"), view,
                 mac: binding(96), windows: binding(96), handler: withBrowser { $0.refresh(nil) })
        register("view.refresh.controlR", L10n.text("Refresh (Control-R)"), view,
                 mac: binding(15, .control), windows: binding(15, .control), handler: withBrowser { $0.refresh(nil) })
        register("view.search.f3", L10n.text("Search (F3)"), view,
                 mac: binding(99), windows: binding(99), allowsWhileEditingText: true,
                 handler: withBrowser { $0.focusSearch(nil) })
        register("view.search.controlE", L10n.text("Search (Control-E)"), view,
                 mac: binding(14, .control), windows: binding(14, .control), allowsWhileEditingText: true,
                 handler: withBrowser { $0.focusSearch(nil) })
        register("view.search.controlF", L10n.text("Search (Control-F)"), view,
                 mac: binding(3, .control), windows: binding(3, .control), allowsWhileEditingText: true,
                 handler: withBrowser { $0.focusSearch(nil) })
        register("view.location.f4", L10n.text("Location (F4)"), view,
                 mac: binding(118), windows: binding(118), allowsWhileEditingText: true,
                 handler: withBrowser { $0.focusAddressBar(nil) })
        register("view.location.controlL", L10n.text("Location (Control-L)"), view,
                 mac: binding(37, .control), windows: binding(37, .control), allowsWhileEditingText: true,
                 handler: withBrowser { $0.focusAddressBar(nil) })
        register("view.location.commandShiftG", L10n.text("Enter Location (Command-Shift-G)"), view,
                 mac: binding(5, [.command, .shift]), windows: binding(5, [.command, .shift]),
                 allowsWhileEditingText: true, handler: withBrowser { $0.focusAddressBar(nil) })
        register("view.cycleFocus.f6", L10n.text("Cycle Focus (F6)"), view,
                 mac: binding(97), windows: binding(97), allowsWhileEditingText: true,
                 handler: withBrowser { $0.cycleExplorerFocus(nil) })
        register("view.cycleFocus.shiftF6", L10n.text("Cycle Focus Backward (Shift-F6)"), view,
                 mac: binding(97, .shift), windows: binding(97, .shift), allowsWhileEditingText: true,
                 handler: withBrowser { $0.cycleExplorerFocusBackward(nil) })
        register("view.preview.optionP", L10n.text("Preview pane (Option-P)"), view,
                 mac: binding(35, .option), windows: binding(35, .option), handler: withBrowser { $0.toggleDetailsPane(nil) })
        register("view.fullScreen.f11", L10n.text("Full Screen (F11)"), view,
                 mac: binding(103), windows: binding(103)) { NSApp.keyWindow?.toggleFullScreen(nil); return NSApp.keyWindow != nil }

        register("go.back.optionLeft", L10n.text("Back (Option-Left Arrow)"), go,
                 mac: binding(123, .option), windows: binding(123, .option), handler: withBrowser { $0.goBack(nil) })
        register("go.forward.optionRight", L10n.text("Forward (Option-Right Arrow)"), go,
                 mac: binding(124, .option), windows: binding(124, .option), handler: withBrowser { $0.goForward(nil) })
        register("go.up.optionUp", L10n.text("Enclosing Folder (Option-Up Arrow)"), go,
                 mac: binding(126, .option), windows: binding(126, .option), handler: withBrowser { $0.goUp(nil) })
        register("go.back.backspace", L10n.text("Back (Backspace)"), go,
                 mac: nil, windows: binding(51), handler: withFileList { $0.goBack(nil) })

        register("tabs.next.controlTab", L10n.text("Next Tab"), tabs,
                 mac: binding(48, .control), windows: binding(48, .control)) { [weak self] in
            guard let container = self?.currentContainer else { return false }
            container.selectAdjacentTab(direction: 1); return true
        }
        register("tabs.previous.controlShiftTab", L10n.text("Previous Tab"), tabs,
                 mac: binding(48, [.control, .shift]), windows: binding(48, [.control, .shift])) { [weak self] in
            guard let container = self?.currentContainer else { return false }
            container.selectAdjacentTab(direction: -1); return true
        }
        register("tabs.new.controlT", L10n.text("New Tab (Control-T)"), tabs,
                 mac: binding(17, .control), windows: binding(17, .control)) { [weak self] in
            guard let container = self?.currentContainer else { return false }
            container.addTab(); return true
        }
        register("tabs.close.controlW", L10n.text("Close Tab (Control-W)"), tabs,
                 mac: binding(13, .control), windows: binding(13, .control)) { [weak self] in
            guard let self else { return false }
            self.closeCurrentTab(nil); return true
        }
        register("tabs.reopen.controlShiftT", L10n.text("Reopen Closed Tab"), tabs,
                 mac: ExplorerTabShortcutDefaults.reopenClosedTabWindowsAlias,
                 windows: ExplorerTabShortcutDefaults.reopenClosedTabWindowsAlias) { [weak self] in
            self?.currentContainer?.reopenClosedTab() == true
        }
        register("file.newFolder.controlShiftN", L10n.text("New Folder (Control-Shift-N)"), file,
                 mac: binding(45, [.control, .shift]), windows: binding(45, [.control, .shift]), handler: withBrowser { $0.newFolder(nil) })
        register("file.newWindow.controlN", L10n.text("New Window (Control-N)"), file,
                 mac: binding(45, .control), windows: binding(45, .control)) { [weak self] in
            guard let self, let browser = self.currentBrowser else { return false }
            self.createWindow(at: browser.currentLocation.folderURL); return true
        }

        let numberKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        for (index, keyCode) in numberKeyCodes.enumerated() {
            register("tabs.select.\(index + 1)", String(format: L10n.text("Select Tab %d"), index + 1), tabs,
                     mac: binding(keyCode, .control), windows: binding(keyCode, .control)) { [weak self] in
                guard let container = self?.currentContainer else { return false }
                container.selectTab(at: index); return true
            }
        }
    }

    private func installExplorerKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if NSApp.keyWindow?.firstResponder is ShortcutRecorderButton { return event }
            let isEditingText = NSApp.keyWindow?.firstResponder is NSTextView
            return ShortcutRegistry.shared.handleNonMenuShortcut(
                event: event,
                isEditingText: isEditingText
            ) ? nil : event
        }
    }

    @objc private func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Mac Explorer",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development",
            .credits: NSAttributedString(string: L10n.text("A native macOS file manager with an efficient workflow and an original interface."))
        ])
    }

    @objc private func showSettings(_ sender: Any?) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        guard let controller = settingsWindowController, let window = controller.window else { return }
        window.collectionBehavior.insert(.moveToActiveSpace)
        if window.isMiniaturized { window.deminiaturize(nil) }
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let aboutItem = appMenu.addItem(withTitle: L10n.text("About Mac Explorer"), action: #selector(showAbout(_:)), keyEquivalent: "")
        aboutItem.target = self
        let updateItem = appMenu.addItem(withTitle: L10n.text("Check for Updates") + "…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        updateItem.target = appUpdater.controller
        let automaticUpdatesItem = appMenu.addItem(withTitle: L10n.text("Automatically Check for Updates"),
            action: #selector(AppUpdater.toggleAutomaticChecks(_:)), keyEquivalent: "")
        automaticUpdatesItem.target = appUpdater
        let settingsItem = appMenu.addItem(withTitle: L10n.text("Settings") + "…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        let defaultViewerItem = appMenu.addItem(withTitle: L10n.text("Default File Manager") + "…",
            action: #selector(configureDefaultFileViewer(_:)), keyEquivalent: "")
        defaultViewerItem.target = self
        let fullDiskAccessItem = appMenu.addItem(withTitle: L10n.text("Full Disk Access") + "…", action: #selector(openFullDiskAccess(_:)), keyEquivalent: "")
        fullDiskAccessItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.text("Hide Mac Explorer"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: L10n.text("Hide Others"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: L10n.text("Show All"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.text("Quit Mac Explorer"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: L10n.text("File"))
        fileMenu.addItem(withTitle: L10n.text("New Window"), action: #selector(newWindow(_:)), keyEquivalent: "n")
        fileMenu.addItem(withTitle: L10n.text("New Tab"), action: #selector(newTab(_:)), keyEquivalent: "t")
        let reopenTab = fileMenu.addItem(
            withTitle: L10n.text("Reopen Closed Tab"),
            action: #selector(reopenClosedTab(_:)),
            keyEquivalent: ExplorerTabShortcutDefaults.reopenClosedTab.menuKeyEquivalent ?? "t"
        )
        reopenTab.keyEquivalentModifierMask = ExplorerTabShortcutDefaults.reopenClosedTab.modifiers
        reopenTab.target = self
        fileMenu.addItem(withTitle: L10n.text("New Folder"), action: #selector(MainViewController.newFolder(_:)), keyEquivalent: "n").keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(withTitle: L10n.text("New Folder with Selection"), action: #selector(MainViewController.newFolderWithSelection(_:)), keyEquivalent: "n").keyEquivalentModifierMask = [.command, .control]
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: L10n.text("Open"), action: #selector(MainViewController.openSelection(_:)), keyEquivalent: "o")
        fileMenu.addItem(withTitle: L10n.text("Quick Look"), action: #selector(MainViewController.quickLook(_:)), keyEquivalent: "y")
        fileMenu.addItem(withTitle: L10n.text("Get Info"), action: #selector(MainViewController.showSelectionDetails(_:)), keyEquivalent: "i")
        fileMenu.addItem(withTitle: L10n.text("Eject"), action: #selector(MainViewController.ejectCurrentVolume(_:)), keyEquivalent: "e")
        fileMenu.addItem(withTitle: L10n.text("Rename"), action: #selector(MainViewController.rename(_:)), keyEquivalent: "")
        fileMenu.addItem(withTitle: L10n.text("Duplicate"), action: #selector(MainViewController.duplicate(_:)), keyEquivalent: "d")
        fileMenu.addItem(withTitle: L10n.text("Move to Trash"), action: #selector(MainViewController.moveToTrash(_:)), keyEquivalent: "\u{8}")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: L10n.text("Close Tab"), action: #selector(closeCurrentTab(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: L10n.text("Edit"))
        let undoItem = editMenu.addItem(withTitle: L10n.text("Undo"), action: #selector(undoProxy(_:)), keyEquivalent: "z")
        undoItem.target = self
        let redoItem = editMenu.addItem(withTitle: L10n.text("Redo"), action: #selector(redoProxy(_:)), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        redoItem.target = self
        editMenu.addItem(.separator())
        let cutItem = editMenu.addItem(withTitle: L10n.text("Cut"), action: #selector(cutProxy(_:)), keyEquivalent: "x")
        cutItem.target = self
        let copyItem = editMenu.addItem(withTitle: L10n.text("Copy"), action: #selector(copyProxy(_:)), keyEquivalent: "c")
        copyItem.target = self
        let pasteItem = editMenu.addItem(withTitle: L10n.text("Paste"), action: #selector(pasteProxy(_:)), keyEquivalent: "v")
        pasteItem.target = self
        let movePaste = editMenu.addItem(withTitle: L10n.text("Move Item Here"), action: #selector(pasteAndMoveProxy(_:)), keyEquivalent: "v")
        movePaste.keyEquivalentModifierMask = [.command, .option]
        movePaste.target = self
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L10n.text("Select All"), action: #selector(MainViewController.selectAll(_:)), keyEquivalent: "a")
        let invertSelection = editMenu.addItem(withTitle: L10n.text("Invert Selection"), action: #selector(MainViewController.invertSelection(_:)), keyEquivalent: "i")
        invertSelection.keyEquivalentModifierMask = [.command, .control]
        editMenu.addItem(withTitle: L10n.text("Select Same Extension"), action: #selector(MainViewController.selectSameExtension(_:)), keyEquivalent: "")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: L10n.text("View"))
        let refreshItem = viewMenu.addItem(withTitle: L10n.text("Refresh"), action: #selector(refresh(_:)), keyEquivalent: "r")
        refreshItem.target = self
        viewMenu.addItem(withTitle: L10n.text("Show Hidden Files"), action: #selector(MainViewController.toggleHiddenFiles(_:)), keyEquivalent: ".").keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(withTitle: L10n.text("as Icons"), action: #selector(MainViewController.showIconView(_:)), keyEquivalent: "1")
        viewMenu.addItem(withTitle: L10n.text("as List"), action: #selector(MainViewController.showDetailsView(_:)), keyEquivalent: "2")
        viewMenu.addItem(withTitle: L10n.text("Show folder sizes"), action: #selector(MainViewController.toggleFolderSizes(_:)), keyEquivalent: "")
        let dateGroupingMenu = NSMenu(title: L10n.text("Date groups"))
        [(L10n.text("Automatic"), FileDateGroupingMode.automatic),
         (L10n.text("On"), FileDateGroupingMode.enabled),
         (L10n.text("Off"), FileDateGroupingMode.disabled)].forEach { title, mode in
            let item = dateGroupingMenu.addItem(
                withTitle: title,
                action: #selector(MainViewController.setDateGroupingMode(_:)),
                keyEquivalent: ""
            )
            item.tag = mode.rawValue
        }
        let dateGroupingItem = NSMenuItem(title: L10n.text("Date groups"), action: nil, keyEquivalent: "")
        dateGroupingItem.submenu = dateGroupingMenu
        viewMenu.addItem(dateGroupingItem)
        viewMenu.addItem(.separator())
        viewMenu.addItem(
            withTitle: L10n.text("Save View for This Folder"),
            action: #selector(MainViewController.saveViewForThisFolder(_:)),
            keyEquivalent: ""
        )
        viewMenu.addItem(
            withTitle: L10n.text("Apply View to Subfolders"),
            action: #selector(MainViewController.applyViewToSubfolders(_:)),
            keyEquivalent: ""
        )
        viewMenu.addItem(
            withTitle: L10n.text("Reset Folder View"),
            action: #selector(MainViewController.resetFolderView(_:)),
            keyEquivalent: ""
        )
        viewMenu.addItem(withTitle: L10n.text("Show View Options"), action: #selector(MainViewController.showViewOptions(_:)), keyEquivalent: "j")
        let sidebarItem = viewMenu.addItem(withTitle: L10n.text("Show or Hide Sidebar"), action: #selector(MainViewController.toggleSidebar(_:)), keyEquivalent: "s")
        sidebarItem.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(withTitle: L10n.text("Show or Hide Status Bar"), action: #selector(MainViewController.toggleStatusBar(_:)), keyEquivalent: "/")
        viewMenu.addItem(.separator())
        let previewItem = viewMenu.addItem(withTitle: L10n.text("Preview pane"), action: #selector(togglePreviewPane(_:)), keyEquivalent: "p")
        previewItem.keyEquivalentModifierMask = [.command, .shift]
        previewItem.target = self
        let splitItem = viewMenu.addItem(withTitle: L10n.text("Split View"), action: #selector(toggleSplitView(_:)), keyEquivalent: "\\")
        splitItem.target = self
        viewMenu.addItem(.separator())
        let zoomInItem = viewMenu.addItem(withTitle: L10n.text("Zoom In"), action: #selector(zoomIn(_:)), keyEquivalent: "+")
        zoomInItem.target = self
        let zoomOutItem = viewMenu.addItem(withTitle: L10n.text("Zoom Out"), action: #selector(zoomOut(_:)), keyEquivalent: "-")
        zoomOutItem.target = self
        let actualSizeItem = viewMenu.addItem(withTitle: L10n.text("Actual Size"), action: #selector(actualSize(_:)), keyEquivalent: "0")
        actualSizeItem.target = self
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        let goItem = NSMenuItem()
        let goMenu = NSMenu(title: L10n.text("Go"))
        goMenu.addItem(withTitle: L10n.text("Back"), action: #selector(MainViewController.goBack(_:)), keyEquivalent: "[")
        goMenu.addItem(withTitle: L10n.text("Forward"), action: #selector(MainViewController.goForward(_:)), keyEquivalent: "]")
        goMenu.addItem(withTitle: L10n.text("Enclosing Folder"), action: #selector(MainViewController.goUp(_:)), keyEquivalent: "\u{2191}")
        goMenu.addItem(withTitle: L10n.text("Computer"), action: #selector(MainViewController.goToComputer(_:)), keyEquivalent: "c").keyEquivalentModifierMask = [.command, .shift]
        goMenu.addItem(withTitle: L10n.text("Desktop"), action: #selector(MainViewController.goToDesktop(_:)), keyEquivalent: "d").keyEquivalentModifierMask = [.command, .shift]
        goMenu.addItem(withTitle: L10n.text("Recents"), action: #selector(MainViewController.goToRecents(_:)), keyEquivalent: "f").keyEquivalentModifierMask = [.command, .shift]
        goMenu.addItem(withTitle: L10n.text("Home Folder"), action: #selector(MainViewController.goToUserHome(_:)), keyEquivalent: "h").keyEquivalentModifierMask = [.command, .shift]
        goMenu.addItem(withTitle: L10n.text("Downloads"), action: #selector(MainViewController.goToDownloads(_:)), keyEquivalent: "l").keyEquivalentModifierMask = [.command, .option]
        goMenu.addItem(withTitle: L10n.text("Documents"), action: #selector(MainViewController.goToDocuments(_:)), keyEquivalent: "o").keyEquivalentModifierMask = [.command, .shift]
        goMenu.addItem(withTitle: L10n.text("iCloud Drive"), action: #selector(MainViewController.goToICloudDrive(_:)), keyEquivalent: "i").keyEquivalentModifierMask = [.command, .shift]
        goMenu.addItem(withTitle: L10n.text("Network"), action: #selector(MainViewController.showNetwork(_:)), keyEquivalent: "k").keyEquivalentModifierMask = [.command, .shift]
        goMenu.addItem(withTitle: L10n.text("Utilities"), action: #selector(MainViewController.goToUtilities(_:)), keyEquivalent: "u").keyEquivalentModifierMask = [.command, .shift]
        goMenu.addItem(withTitle: L10n.text("AirDrop"), action: #selector(MainViewController.openAirDrop(_:)), keyEquivalent: "r").keyEquivalentModifierMask = [.command, .shift]
        goMenu.addItem(.separator())
        let locationItem = goMenu.addItem(withTitle: L10n.text("Location"), action: #selector(focusAddressBar(_:)), keyEquivalent: "l")
        locationItem.target = self
        let enterLocationItem = goMenu.addItem(withTitle: L10n.text("Enter Location"), action: #selector(focusAddressBar(_:)), keyEquivalent: "d")
        enterLocationItem.keyEquivalentModifierMask = [.option]
        enterLocationItem.target = self
        let searchItem = goMenu.addItem(withTitle: L10n.text("Search"), action: #selector(focusSearch(_:)), keyEquivalent: "f")
        searchItem.target = self
        let connectItem = goMenu.addItem(withTitle: L10n.text("Connect to Server") + "…", action: #selector(connectToServer(_:)), keyEquivalent: "k")
        connectItem.target = self
        let toggleTabs = goMenu.addItem(withTitle: L10n.text("Show or Hide Tab Bar"), action: #selector(toggleTabBar(_:)), keyEquivalent: "t")
        toggleTabs.keyEquivalentModifierMask = ExplorerTabShortcutDefaults.toggleTabBar.modifiers
        toggleTabs.target = self
        goItem.submenu = goMenu
        mainMenu.addItem(goItem)

        let toolsItem = NSMenuItem()
        let toolsMenu = NSMenu(title: L10n.text("Tools"))
        let actionPanel = toolsMenu.addItem(
            withTitle: L10n.text("Action Panel") + "…",
            action: #selector(showActionPanel(_:)),
            keyEquivalent: "p"
        )
        actionPanel.keyEquivalentModifierMask = [.control, .shift]
        actionPanel.target = self
        let shelf = toolsMenu.addItem(withTitle: L10n.text("File Shelf") + "…", action: #selector(showFileShelf(_:)), keyEquivalent: "")
        shelf.target = self
        toolsMenu.addItem(.separator())
        toolsMenu.addItem(withTitle: L10n.text("Quick Select") + "…", action: #selector(MainViewController.quickSelect(_:)), keyEquivalent: "")
        toolsMenu.addItem(withTitle: L10n.text("View Contents"), action: #selector(MainViewController.viewContents(_:)), keyEquivalent: "")
        toolsMenu.addItem(withTitle: L10n.text("Create Link") + "…", action: #selector(MainViewController.createLink(_:)), keyEquivalent: "")
        toolsMenu.addItem(withTitle: L10n.text("Open in Other Pane"), action: #selector(MainViewController.openInOtherPane(_:)), keyEquivalent: "")
        toolsMenu.addItem(.separator())
        toolsMenu.addItem(withTitle: L10n.text("Compare Panes"), action: #selector(MainViewController.comparePanes(_:)), keyEquivalent: "")
        toolsMenu.addItem(withTitle: L10n.text("Storage Map"), action: #selector(MainViewController.showStorageMap(_:)), keyEquivalent: "")
        toolsMenu.addItem(withTitle: L10n.text("Open in Terminal"), action: #selector(MainViewController.openInTerminal(_:)), keyEquivalent: "")
        toolsItem.submenu = toolsMenu
        mainMenu.addItem(toolsItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: L10n.text("Window"))
        windowMenu.addItem(withTitle: L10n.text("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: L10n.text("Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: L10n.text("Bring All to Front"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        return mainMenu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        validateMenuItem(menuItem, textEditor: NSApp.keyWindow?.firstResponder as? NSTextView)
    }

    func validateMenuItem(_ menuItem: NSMenuItem, textEditor: NSTextView?) -> Bool {
        if let editor = textEditor {
            let textAction: Selector?
            switch menuItem.action {
            case #selector(copyProxy(_:)): textAction = #selector(NSText.copy(_:))
            case #selector(cutProxy(_:)): textAction = #selector(NSText.cut(_:))
            case #selector(pasteProxy(_:)): textAction = #selector(NSText.paste(_:))
            default: textAction = nil
            }
            if let textAction {
                return editor.validateMenuItem(NSMenuItem(title: menuItem.title,
                    action: textAction, keyEquivalent: ""))
            }
        }
        if menuItem.action == #selector(undoProxy(_:)) {
            if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                return editor.undoManager?.canUndo == true
            }
            return currentBrowser?.canUndoFileOperation == true
        }
        if menuItem.action == #selector(redoProxy(_:)) {
            if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                return editor.undoManager?.canRedo == true
            }
            return currentBrowser?.canRedoFileOperation == true
        }
        if menuItem.action == #selector(reopenClosedTab(_:)) {
            return currentContainer != nil && RecentlyClosedTabStore.shared.canReopen
        }
        if menuItem.action == #selector(toggleSplitView(_:)) {
            menuItem.title = L10n.text(isCurrentTabSplit ? "Close Split View" : "Split View")
            return currentBrowser != nil
        }
        if menuItem.action == #selector(MainViewController.toggleHiddenFiles(_:)) {
            menuItem.state = currentBrowser?.isShowingHiddenFiles == true ? .on : .off
            return currentBrowser != nil
        }
        if menuItem.action == #selector(MainViewController.setDateGroupingMode(_:)) {
            guard let browser = currentBrowser else { return false }
            menuItem.state = menuItem.tag == browser.currentDateGroupingMode.rawValue ? .on : .off
            return browser.canConfigureDateGrouping
        }
        if menuItem.action == #selector(MainViewController.toggleFolderSizes(_:)) {
            guard let browser = currentBrowser else { return false }
            menuItem.state = browser.isShowingFolderSizes ? .on : .off
            return browser.canConfigureFolderSizes
        }
        if menuItem.action == #selector(MainViewController.saveViewForThisFolder(_:))
            || menuItem.action == #selector(MainViewController.applyViewToSubfolders(_:)) {
            return currentBrowser?.canConfigureFolderView == true
        }
        if menuItem.action == #selector(MainViewController.resetFolderView(_:)) {
            return currentBrowser?.canConfigureFolderView == true
                && currentBrowser?.hasSavedViewForCurrentFolder == true
        }
        if menuItem.action == #selector(cutProxy(_:)) {
            return currentBrowser?.canRenameSelection == true
        }
        if menuItem.action == #selector(copyProxy(_:)) {
            return currentBrowser?.hasFileSelection == true
        }
        if menuItem.action == #selector(pasteProxy(_:))
            || menuItem.action == #selector(pasteAndMoveProxy(_:)) {
            return currentBrowser?.canPasteItems == true
        }
        return true
    }

    private var isCurrentTabSplit: Bool {
        currentContainer?.isCurrentTabSplit ?? false
    }
}
