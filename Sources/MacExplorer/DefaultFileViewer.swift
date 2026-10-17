import AppKit
import CoreServices
import UniformTypeIdentifiers
import OSLog

enum DefaultFileViewer {
    static let requestLogger = Logger(subsystem: "app.macexplorer.filemanager", category: "FileViewerRequests")

    /// Log structure only, never filenames, paths or raw event descriptors.
    static func descriptorSummary(_ descriptor: NSAppleEventDescriptor, depth: Int = 0) -> String {
        guard depth < 4 else { return "nested" }
        let type = String(format: "%08x", descriptor.descriptorType)
        if descriptor.descriptorType == typeAEList {
            let children = (0..<min(descriptor.numberOfItems, 8)).compactMap { index in
                descriptor.atIndex(index + 1).map { descriptorSummary($0, depth: depth + 1) }
            }.joined(separator: ",")
            return "list(count=\(descriptor.numberOfItems)):[\(children)]"
        }
        if [typeUnicodeText, typeUTF8Text, typeChar].contains(descriptor.descriptorType),
           let value = descriptor.stringValue {
            let format = value.hasPrefix("/") ? "absolute-path"
                : value.hasPrefix("file:") ? "file-url"
                : value.contains(":") ? "colon-text" : "other-text"
            return "\(type):\(format)"
        }
        if descriptor.descriptorType == typeObjectSpecifier {
            let key = descriptor.forKeyword(AEKeyword(keyAEKeyData))
                .map { descriptorSummary($0, depth: depth + 1) } ?? "missing"
            let container = descriptor.forKeyword(AEKeyword(keyAEContainer))
                .map { descriptorSummary($0, depth: depth + 1) } ?? "missing"
            return "\(type):key=\(key),container=\(container)"
        }
        return type
    }
    static let enabledKey = "DefaultFileViewerExplicitlyEnabled"
    static let finderIdentifier = "com.apple.finder"

    /// Finder is the system fallback, not an alternate document-opening app.
    /// Explicitly setting NSFileViewer to Finder routes reveal requests through
    /// ordinary document opening, which sandboxed senders can have rejected.
    static func fileViewerOverride(for identifier: String) -> String? {
        identifier == finderIdentifier || identifier.isEmpty ? nil : identifier
    }

    struct Registration {
        let folderHandler: String?
        let fileViewer: String?

        func matches(_ identifier: String) -> Bool {
            folderHandler == identifier && fileViewer == DefaultFileViewer.fileViewerOverride(for: identifier)
        }
    }

    static var registration: Registration {
        Registration(
            folderHandler: LSCopyDefaultRoleHandlerForContentType("public.folder" as CFString, .all)?
                .takeRetainedValue() as String?,
            fileViewer: CFPreferencesCopyValue("NSFileViewer" as CFString,
                kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String
        )
    }

    static func logRegistrationStatus() {
        guard let identifier = Bundle.main.bundleIdentifier else { return }
        let current = registration
        requestLogger.notice("Default viewer registration: foldersMatch=\(current.folderHandler == identifier) revealMatches=\(current.fileViewer == identifier) explicitlyEnabled=\(UserDefaults.standard.bool(forKey: enabledKey))")
    }
    static let revealEventClass: AEEventClass = 0x6D697363 // misc
    // Finder.sdef defines reveal as misc/mvis. Keep the earlier revl alias for
    // clients that already send it, but do not rely on it for Finder compatibility.
    static let revealEventIDs: [AEEventID] = [0x6D766973, 0x7265766C]

    static func revealedURLs(from direct: NSAppleEventDescriptor) -> [URL] {
        var seen = Set<URL>()
        return decodeURLs(from: direct, depth: 0).map(filePathURL).filter { seen.insert($0).inserted }
    }

    static func filePathURL(_ url: URL) -> URL {
        // System reveal requests can use /.file/id=… references. Resolve those
        // before taking the parent, otherwise we try to browse /.file instead.
        ((url as NSURL).filePathURL ?? url).standardizedFileURL
    }

    private static func decodeURLs(from descriptor: NSAppleEventDescriptor, depth: Int) -> [URL] {
        guard depth < 16 else { return [] }
        if descriptor.descriptorType == typeAEList {
            return (0..<descriptor.numberOfItems).flatMap { index in
                descriptor.atIndex(index + 1).map { decodeURLs(from: $0, depth: depth + 1) } ?? []
            }
        }
        // Some reveal senders use text paths instead of alias/file-URL data.
        // Decode text before coercion: Apple Event text-to-file coercion treats
        // URL strings as HFS paths (e.g. file:///tmp becomes /file/:::tmp).
        if [typeUnicodeText, typeUTF8Text, typeChar].contains(descriptor.descriptorType),
           let value = descriptor.stringValue {
            if value.hasPrefix("/") { return [URL(fileURLWithPath: value).standardizedFileURL] }
            if let url = URL(string: value), url.isFileURL { return [url.standardizedFileURL] }
            return []
        }
        if let fileDescriptor = descriptor.descriptorType == typeFileURL
                ? descriptor : descriptor.coerce(toDescriptorType: typeFileURL),
           let value = String(data: fileDescriptor.data, encoding: .utf8),
           let url = URL(string: value), url.isFileURL {
            return [url.standardizedFileURL]
        }
        // Finder-style named file specifiers carry a path in keyAEKeyData.
        // Do not evaluate arbitrary AppleScript object specifiers.
        if descriptor.descriptorType == typeObjectSpecifier,
           descriptor.forKeyword(AEKeyword(keyAEKeyForm))?.enumCodeValue == OSType(formName),
           let container = descriptor.forKeyword(AEKeyword(keyAEContainer)), container.descriptorType == typeNull,
           let key = descriptor.forKeyword(AEKeyword(keyAEKeyData)) {
            return decodeURLs(from: key, depth: depth + 1)
        }
        return []
    }

    static func configure(useExplorer: Bool, completion: @escaping (Error?) -> Void) {
        let target = useExplorer ? Bundle.main.bundleURL
            : NSWorkspace.shared.urlForApplication(withBundleIdentifier: finderIdentifier)
        guard let target, target.pathExtension == "app",
              let identifier = Bundle(url: target)?.bundleIdentifier else {
            completion(NSError(domain: "DefaultFileViewer", code: 1, userInfo: [
                NSLocalizedDescriptionKey: L10n.text("Run the installed Mac Explorer app to change the default file manager.")
            ]))
            return
        }
        // Only folders are registered: never take over ordinary document types.
        NSWorkspace.shared.setDefaultApplication(at: target, toOpen: UTType.folder) { error in
            DispatchQueue.main.async {
                guard error == nil else { completion(error); return }
                let viewerOverride = fileViewerOverride(for: identifier).map { $0 as CFString }
                CFPreferencesSetValue("NSFileViewer" as CFString, viewerOverride,
                    kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                let saved = CFPreferencesSynchronize(kCFPreferencesAnyApplication,
                    kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                guard saved, registration.matches(identifier) else {
                    logRegistrationStatus()
                    completion(NSError(domain: "DefaultFileViewer", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: L10n.text("The default file manager settings could not be fully applied. Please try again.")
                    ]))
                    return
                }
                // Prevent the old Desktop-only migration from undoing this explicit choice.
                UserDefaults.standard.set(useExplorer, forKey: enabledKey)
                logRegistrationStatus()
                completion(nil)
            }
        }
    }
}
