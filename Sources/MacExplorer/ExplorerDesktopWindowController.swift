import AppKit
import CoreGraphics

private final class ExplorerDesktopWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the desktop-level browser used when Mac Explorer Desktop is enabled.
/// Finder still owns wallpaper, widgets, the menu bar, and the Dock; only Finder's
/// file-icon layer is disabled while this controller is active.
final class ExplorerDesktopWindowController: NSWindowController {
    let browser: MainViewController

    init(screen: NSScreen, openURL: @escaping (URL) -> Void) {
        let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        browser = MainViewController(initialURL: desktopURL, desktopPresentation: true)
        browser.desktopOpenHandler = openURL

        let window = ExplorerDesktopWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.contentViewController = browser
        window.setFrame(screen.frame, display: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.canHide = false
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.isExcludedFromWindowsMenu = true
        window.acceptsMouseMovedEvents = true
        window.animationBehavior = .none
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showBehindApplications() {
        guard let window else { return }
        window.orderBack(nil)
    }
}

final class ExplorerDesktopManager {
    static let shared = ExplorerDesktopManager()

    private static let finderDomain = "com.apple.finder" as CFString
    private static let createDesktopKey = "CreateDesktop" as CFString
    private static let capturedKey = "ExplorerFinderDesktopStateCaptured"
    private static let previousPresentKey = "ExplorerFinderDesktopPreviousPresent"
    private static let previousValueKey = "ExplorerFinderDesktopPreviousValue"

    private var controller: ExplorerDesktopWindowController?
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var displacedWindows: [NSWindow] = []
    private var displacedApplications: [NSRunningApplication] = []
    private var lastExternalFrontmostApplication: NSRunningApplication?
    private var isShowingDesktop = false

    var browser: MainViewController? { controller?.browser }
    var isRunning: Bool { controller != nil }

    private init() {}

    func setEnabled(_ enabled: Bool) {
        if enabled {
            start()
        } else {
            stop(restoreFinderDesktop: true)
        }
    }

    func prepareForApplicationTermination() {
        restoreDisplacedWindows(activatePreviousApplication: false)
        stop(restoreFinderDesktop: true)
    }

    func toggleShowDesktop() {
        if isShowingDesktop {
            restoreDisplacedWindows(activatePreviousApplication: true)
        } else {
            revealDesktop()
        }
    }

    private func start() {
        guard controller == nil else {
            controller?.showBehindApplications()
            return
        }
        captureFinderDesktopStateIfNeeded()

        guard let screen = NSScreen.screens.first ?? NSScreen.main else { return }
        let newController = ExplorerDesktopWindowController(screen: screen) { [weak self] url in
            self?.restoreDisplacedWindows(activatePreviousApplication: false)
            (NSApp.delegate as? AppDelegate)?.createWindow(at: url)
        }
        controller = newController
        newController.showBehindApplications()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.rebuildForCurrentMainScreen()
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.controller?.showBehindApplications()
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  application.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            self?.lastExternalFrontmostApplication = application
        }

        if setFinderDesktopFilesVisible(false) {
            restartFinder()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.controller?.showBehindApplications()
        }
    }

    private func stop(restoreFinderDesktop: Bool) {
        restoreDisplacedWindows(activatePreviousApplication: false)
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
            self.spaceObserver = nil
        }
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        controller?.window?.orderOut(nil)
        controller?.close()
        controller = nil

        guard restoreFinderDesktop else { return }
        if restoreCapturedFinderDesktopState() {
            restartFinder()
        }
    }

    private func rebuildForCurrentMainScreen() {
        guard controller != nil, let screen = NSScreen.screens.first ?? NSScreen.main else { return }
        controller?.window?.orderOut(nil)
        controller?.close()
        let replacement = ExplorerDesktopWindowController(screen: screen) { [weak self] url in
            self?.restoreDisplacedWindows(activatePreviousApplication: false)
            (NSApp.delegate as? AppDelegate)?.createWindow(at: url)
        }
        controller = replacement
        replacement.showBehindApplications()
    }

    private func captureFinderDesktopStateIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.capturedKey) else { return }
        let current = CFPreferencesCopyValue(
            Self.createDesktopKey,
            Self.finderDomain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        defaults.set(true, forKey: Self.capturedKey)
        defaults.set(current != nil, forKey: Self.previousPresentKey)
        if let value = current as? Bool {
            defaults.set(value, forKey: Self.previousValueKey)
        } else {
            defaults.removeObject(forKey: Self.previousValueKey)
        }
    }

    @discardableResult
    private func restoreCapturedFinderDesktopState() -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Self.capturedKey) else { return false }
        let current = CFPreferencesCopyValue(
            Self.createDesktopKey,
            Self.finderDomain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? Bool
        let changed = current != true
        _ = setFinderPreference(true as CFBoolean)
        defaults.removeObject(forKey: Self.capturedKey)
        defaults.removeObject(forKey: Self.previousPresentKey)
        defaults.removeObject(forKey: Self.previousValueKey)
        return changed
    }

    @discardableResult
    private func setFinderDesktopFilesVisible(_ visible: Bool) -> Bool {
        let current = CFPreferencesCopyValue(
            Self.createDesktopKey,
            Self.finderDomain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? Bool
        guard current != visible else { return false }
        return setFinderPreference(visible as CFBoolean)
    }

    @discardableResult
    private func setFinderPreference(_ value: CFPropertyList?) -> Bool {
        CFPreferencesSetValue(
            Self.createDesktopKey,
            value,
            Self.finderDomain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        return CFPreferencesSynchronize(
            Self.finderDomain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
    }

    private func restartFinder() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "sleep 0.25; /usr/bin/killall Finder >/dev/null 2>&1 || true; sleep 0.25; /usr/bin/open -gj /System/Library/CoreServices/Finder.app"
        ]
        try? process.run()
    }

    private func revealDesktop() {
        guard let desktopWindow = controller?.window else { return }
        displacedWindows = NSApp.windows.filter {
            $0 !== desktopWindow && $0.isVisible && $0.level == .normal
        }
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        displacedApplications = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
                && !$0.isHidden
                && !$0.isTerminated
                && $0.bundleIdentifier != ownBundleIdentifier
        }

        displacedWindows.forEach { $0.orderOut(nil) }
        NSWorkspace.shared.hideOtherApplications()
        controller?.showBehindApplications()
        isShowingDesktop = true
    }

    private func restoreDisplacedWindows(activatePreviousApplication: Bool) {
        guard isShowingDesktop || !displacedWindows.isEmpty || !displacedApplications.isEmpty else { return }
        let applications = displacedApplications
        let windows = displacedWindows
        displacedApplications.removeAll()
        displacedWindows.removeAll()
        isShowingDesktop = false

        applications.filter { !$0.isTerminated }.forEach { $0.unhide() }
        windows.forEach { $0.orderFrontRegardless() }
        if activatePreviousApplication,
           let previous = lastExternalFrontmostApplication,
           !previous.isTerminated {
            previous.activate(options: [.activateAllWindows])
        }
        controller?.showBehindApplications()
    }
}
