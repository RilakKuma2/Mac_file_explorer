import AppKit
import Security

// MARK: - Release model

struct AppVersion: Comparable, CustomStringConvertible {
    let components: [Int]

    /// Accepts `0.1`, `v0.1.2`, `V1.2.3.4`. Trailing zero components are not
    /// significant, so `0.1` and `0.1.0` are the same version.
    init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var values: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 9, part.allSatisfy(\.isASCII),
                  part.allSatisfy(\.isNumber), let value = Int(part) else { return nil }
            values.append(value)
        }
        while values.count > 1, values.last == 0 { values.removeLast() }
        components = values
    }

    var description: String {
        (components + Array(repeating: 0, count: max(0, 2 - components.count)))
            .map(String.init).joined(separator: ".")
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let body: String?
    let draft: Bool?
    let prerelease: Bool?
    let htmlURL: String?
    let assets: [Asset]?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body, draft, prerelease, assets
        case htmlURL = "html_url"
    }
}

struct UpdateOffer: Equatable {
    let version: AppVersion
    let downloadURL: URL
    let assetName: String
    let releasePage: URL
}

enum UpdateAvailability: Equatable {
    case current(latest: AppVersion)
    case available(UpdateOffer)
    /// A newer release exists but has no installable image for this Mac yet.
    case missingAsset(latest: AppVersion, releasePage: URL)
}

enum UpdateError: LocalizedError {
    case invalidRelease(String)
    case notInstallable(String)

    var errorDescription: String? {
        switch self {
        case .invalidRelease(let detail), .notInstallable(let detail): return detail
        }
    }
}

/// Reads the public GitHub release list. Everything here is pure so it can be
/// tested without the network.
enum UpdateCatalog {
    static let repository = "RilakKuma2/Mac_file_explorer"
    static var releasePagePrefix: String { "https://github.com/\(repository)/releases/" }
    static var downloadPrefix: String { "https://github.com/\(repository)/releases/download/" }

    static var machineArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    static func availability(
        of release: GitHubRelease,
        current: AppVersion,
        architecture: String = machineArchitecture
    ) throws -> UpdateAvailability {
        guard let latest = AppVersion(release.tagName) else {
            throw UpdateError.invalidRelease("Invalid release version: \(release.tagName)")
        }
        guard latest > current else { return .current(latest: latest) }
        let page = release.htmlURL.flatMap { $0.hasPrefix(releasePagePrefix) ? URL(string: $0) : nil }
            ?? URL(string: releasePagePrefix + "latest")!
        let suffix = "-\(architecture).dmg"
        guard let asset = (release.assets ?? []).first(where: {
            $0.name.hasPrefix("Mac-Explorer-") && $0.name.hasSuffix(suffix)
        }) else {
            return .missingAsset(latest: latest, releasePage: page)
        }
        // Never follow a download location outside this project's releases.
        guard asset.browserDownloadURL.hasPrefix(downloadPrefix),
              !asset.name.contains("/"),
              let url = URL(string: asset.browserDownloadURL) else {
            throw UpdateError.invalidRelease("Unexpected release download URL.")
        }
        return .available(UpdateOffer(version: latest, downloadURL: url, assetName: asset.name, releasePage: page))
    }

    private static let changeHeadings: Set<String> = [
        "수정사항", "변경사항", "개선및수정", "changes", "whatsnew", "what'snew"
    ]

