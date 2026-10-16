import AppKit
import Darwin

enum FullDiskAccessStatus {
    case granted
    case denied
    case unknown
}

final class FullDiskAccessManager {
    static let shared = FullDiskAccessManager()

    private var dragGuideWindowController: FullDiskAccessDragGuideWindowController?

    private init() {}

    /// Causes a real SystemPolicyAllFiles denial when Full Disk Access is off.
    ///
    /// Full Disk Access has no public request API and does not show a consent
    /// alert. Instead, macOS adds responsible apps to the Full Disk Access list
    /// after they attempt an operation protected by SystemPolicyAllFiles. Run
    /// the probe through a child process so TCC attributes the operation to the
    /// parent GUI app and records Mac Explorer as the responsible application.
    func requestFullDiskAccessListRegistration(
        completion: @escaping (FullDiskAccessStatus) -> Void
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let protectedPaths = [
            home.appendingPathComponent("Library/Safari", isDirectory: true).path,
            home.appendingPathComponent("Library/Mail", isDirectory: true).path,
            home.appendingPathComponent("Library/Messages", isDirectory: true).path,
            home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path
        ]

        DispatchQueue.global(qos: .userInitiated).async {
            var sawDeniedAccess = false
            var sawSuccessfulAccess = false

            for path in protectedPaths where self.pathExistsOrIsProtected(path) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/ls")
                process.arguments = [path]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice

                do {
                    try process.run()
                    process.waitUntilExit()
                    if process.terminationStatus == 0 {
                        sawSuccessfulAccess = true
                    } else {
                        sawDeniedAccess = true
                    }
                } catch {
                    continue
                }
            }

            let status: FullDiskAccessStatus
            if sawDeniedAccess {
                status = .denied
            } else if sawSuccessfulAccess {
                status = .granted
            } else {
                status = .unknown
            }
            DispatchQueue.main.async { completion(status) }
        }
    }

    private func pathExistsOrIsProtected(_ path: String) -> Bool {
        var information = stat()
        if lstat(path, &information) == 0 { return true }
        return errno == EACCES || errno == EPERM
    }

    /// On macOS 14 and later, entering another app's sandbox container invokes
    /// App Container Protection. macOS presents its native consent dialog and
    /// records this app as the responsible requester.
    func requestProtectedAppDataAccess() {
        guard #available(macOS 14.0, *) else { return }
        let containers = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers", isDirectory: true)
        let preferredIdentifiers = [
            "com.gingerlabs.Notability",
            "com.apple.iWork.Numbers",
            "chat.rocket",
            "com.apple.Safari",
            "com.apple.mail",
            "com.apple.MobileSMS",
            "com.apple.Notes"
        ]
        var candidates = preferredIdentifiers.map {
            containers.appendingPathComponent($0, isDirectory: true)
                .appendingPathComponent("Data", isDirectory: true)
        }

        if let discovered = try? FileManager.default.contentsOfDirectory(
            at: containers,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            let sorted = discovered
                .filter { $0.lastPathComponent != Bundle.main.bundleIdentifier }
                .sorted {
                    let leftIsApple = $0.lastPathComponent.hasPrefix("com.apple.")
                    let rightIsApple = $1.lastPathComponent.hasPrefix("com.apple.")
                    if leftIsApple != rightIsApple { return !leftIsApple }
                    return $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
                }
            candidates.append(contentsOf: sorted.map {
                $0.appendingPathComponent("Data", isDirectory: true)
            })
        }

        var visited: Set<String> = []
        for dataURL in candidates where visited.insert(dataURL.path).inserted {
            let preferences = dataURL.appendingPathComponent("Library/Preferences", isDirectory: true)
            do {
                let files = try FileManager.default.contentsOfDirectory(
                    at: preferences,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
                if let file = files.first(where: { !$0.hasDirectoryPath }), attemptRead(file) {
                    return
                }
            } catch {
                if isPermissionDenied(error) {
                    // The native TCC request was handled. The subsequent Full
                    // Disk Access guidance remains necessary if access was denied.
                    return
                }
            }

            let metadata = dataURL.deletingLastPathComponent()
                .appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
            if attemptRead(metadata) { return }
        }
    }

    private func attemptRead(_ url: URL) -> Bool {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return errno == EACCES || errno == EPERM }
        var byte: UInt8 = 0
        _ = read(descriptor, &byte, 1)
        close(descriptor)
        return true
    }

    private func isPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        return (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoPermissionError)
            || (nsError.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(nsError.code))
    }

    /// macOS has no public general-purpose API for querying Full Disk Access.
    /// Opening the per-user TCC database is a best-effort probe that also makes
    /// the access attempt originate from the responsible app process.
    func probeStatus() -> FullDiskAccessStatus {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let protectedFiles = [
            home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db"),
            home.appendingPathComponent("Library/Safari/History.db")
        ]

        var sawDeniedAccess = false
        for url in protectedFiles {
            let descriptor = open(url.path, O_RDONLY)
            if descriptor >= 0 {
                close(descriptor)
                return .granted
            }
            if errno == EACCES || errno == EPERM { sawDeniedAccess = true }
        }

        let protectedDirectories = [
            home.appendingPathComponent("Library/Mail", isDirectory: true),
            home.appendingPathComponent("Library/Messages", isDirectory: true)
        ]
        for url in protectedDirectories {
            do {
                _ = try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
                return .granted
            } catch {
                let nsError = error as NSError
                if (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoPermissionError)
                    || (nsError.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(nsError.code)) {
                    sawDeniedAccess = true
                }
            }
        }
        return sawDeniedAccess ? .denied : .unknown
    }

    @discardableResult
    func openSystemSettings() -> Bool {
        showDragGuide()
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        ]
        for value in candidates {
            if let url = URL(string: value), NSWorkspace.shared.open(url) { return true }
        }
        return false
    }

    func revealApplication() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    private func showDragGuide() {
        if dragGuideWindowController == nil {
            dragGuideWindowController = FullDiskAccessDragGuideWindowController(appURL: Bundle.main.bundleURL)
        }
        dragGuideWindowController?.showWindow(nil)
        dragGuideWindowController?.window?.orderFrontRegardless()
    }
}

