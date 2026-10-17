import AppKit
import ApplicationServices
import CoreServices

/// Leaves the Finder Desktop completely intact and reroutes only a folder
/// double-click to Mac Explorer. A listen-only monitor cannot cancel Finder's
/// own open action, so this uses an Accessibility-authorized event tap.
final class FinderDesktopOpenInterceptor {
    static let shared = FinderDesktopOpenInterceptor()

    private static let previousFileViewerKey = "PreviousFileViewerBundleIdentifier"
    private static let previousFolderHandlerKey = "PreviousFolderHandlerBundleIdentifier"

    private let systemWideElement = AXUIElementCreateSystemWide()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var activationObserver: NSObjectProtocol?
    private weak var presentingWindow: NSWindow?
    private var isEnabled = false
    private var suppressNextMouseUp = false
    private var hasShownPermissionAlert = false

    private init() {}

    func setEnabled(_ enabled: Bool, presentingWindow: NSWindow? = nil) {
        self.presentingWindow = presentingWindow ?? self.presentingWindow
        isEnabled = enabled

        if enabled {
            installActivationObserverIfNeeded()
            requestPermissionAndStart(prompt: true)
        } else {
            stop()
        }
    }

    func stop() {
        isEnabled = false
        suppressNextMouseUp = false
        hasShownPermissionAlert = false
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
    }

    /// Earlier builds changed the system-wide folder viewer for this same
    /// preference. Restore that registration once so the new integration is
    /// strictly limited to Finder's Desktop.
    func restoreLegacyGlobalFolderRegistrationIfNeeded() {
        let defaults = UserDefaults.standard
        guard Self.hasLegacyRegistrationToRestore(defaults: defaults) else { return }
        let appIdentifier = Bundle.main.bundleIdentifier ?? "app.macexplorer.filemanager"

        if currentFolderHandler == appIdentifier,
           let savedHandler = defaults.string(forKey: Self.previousFolderHandlerKey) {
            let previous = savedHandler.isEmpty ? "com.apple.finder" : savedHandler
            _ = LSSetDefaultRoleHandlerForContentType("public.folder" as CFString, .all, previous as CFString)
            _ = LSSetDefaultRoleHandlerForContentType("public.folder" as CFString, .viewer, previous as CFString)
        }

        if currentFileViewer == appIdentifier,
           let previous = defaults.string(forKey: Self.previousFileViewerKey) {
            let value: CFPropertyList? = DefaultFileViewer.fileViewerOverride(for: previous).map { $0 as CFString }
            CFPreferencesSetValue(
                "NSFileViewer" as CFString,
                value,
                kCFPreferencesAnyApplication,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost
            )
            _ = CFPreferencesSynchronize(
                kCFPreferencesAnyApplication,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost
            )
        }

        defaults.removeObject(forKey: Self.previousFileViewerKey)
        defaults.removeObject(forKey: Self.previousFolderHandlerKey)
    }

    static func hasLegacyRegistrationToRestore(defaults: UserDefaults) -> Bool {
        guard !defaults.bool(forKey: DefaultFileViewer.enabledKey) else { return false }
        // An absent opt-in flag is not evidence that the Desktop integration
        // changed these settings. Without an actual saved migration record,
        // this used to undo choices made via Launch Services on every launch.
        return defaults.string(forKey: previousFolderHandlerKey) != nil
            || defaults.string(forKey: previousFileViewerKey) != nil
    }

    private var currentFolderHandler: String? {
        LSCopyDefaultRoleHandlerForContentType("public.folder" as CFString, .all)?
            .takeRetainedValue() as String?
    }