    /// Only the "changes" section of a release body, without installation
    /// instructions, other headings or Markdown markup.
    static func changes(fromReleaseBody body: String?) -> String {
        guard let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        var collected: [String] = []
        var sectionLevel = 0
        var fenced = false
        for line in body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { fenced.toggle(); continue }
            if !fenced, let heading = heading(in: line) {
                if sectionLevel == 0 {
                    let title = heading.title.lowercased().filter { !$0.isWhitespace }
                    if changeHeadings.contains(title) { sectionLevel = heading.level }
                    continue
                }
                if heading.level <= sectionLevel { break }
                continue
            }
            if sectionLevel != 0 { collected.append(line) }
        }
        if sectionLevel == 0 {
            // Notes written without headings: take the first bullet list.
            guard heading(inAnyLineOf: body) == false else { return "" }
            for line in body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
                if isBullet(line) { collected.append(line) } else if !collected.isEmpty { break }
            }
        }
        return collected.map(plainText(fromMarkdownLine:))
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Notes for every public version newer than the installed one, newest first.
    static func pendingNotes(
        from releases: [GitHubRelease],
        current: AppVersion,
        latest: AppVersion,
        versionHeading: (AppVersion) -> String,
        emptyText: String
    ) -> String {
        var notes: [(AppVersion, String)] = []
        for release in releases {
            if release.draft == true || release.prerelease == true { continue }
            guard let version = AppVersion(release.tagName),
                  version > current, version <= latest,
                  !notes.contains(where: { $0.0 == version }) else { continue }
            let text = changes(fromReleaseBody: release.body)
            notes.append((version, text.isEmpty ? emptyText : text))
        }
        return notes.sorted { $0.0 > $1.0 }
            .map { versionHeading($0.0) + "\n" + $0.1 }
            .joined(separator: "\n\n")
    }

    private static func heading(in line: String) -> (level: Int, title: String)? {
        let leading = line.prefix { $0 == " " }
        guard leading.count <= 3 else { return nil }
        let rest = line.dropFirst(leading.count)
        let hashes = rest.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        var title = rest.dropFirst(hashes.count).trimmingCharacters(in: .whitespaces)
        while title.hasSuffix("#") { title.removeLast() }
        return (hashes.count, title.trimmingCharacters(in: .whitespaces))
    }

    private static func heading(inAnyLineOf body: String) -> Bool {
        body.components(separatedBy: .newlines).contains { heading(in: $0) != nil }
    }

    private static func isBullet(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ")
    }

    private static func plainText(fromMarkdownLine line: String) -> String {
        var text = line
        // [label](link) -> label
        while let open = text.range(of: "["),
              let middle = text.range(of: "](", range: open.upperBound..<text.endIndex),
              let close = text.range(of: ")", range: middle.upperBound..<text.endIndex) {
            text.replaceSubrange(open.lowerBound..<close.upperBound, with: text[open.upperBound..<middle.lowerBound])
        }
        for mark in ["**", "__", "`"] { text = text.replacingOccurrences(of: mark, with: "") }
        if isBullet(text) {
            let indent = text.prefix { $0 == " " || $0 == "\t" }
            text = indent + "• " + text.trimmingCharacters(in: .whitespaces).dropFirst(2)
        }
        return text
    }
}

// MARK: - Installation

enum UpdateInstaller {
    /// Refuses a downloaded bundle that is not this app, is not newer, or was
    /// not signed by the same identity as the running copy.
    static func validate(candidate: URL, replacing installed: URL, newerThan current: AppVersion) throws {
        guard let bundle = Bundle(url: candidate),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              let versionText = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let version = AppVersion(versionText),
              let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw UpdateError.notInstallable(L10n.text("The downloaded update is not a valid copy of Mac Explorer."))
        }
        guard version > current else {
            throw UpdateError.notInstallable(L10n.text("The downloaded update is not newer than this version."))
        }
        try validateSignature(of: candidate, matching: installed)
    }

    static func validateSignature(of candidate: URL, matching installed: URL) throws {
        let mismatch = UpdateError.notInstallable(
            L10n.text("The downloaded update is not signed by the same developer as this copy, so it was not installed.")
        )
        var installedCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(installed as CFURL, [], &installedCode) == errSecSuccess,
              let installedCode else { throw mismatch }

        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        let status = SecCodeCopySigningInformation(installedCode, flags, &information)
        let details = information as? [String: Any]
        let signatureFlags = (details?[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let isAdHoc = signatureFlags & SecCodeSignatureFlags.adhoc.rawValue != 0
        if status != errSecSuccess || details?[kSecCodeInfoIdentifier as String] == nil || isAdHoc {
            // A development build has no stable identity to compare against;
            // the identifier and version checks above are all that apply.
            return
        }

        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(installedCode, [], &requirement) == errSecSuccess,
              let requirement else { throw mismatch }
        var candidateCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(candidate as CFURL, [], &candidateCode) == errSecSuccess,
              let candidateCode else { throw mismatch }
        let checks = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidity(candidateCode, checks, requirement) == errSecSuccess else {
            throw mismatch
        }
    }

    /// Runs after this process exits: swaps the bundle (restoring the old one if
    /// the swap fails), unmounts the image and reopens the app.
    static let applyScript = """
        #!/bin/sh
        BUNDLE="$1"
        SOURCE="$2"
        MNT="$3"
        STAGING="$4"
        APP_PID="$5"
        i=0
        while kill -0 "$APP_PID" 2>/dev/null && [ "$i" -lt 480 ]; do
          sleep 0.25
          i=$((i+1))
        done
        if kill -0 "$APP_PID" 2>/dev/null; then
          /usr/bin/hdiutil detach "$MNT" -force >/dev/null 2>&1
          rm -rf "$STAGING"
          exit 1
        fi
        NEW="$BUNDLE.update-new"
        OLD="$BUNDLE.update-old"
        rm -rf "$NEW" "$OLD"
        if /usr/bin/ditto "$SOURCE" "$NEW" && mv "$BUNDLE" "$OLD"; then
          if mv "$NEW" "$BUNDLE"; then
            rm -rf "$OLD"
          else
            mv "$OLD" "$BUNDLE"
          fi
        fi
        rm -rf "$NEW"
        /usr/bin/xattr -dr com.apple.quarantine "$BUNDLE" 2>/dev/null
        /usr/bin/hdiutil detach "$MNT" -force >/dev/null 2>&1
        rm -rf "$STAGING"
        /usr/bin/open "$BUNDLE"
        """

    static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.notInstallable(
                String(data: message, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? "\(tool) failed"
            )
        }
    }
}