private final class FullDiskAccessDragGuideWindowController: NSWindowController {
    init(appURL: URL) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 270),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = L10n.text("Add Mac Explorer to Full Disk Access")
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let title = NSTextField(labelWithString: L10n.text("Drag Mac Explorer into the Full Disk Access list"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.alignment = .center

        let explanation = NSTextField(wrappingLabelWithString: L10n.text("Keep this window visible, then drag the Mac Explorer icon below onto the app list in System Settings. Turn on its switch after it appears."))
        explanation.alignment = .center
        explanation.textColor = .secondaryLabelColor
        explanation.maximumNumberOfLines = 3

        let iconView = DraggableApplicationIconView(appURL: appURL)
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let dragCaption = NSTextField(labelWithString: L10n.text("Drag this icon"))
        dragCaption.alignment = .center
        dragCaption.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [title, explanation, iconView, dragCaption])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10

        let contentView = NSView()
        contentView.addSubview(stack)
        panel.contentView = contentView
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -18),
            iconView.widthAnchor.constraint(equalToConstant: 84),
            iconView.heightAnchor.constraint(equalToConstant: 84)
        ])

        super.init(window: panel)
        panel.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class DraggableApplicationIconView: NSImageView, NSDraggingSource {
    private let appURL: URL

    init(appURL: URL) {
        self.appURL = appURL
        super.init(frame: .zero)
        image = NSWorkspace.shared.icon(forFile: appURL.path)
        imageScaling = .scaleProportionallyUpOrDown
        toolTip = L10n.text("Drag this icon")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: appURL as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }
}