    private var currentFileViewer: String? {
        CFPreferencesCopyValue(
            "NSFileViewer" as CFString,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? String
    }

    private func installActivationObserverIfNeeded() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isEnabled, self.eventTap == nil else { return }
            self.requestPermissionAndStart(prompt: false)
        }
    }

    private func requestPermissionAndStart(prompt: Bool) {
        guard isEnabled, eventTap == nil else { return }
        let option = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([option: prompt] as CFDictionary)
        guard trusted else {
            if prompt { showPermissionAlertOnce() }
            return
        }
        installEventTap()
    }

    private func installEventTap() {
        let mask = (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let interceptor = Unmanaged<FinderDesktopOpenInterceptor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()
            return interceptor.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            showPermissionAlertOnce()
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        if type == .leftMouseUp, suppressNextMouseUp {
            suppressNextMouseUp = false
            return nil
        }

        guard type == .leftMouseDown,
              event.getIntegerValueField(.mouseEventClickState) == 2,
              let folderURL = finderDesktopFolder(at: event.location) else {
            return Unmanaged.passUnretained(event)
        }

        suppressNextMouseUp = true
        DispatchQueue.main.async {
            guard self.isEnabled else { return }
            NSApp.activate(ignoringOtherApps: true)
            (NSApp.delegate as? AppDelegate)?.createWindow(at: folderURL)
        }
        return nil
    }

    private func finderDesktopFolder(at point: CGPoint) -> URL? {
        var hitElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(point.x),
            Float(point.y),
            &hitElement
        ) == .success,
        let hitElement else { return nil }

        var finderPID: pid_t = 0
        guard AXUIElementGetPid(hitElement, &finderPID) == .success,
              NSRunningApplication(processIdentifier: finderPID)?.bundleIdentifier == "com.apple.finder" else {
            return nil
        }
        guard isFinderDesktopSurface(at: point, finderPID: finderPID) else { return nil }

        var candidate: URL?
        var possibleNames: [String] = []
        var element: AXUIElement? = hitElement
        var visited = 0
        while let current = element, visited < 10 {
            if candidate == nil {
                candidate = directURL(from: current)
            }
            possibleNames.append(contentsOf: names(from: current))
            element = attributeElement(kAXParentAttribute, from: current)
            visited += 1
        }
        if candidate == nil {
            candidate = desktopItemURL(named: possibleNames)
        }

        guard let candidate = candidate?.standardizedFileURL,
              isDirectDesktopItem(candidate) else { return nil }
        let values = try? candidate.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        guard values?.isDirectory == true, values?.isPackage != true else { return nil }
        return candidate
    }

    private func isFinderDesktopSurface(at point: CGPoint, finderPID: pid_t) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let desktopIconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == finderPID,
                  let boundsDictionary = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  bounds.contains(point) else { continue }
            // CGWindowList is front-to-back. A normal Finder window showing the
            // Desktop directory is therefore rejected before the Desktop layer.
            return (window[kCGWindowLayer as String] as? NSNumber)?.intValue == desktopIconLevel
        }
        return false
    }

    private func directURL(from element: AXUIElement) -> URL? {
        for attribute in [kAXURLAttribute as String, "AXDocument", "AXFilename"] {
            guard let value = attributeValue(attribute, from: element) else { continue }
            if let url = value as? URL { return url }
            if let url = value as? NSURL { return url as URL }
            if let string = value as? String {
                if let url = URL(string: string), url.isFileURL { return url }
                return URL(fileURLWithPath: string)
            }
        }
        return nil
    }

    private func names(from element: AXUIElement) -> [String] {
        [
            attributeString(kAXTitleAttribute, from: element),
            attributeString(kAXDescriptionAttribute, from: element),
            attributeString("AXFilename", from: element)
        ].compactMap { $0 }.filter { !$0.isEmpty }
    }

    private func desktopItemURL(named possibleNames: [String]) -> URL? {
        guard !possibleNames.isEmpty else { return nil }

        let desktop = desktopURL
        for name in possibleNames {
            let directCandidate = desktop.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: directCandidate.path) {
                return directCandidate
            }
        }
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: desktop,
            includingPropertiesForKeys: [.localizedNameKey],
            options: []
        ) else { return nil }
        return items.first { item in
            let localizedName = (try? item.resourceValues(forKeys: [.localizedNameKey]))?.localizedName
            return possibleNames.contains(item.lastPathComponent)
                || localizedName.map(possibleNames.contains) == true
        }
    }

    private var desktopURL: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    private func isDirectDesktopItem(_ url: URL) -> Bool {
        url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            == desktopURL.resolvingSymlinksInPath().standardizedFileURL
    }

    private func attributeValue(_ attribute: String, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private func attributeString(_ attribute: String, from element: AXUIElement) -> String? {
        attributeValue(attribute, from: element) as? String
    }

    private func attributeElement(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        guard let value = attributeValue(attribute, from: element),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func showPermissionAlertOnce() {
        guard !hasShownPermissionAlert else { return }
        hasShownPermissionAlert = true
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = L10n.text("Accessibility Permission Required")
            alert.informativeText = L10n.text("Mac Explorer needs Accessibility permission to intercept folder double-clicks on the Finder Desktop. Turn on Mac Explorer in System Settings, then return to the app.")
            alert.addButton(withTitle: L10n.text("Open Accessibility Settings"))
            alert.addButton(withTitle: L10n.text("Not Now"))
            let completion: (NSApplication.ModalResponse) -> Void = { response in
                guard response == .alertFirstButtonReturn else { return }
                self.openAccessibilitySettings()
            }
            if let window = self.presentingWindow ?? NSApp.keyWindow {
                alert.beginSheetModal(for: window, completionHandler: completion)
            } else {
                completion(alert.runModal())
            }
        }
    }

    private func openAccessibilitySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        ]
        for value in candidates {
            if let url = URL(string: value), NSWorkspace.shared.open(url) { return }
        }
    }
}