private final class UpdateDownload: NSObject, URLSessionDownloadDelegate {
    private let destination: URL
    private let onProgress: (Double?) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var moveError: Error?

    init(destination: URL, onProgress: @escaping (Double?) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    func start(_ request: URLRequest) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
            self.session = session
            session.downloadTask(with: request).resume()
        }
    }

    func cancel() { session?.invalidateAndCancel() }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let response = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            moveError = URLError(.badServerResponse)
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch { moveError = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        let continuation = self.continuation
        self.continuation = nil
        if let failure = error ?? moveError { continuation?.resume(throwing: failure) }
        else { continuation?.resume() }
    }
}

// MARK: - Updater

/// Checks this project's public GitHub releases, and on the user's confirmation
/// downloads the disk image, replaces the installed bundle and reopens it.
final class AppUpdater: NSObject, NSMenuItemValidation {
    private static let automaticChecksKey = "ExplorerAutomaticUpdateChecks"
    private static let lastCheckKey = "ExplorerLastUpdateCheck"
    private static let skippedVersionKey = "ExplorerSkippedUpdateVersion"
    private static let checkInterval: TimeInterval = 86_400

    private let defaults: UserDefaults
    private var isChecking = false
    private var scheduleTimer: Timer?
    private var activeDownload: UpdateDownload?
    private var progressWindow: NSWindow?
    private var progressIndicator: NSProgressIndicator?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
    }

    deinit { scheduleTimer?.invalidate() }

    static var currentVersion: AppVersion {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            .flatMap(AppVersion.init) ?? AppVersion("0")!
    }

    private var isInstalledApp: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    private var hasActiveOperations: Bool {
        FileOperationManager.shared.hasActiveOperations || ArchiveOperationManager.shared.hasActiveOperations
    }

    var automaticallyChecksForUpdates: Bool {
        get {
            if let own = defaults.object(forKey: Self.automaticChecksKey) as? Bool { return own }
            // Honour the choice made with the previous (Sparkle) updater.
            return defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool ?? true
        }
        set { defaults.set(newValue, forKey: Self.automaticChecksKey) }
    }

    func start() {
        // `swift run` and unit tests are not installable app bundles.
        guard isInstalledApp else { return }
        let timer = Timer(timeInterval: 3_600, repeats: true) { [weak self] _ in self?.checkIfDue() }
        RunLoop.main.add(timer, forMode: .common)
        scheduleTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.checkIfDue() }
    }

    private func checkIfDue() {
        guard automaticallyChecksForUpdates else { return }
        let last = defaults.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= Self.checkInterval else { return }
        check(manual: false)
    }

    @objc func checkForUpdates(_ sender: Any?) { check(manual: true) }

    @objc func toggleAutomaticChecks(_ sender: Any?) {
        automaticallyChecksForUpdates.toggle()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleAutomaticChecks(_:)) {
            menuItem.state = automaticallyChecksForUpdates ? .on : .off
        }
        if menuItem.action == #selector(checkForUpdates(_:)) { return !isChecking }
        return true
    }

    private func check(manual: Bool) {
        guard !isChecking else { return }
        isChecking = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isChecking = false; self.closeProgress() }
            do {
                try await self.performCheck(manual: manual)
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch let error as UpdateError {
                self.notify(L10n.text("The update could not be installed."), detail: error.localizedDescription)
            } catch {
                // Automatic checks stay quiet offline; a manual check always reports.
                if manual || self.activeDownload != nil {
                    self.notify(L10n.text("Could not check for updates. Check your connection."),
                                detail: error.localizedDescription)
                }
            }
            self.activeDownload = nil
        }
    }

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("MacExplorer/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        return request
    }

    @MainActor
    private func performCheck(manual: Bool) async throws {
        guard isInstalledApp else {
            if manual {
                notify(L10n.text("This is a development build."),
                       detail: L10n.text("Updates can be installed from a released copy of the app."))
            }
            return
        }
        let current = Self.currentVersion
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let api = "https://api.github.com/repos/\(UpdateCatalog.repository)/releases"
        let (data, response) = try await session.data(for: request(URL(string: api + "/latest")!))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 {
            if manual { notify(L10n.text("No public release is available yet."), detail: nil) }
            return
        }
        guard (200..<300).contains(status) else { throw URLError(.badServerResponse) }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        defaults.set(Date(), forKey: Self.lastCheckKey)

        switch try UpdateCatalog.availability(of: release, current: current) {
        case .current:
            if manual {
                notify(String(format: L10n.text("You are up to date (v%@)."), current.description), detail: nil)
            }
        case let .missingAsset(latest, page):
            if manual {
                let alert = NSAlert()
                alert.messageText = String(format: L10n.text("Version %@ is available (this is v%@)."),
                                           "v" + latest.description, current.description)
                alert.informativeText = L10n.text("An installer for this Mac is not available yet.")
                alert.addButton(withTitle: L10n.text("Open Release Page"))
                alert.addButton(withTitle: L10n.text("Cancel"))
                if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(page) }
            }
        case let .available(offer):
            if !manual, defaults.string(forKey: Self.skippedVersionKey) == offer.version.description { return }
            var releases = [release]
            if let (listData, listResponse) = try? await session.data(
                for: request(URL(string: api + "?per_page=100")!)
            ), (listResponse as? HTTPURLResponse)?.statusCode == 200,
               let list = try? JSONDecoder().decode([GitHubRelease].self, from: listData) {
                releases += list
            }
            let notes = UpdateCatalog.pendingNotes(
                from: releases, current: current, latest: offer.version,
                versionHeading: { "v\($0) " + L10n.text("Changes") },
                emptyText: L10n.text("No change description is available.")
            )
            try await offerUpdate(offer, current: current, notes: notes)
        }
    }

    @MainActor
    private func offerUpdate(_ offer: UpdateOffer, current: AppVersion, notes: String) async throws {
        let alert = NSAlert()
        alert.messageText = String(format: L10n.text("Version %@ is available (this is v%@)."),
                                   "v" + offer.version.description, current.description)
        alert.informativeText = L10n.text("Update now? The app reopens by itself afterwards.")
        alert.accessoryView = notesView(notes)
        alert.addButton(withTitle: L10n.text("Update"))
        alert.addButton(withTitle: L10n.text("Later"))
        alert.addButton(withTitle: L10n.text("Skip This Version"))
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: break
        case .alertThirdButtonReturn:
            defaults.set(offer.version.description, forKey: Self.skippedVersionKey)
            return
        default: return
        }
        defaults.removeObject(forKey: Self.skippedVersionKey)

        let bundle = Bundle.main.bundleURL.standardizedFileURL
        let parent = bundle.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path),
              FileManager.default.isWritableFile(atPath: bundle.path),
              !bundle.path.contains("/AppTranslocation/") else {
            let manual = NSAlert()
            manual.messageText = L10n.text("This copy cannot replace itself.")
            manual.informativeText = L10n.text("Move Mac Explorer to the Applications folder, or download the new version from the release page.")
            manual.addButton(withTitle: L10n.text("Open Release Page"))
            manual.addButton(withTitle: L10n.text("Cancel"))
            if manual.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(offer.releasePage) }
            return
        }

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let staging = caches.appendingPathComponent("app.macexplorer.filemanager/Update", isDirectory: true)
        let mountPoint = staging.appendingPathComponent("mnt", isDirectory: true)
        if FileManager.default.fileExists(atPath: mountPoint.path) {
            try? UpdateInstaller.run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])
        }
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        var keepStaging = false
        defer { if !keepStaging { try? FileManager.default.removeItem(at: staging) } }

        let image = staging.appendingPathComponent(offer.assetName)
        showProgress(String(format: L10n.text("Downloading version %@…"), offer.version.description))
        let download = UpdateDownload(destination: image) { [weak self] fraction in
            guard let indicator = self?.progressIndicator else { return }
            if let fraction {
                indicator.isIndeterminate = false
                indicator.doubleValue = fraction
            }
        }
        activeDownload = download
        var downloadRequest = URLRequest(url: offer.downloadURL, timeoutInterval: 900)
        downloadRequest.setValue("MacExplorer/\(current)", forHTTPHeaderField: "User-Agent")
        try await download.start(downloadRequest)
        activeDownload = nil
        progressIndicator?.isIndeterminate = true
        progressIndicator?.startAnimation(nil)

        let source = try await Task.detached(priority: .userInitiated) { () -> URL in
            try UpdateInstaller.run("/usr/bin/hdiutil", [
                "attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mountPoint.path, image.path
            ])
            do {
                let apps = try FileManager.default.contentsOfDirectory(
                    at: mountPoint, includingPropertiesForKeys: nil
                ).filter { $0.pathExtension == "app" }
                guard let app = apps.first(where: {
                    Bundle(url: $0)?.bundleIdentifier == Bundle.main.bundleIdentifier
                }) else {
                    throw UpdateError.notInstallable(
                        L10n.text("The downloaded update is not a valid copy of Mac Explorer.")
                    )
                }
                try UpdateInstaller.validate(candidate: app, replacing: bundle, newerThan: current)
                return app
            } catch {
                try? UpdateInstaller.run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])
                throw error
            }
        }.value

        // A restart must not interrupt a copy, move, archive or queued undo.
        if hasActiveOperations {
            setProgressText(L10n.text("Waiting for file operations to finish…"))
            while hasActiveOperations { try await Task.sleep(nanoseconds: 500_000_000) }
        }

        let script = staging.appendingPathComponent("apply.sh")
        try UpdateInstaller.applyScript.write(to: script, atomically: true, encoding: .utf8)
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            script.path, bundle.path, source.path, mountPoint.path, staging.path,
            String(ProcessInfo.processInfo.processIdentifier)
        ]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        do { try helper.run() } catch {
            try? UpdateInstaller.run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])
            throw error
        }
        keepStaging = true
        closeProgress()
        NSApp.terminate(nil)
    }

    // MARK: Interface

    private func notesView(_ notes: String) -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 190))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.contentView.bounds)
        text.isEditable = false
        text.isSelectable = true
        text.autoresizingMask = [.width]
        text.textContainerInset = NSSize(width: 6, height: 8)
        text.font = .systemFont(ofSize: 12)
        text.string = notes
        scroll.documentView = text
        return scroll
    }

    private func notify(_ message: String, detail: String?) {
        let alert = NSAlert()
        alert.messageText = message
        if let detail { alert.informativeText = detail }
        alert.addButton(withTitle: L10n.text("OK"))
        alert.runModal()
    }

    private func showProgress(_ title: String) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 96),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Mac Explorer"
        panel.isReleasedWhenClosed = false
        let label = NSTextField(labelWithString: title)
        label.identifier = NSUserInterfaceItemIdentifier("updateProgressLabel")
        label.frame = NSRect(x: 20, y: 58, width: 340, height: 18)
        let indicator = NSProgressIndicator(frame: NSRect(x: 20, y: 34, width: 340, height: 16))
        indicator.minValue = 0
        indicator.maxValue = 1
        indicator.isIndeterminate = true
        indicator.startAnimation(nil)
        let cancel = NSButton(title: L10n.text("Cancel"), target: self, action: #selector(cancelDownload(_:)))
        cancel.frame = NSRect(x: 270, y: 4, width: 96, height: 28)
        cancel.identifier = NSUserInterfaceItemIdentifier("updateProgressCancel")
        panel.contentView?.addSubview(label)
        panel.contentView?.addSubview(indicator)
        panel.contentView?.addSubview(cancel)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        progressWindow = panel
        progressIndicator = indicator
    }

    private func setProgressText(_ text: String) {
        for case let label as NSTextField in progressWindow?.contentView?.subviews ?? []
        where label.identifier?.rawValue == "updateProgressLabel" {
            label.stringValue = text
        }
    }

    private func closeProgress() {
        progressWindow?.orderOut(nil)
        progressWindow = nil
        progressIndicator = nil
    }

    @objc private func cancelDownload(_ sender: Any?) {
        // Only the download is cancellable; mounting and swapping are brief.
        activeDownload?.cancel()
    }
}
