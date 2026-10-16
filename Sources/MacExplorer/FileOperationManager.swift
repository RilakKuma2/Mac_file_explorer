import AppKit
import Darwin

enum FileTransferKind {
    case copy
    case move

    var windowTitle: String {
        switch self {
        case .copy: return L10n.text("Copying items")
        case .move: return L10n.text("Moving items")
        }
    }

    var currentItemPrefix: String {
        switch self {
        case .copy: return L10n.text("Copying")
        case .move: return L10n.text("Moving")
        }
    }
}

enum FileConflictPolicy: Equatable {
    case keepBoth
    case replace
    case skip
}

enum FileTransferError: LocalizedError {
    case cancelled
    case destinationInsideSource
    case folderReplacementWouldDiscardContents

    var errorDescription: String? {
        switch self {
        case .cancelled: return L10n.text("The file operation was cancelled.")
        case .destinationInsideSource:
            return L10n.text("A folder can’t be copied or moved into itself or one of its subfolders.")
        case .folderReplacementWouldDiscardContents:
            return L10n.text("A folder can’t replace another folder because destination-only items would be removed.")
        }
    }
}

struct FileTransferSnapshot {
    let hasStarted: Bool
    let isPrepared: Bool
    let currentItem: String
    let completedBytes: Int64
    let totalBytes: Int64
    let isCancelled: Bool
    let isPaused: Bool

    var fractionCompleted: Double {
        guard isPrepared, totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }
}

struct FileTransferResult {
    let createdURLs: [URL]
    let completedMoves: [(source: URL, destination: URL)]
    let remainingSources: [URL]

    init(
        createdURLs: [URL],
        completedMoves: [(source: URL, destination: URL)],
        remainingSources: [URL] = []
    ) {
        self.createdURLs = createdURLs
        self.completedMoves = completedMoves
        self.remainingSources = remainingSources
    }
}

struct FileTransferPartialFailure: LocalizedError {
    let underlyingError: Error
    let partialResult: FileTransferResult

    var errorDescription: String? { underlyingError.localizedDescription }
}

final class FileTransferTask {
    let id = UUID()
    let kind: FileTransferKind
    let sources: [URL]
    let destinationDirectory: URL
    let conflictPolicy: FileConflictPolicy
    let progress = Progress(totalUnitCount: 1)

    private let manager: FileManager
    private let stateLock = NSCondition()
    private var hasStarted = false
    private var isPaused = false
    private var prepared = false
    private var currentItem = ""
    private var completedBytes: Int64 = 0
    private var totalBytes: Int64 = 1
    private var sourceBaseBytes: Int64 = 0
    private var sourceExpectedBytes: Int64 = 0
    private var sourceReportedBytes: Int64 = 0
    private var copiedByPath: [String: Int64] = [:]

    init(
        kind: FileTransferKind,
        sources: [URL],
        destinationDirectory: URL,
        conflictPolicy: FileConflictPolicy = .keepBoth,
        fileManager: FileManager = .default
    ) {
        self.kind = kind
        self.sources = sources
        self.destinationDirectory = destinationDirectory
        self.conflictPolicy = conflictPolicy
        self.manager = fileManager
        progress.isCancellable = true
        progress.isPausable = true
    }

    func cancel() {
        progress.cancel()
        stateLock.lock()
        stateLock.broadcast()
        stateLock.unlock()
    }

    func pause() {
        stateLock.lock()
        guard !progress.isCancelled, !isPaused else {
            stateLock.unlock()
            return
        }
        isPaused = true
        stateLock.unlock()
        progress.pause()
    }

    func resume() {
        stateLock.lock()
        guard isPaused else {
            stateLock.unlock()
            return
        }
        isPaused = false
        stateLock.broadcast()
        stateLock.unlock()
        progress.resume()
    }

    func snapshot() -> FileTransferSnapshot {
        stateLock.lock()
        defer { stateLock.unlock() }
        return FileTransferSnapshot(
            hasStarted: hasStarted,
            isPrepared: prepared,
            currentItem: currentItem,
            completedBytes: completedBytes,
            totalBytes: totalBytes,
            isCancelled: progress.isCancelled,
            isPaused: isPaused
        )
    }

    func run() throws -> FileTransferResult {
        stateLock.lock()
        hasStarted = true
        stateLock.unlock()
        try waitUntilRunnable()
        for source in sources where isDirectory(source) {
            let sourcePath = source.resolvingSymlinksInPath().standardizedFileURL.path
            let destinationPath = destinationDirectory.resolvingSymlinksInPath().standardizedFileURL.path
            if sourcePath == "/" || destinationPath == sourcePath || destinationPath.hasPrefix(sourcePath + "/") {
                throw FileTransferError.destinationInsideSource
            }
        }
        // Replacing a directory by moving the existing destination aside and then
        // deleting that backup discards every destination-only item. A correct
        // folder merge also needs a per-child rollback journal; the current result
        // model cannot represent that safely. Reject every folder/folder replace
        // before processing any source so a batch cannot be left half-completed.
        if conflictPolicy == .replace {
            for source in sources where isDirectory(source) {
                let destination = destinationDirectory.appendingPathComponent(source.lastPathComponent)
                let sourceAndDestinationMatch = source.standardizedFileURL == destination.standardizedFileURL
                if !sourceAndDestinationMatch, isDirectory(destination) {
                    throw FileTransferError.folderReplacementWouldDiscardContents
                }
            }
        }
        // A move on the same volume is an atomic rename. Recursively calculating a
        // directory's size first can take much longer than the move itself, so cache
        // that decision and skip the unnecessary traversal for those items.
        let usesAtomicMove = sources.map {
            kind == .move && isOnSameVolume($0, destinationDirectory)
        }
        let sourceSizes = try sources.enumerated().map { index, source in
            usesAtomicMove[index] ? 1 : try byteCount(of: source)
        }
        let total = max(1, sourceSizes.reduce(0, +))
        setPrepared(totalBytes: total)

        var results: [URL] = []
        var completedMoves: [(source: URL, destination: URL)] = []
        var remainingSources: [URL] = []
        var processedSourceCount = 0
        do {
            for (index, source) in sources.enumerated() {
                try waitUntilRunnable()
                let expectedBytes = max(1, sourceSizes[index])
                beginSource(source, expectedBytes: expectedBytes)

                if kind == .move,
                   source.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
                       == destinationDirectory.resolvingSymlinksInPath().standardizedFileURL {
                    finishSource(expectedBytes: expectedBytes)
                    results.append(source)
                    processedSourceCount = index + 1
                    continue
                }

                let requestedDestination = destinationDirectory.appendingPathComponent(source.lastPathComponent)
                let sourceAndDestinationMatch = source.standardizedFileURL == requestedDestination.standardizedFileURL
                let destination: URL
                if conflictPolicy == .keepBoth || sourceAndDestinationMatch {
                    destination = FileSystemService.shared.uniqueDestination(
                        named: source.lastPathComponent,
                        in: destinationDirectory,
                        preservingExtension: !isDirectory(source)
                    )
                } else {
                    destination = requestedDestination
                }

                if conflictPolicy == .skip, FileSystemService.entryExists(at: destination) {
                    finishSource(expectedBytes: expectedBytes)
                    remainingSources.append(source)
                    processedSourceCount = index + 1
                    continue
                }

                var backupURL: URL?
                if conflictPolicy == .replace, FileSystemService.entryExists(at: destination) {
                    let backup = FileSystemService.shared.uniqueDestination(
                        named: ".mac-explorer-replaced-\(UUID().uuidString)",
                        in: destinationDirectory,
                        preservingExtension: false
                    )
                    try manager.moveItem(at: destination, to: backup)
                    backupURL = backup
                }

                var copyCompleted = false
                do {
                    if usesAtomicMove[index] {
                        try manager.moveItem(at: source, to: destination)
                    } else {
                        try copyPreservingMetadata(from: source, to: destination)
                        copyCompleted = true
                        if kind == .move { try manager.removeItem(at: source) }
                    }
                    if let backupURL { try? manager.removeItem(at: backupURL) }
                } catch {
                    let failure = error as NSError
                    let destinationAlreadyExists = (failure.domain == NSPOSIXErrorDomain && failure.code == Int(EEXIST))
                        || (failure.domain == NSCocoaErrorDomain && failure.code == CocoaError.fileWriteFileExists.rawValue)
                    // A failed atomic rename creates no output. EEXIST means
                    // another writer owns the destination; never remove it.
                    // Also retain a finished cross-volume copy if source cleanup
                    // fails, since the source may have been only partly removed.
                    if !usesAtomicMove[index], !copyCompleted, !destinationAlreadyExists,
                       FileSystemService.entryExists(at: destination) {
                        try? manager.removeItem(at: destination)
                    }
                    if let backupURL, !FileSystemService.entryExists(at: destination) {
                        try? manager.moveItem(at: backupURL, to: destination)
                    }
                    throw error
                }

                finishSource(expectedBytes: expectedBytes)
                results.append(destination)
                if kind == .move {
                    completedMoves.append((source: source, destination: destination))
                }
                processedSourceCount = index + 1
            }
        } catch {
            remainingSources.append(contentsOf: sources.dropFirst(processedSourceCount))
            let partialResult = FileTransferResult(
                createdURLs: results,
                completedMoves: completedMoves,
                remainingSources: remainingSources
            )
            guard !results.isEmpty || !completedMoves.isEmpty else { throw error }
            throw FileTransferPartialFailure(underlyingError: error, partialResult: partialResult)
        }
        return FileTransferResult(
            createdURLs: results,
            completedMoves: completedMoves,
            remainingSources: remainingSources
        )
    }

    fileprivate func reportCopyProgress(state: copyfile_state_t?, sourcePath: String?) -> Int32 {
        guard waitForCallback() else { return Int32(COPYFILE_QUIT) }
        guard let state, let sourcePath else { return Int32(COPYFILE_CONTINUE) }
        var copied: off_t = 0
        guard copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied) == 0 else {
            return Int32(COPYFILE_CONTINUE)
        }

        stateLock.lock()
        let value = max(0, Int64(copied))
        let previous = copiedByPath[sourcePath] ?? 0
        if value > previous {
            sourceReportedBytes += value - previous
            copiedByPath[sourcePath] = value
            completedBytes = min(totalBytes, sourceBaseBytes + min(sourceExpectedBytes, sourceReportedBytes))
            progress.completedUnitCount = completedBytes
        }
        stateLock.unlock()
        return waitForCallback() ? Int32(COPYFILE_CONTINUE) : Int32(COPYFILE_QUIT)
    }

    private func copyPreservingMetadata(from source: URL, to destination: URL) throws {
        guard let state = copyfile_state_alloc() else { throw POSIXError(.ENOMEM) }
        defer { copyfile_state_free(state) }

        let callbackPointer = unsafeBitCast(fileTransferCopyCallback, to: UnsafeRawPointer.self)
        let contextPointer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), callbackPointer) == 0,
              copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), contextPointer) == 0 else {
            throw POSIXError(.EINVAL)
        }

        var flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_EXCL | COPYFILE_NOFOLLOW)
        if isDirectory(source) { flags |= copyfile_flags_t(COPYFILE_RECURSIVE) }
        errno = 0
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                copyfile(sourcePath, destinationPath, state, flags)
            }
        }
        guard result == 0 else {
            if progress.isCancelled || errno == ECANCELED { throw FileTransferError.cancelled }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func byteCount(of source: URL) throws -> Int64 {
        try waitUntilRunnable()
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let values = try source.resourceValues(forKeys: keys)
        if values.isSymbolicLink == true { return 1 }
        if values.isDirectory != true { return max(1, Int64(values.fileSize ?? 0)) }

        guard let enumerator = manager.enumerator(
            at: source,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 1 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            try waitUntilRunnable()
            let childValues = try? url.resourceValues(forKeys: keys)
            if childValues?.isRegularFile == true {
                total += Int64(childValues?.fileSize ?? 0)
            }
        }
        return max(1, total)
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func isOnSameVolume(_ source: URL, _ destination: URL) -> Bool {
        let sourceIdentifier = try? source.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        let destinationIdentifier = try? destination.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        guard let sourceIdentifier, let destinationIdentifier else { return false }
        return String(describing: sourceIdentifier) == String(describing: destinationIdentifier)
    }

    private func setPrepared(totalBytes: Int64) {
        stateLock.lock()
        prepared = true
        self.totalBytes = totalBytes
        progress.totalUnitCount = totalBytes
        progress.completedUnitCount = 0
        stateLock.unlock()
    }

    private func beginSource(_ source: URL, expectedBytes: Int64) {
        stateLock.lock()
        currentItem = source.lastPathComponent
        sourceBaseBytes = completedBytes
        sourceExpectedBytes = expectedBytes
        sourceReportedBytes = 0
        copiedByPath.removeAll(keepingCapacity: true)
        stateLock.unlock()
    }

    private func finishSource(expectedBytes: Int64) {
        stateLock.lock()
        completedBytes = min(totalBytes, sourceBaseBytes + expectedBytes)
        progress.completedUnitCount = completedBytes
        stateLock.unlock()
    }

    private func waitUntilRunnable() throws {
        guard waitForCallback() else { throw FileTransferError.cancelled }
    }

    fileprivate func waitForCallback() -> Bool {
        stateLock.lock()
        while isPaused && !progress.isCancelled {
            stateLock.wait()
        }
        let canContinue = !progress.isCancelled
        stateLock.unlock()
        return canContinue
    }
}

private let fileTransferCopyCallback: copyfile_callback_t = { what, stage, state, source, _, context in
    guard let context else { return Int32(COPYFILE_CONTINUE) }
    let task = Unmanaged<FileTransferTask>.fromOpaque(context).takeUnretainedValue()
    if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS {
        return task.reportCopyProgress(
            state: state,
            sourcePath: source.map { String(cString: $0) }
        )
    }
    return task.waitForCallback() ? Int32(COPYFILE_CONTINUE) : Int32(COPYFILE_QUIT)
}

final class FileOperationProgressWindowController: NSWindowController {
    private let task: FileTransferTask
    private weak var parentWindow: NSWindow?
    private let titleLabel = NSTextField(labelWithString: "")
    private let itemLabel = NSTextField(labelWithString: "")
    private let destinationLabel = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let byteLabel = NSTextField(labelWithString: "")
    private let pauseButton = NSButton()
    private let cancelButton = NSButton()
    private var timer: Timer?
    private var isShown = false

    init(task: FileTransferTask, parentWindow: NSWindow?) {
        self.task = task
        self.parentWindow = parentWindow
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 184),
            styleMask: [.titled, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = task.kind.windowTitle
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        super.init(window: panel)
        panel.contentView = makeContentView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showProgress() {
        guard !isShown else { return }
        isShown = true
        guard let window else { return }
        if let parentWindow {
            parentWindow.addChildWindow(window, ordered: .above)
            let parentFrame = parentWindow.frame
            let origin = NSPoint(
                x: parentFrame.midX - window.frame.width / 2,
                y: parentFrame.midY - window.frame.height / 2
            )
            window.setFrameOrigin(origin)
        } else {
            window.center()
        }
        // A background copy should never steal the key window while the user
        // is renaming, searching, or even working in another application.
        // The controls can still become key when the user explicitly clicks
        // the utility panel.
        window.orderFront(nil)
        refreshProgress()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.refreshProgress()
        }
    }

    func finish() {
        guard isShown else { return }
        timer?.invalidate()
        timer = nil
        let shouldRestoreParentKey = window?.isKeyWindow == true && NSApp.isActive
        if let window, let parentWindow {
            parentWindow.removeChildWindow(window)
        }
        close()
        if shouldRestoreParentKey {
            parentWindow?.makeKeyAndOrderFront(nil)
        }
    }

    private func makeContentView() -> NSView {
        let root = NSView()
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 18, right: 22)
        root.addSubview(stack)

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.stringValue = task.kind.windowTitle
        stack.addArrangedSubview(titleLabel)

        itemLabel.lineBreakMode = .byTruncatingMiddle
        itemLabel.textColor = .labelColor
        stack.addArrangedSubview(itemLabel)

        destinationLabel.lineBreakMode = .byTruncatingMiddle
        destinationLabel.textColor = .secondaryLabelColor
        destinationLabel.font = .systemFont(ofSize: 11)
        destinationLabel.stringValue = L10n.text("To") + ": " + task.destinationDirectory.path
        stack.addArrangedSubview(destinationLabel)

        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = true
        progressIndicator.usesThreadedAnimation = true
        progressIndicator.startAnimation(nil)
        stack.addArrangedSubview(progressIndicator)

        let bottom = NSStackView()
        bottom.orientation = .horizontal
        bottom.alignment = .centerY
        bottom.spacing = 10
        byteLabel.textColor = .secondaryLabelColor
        byteLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        bottom.addArrangedSubview(byteLabel)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bottom.addArrangedSubview(spacer)
        pauseButton.title = L10n.text("Pause")
        pauseButton.bezelStyle = .rounded
        pauseButton.target = self
        pauseButton.action = #selector(togglePause(_:))
        bottom.addArrangedSubview(pauseButton)
        cancelButton.title = L10n.text("Cancel")
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelTransfer(_:))
        bottom.addArrangedSubview(cancelButton)
        stack.addArrangedSubview(bottom)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            titleLabel.widthAnchor.constraint(equalToConstant: 456),
            itemLabel.widthAnchor.constraint(equalToConstant: 456),
            destinationLabel.widthAnchor.constraint(equalToConstant: 456),
            progressIndicator.widthAnchor.constraint(equalToConstant: 456),
            bottom.widthAnchor.constraint(equalToConstant: 456)
        ])
        return root
    }

    private func refreshProgress() {
        let snapshot = task.snapshot()
        if snapshot.isCancelled {
            itemLabel.stringValue = L10n.text("Cancelling") + "…"
            cancelButton.isEnabled = false
            pauseButton.isEnabled = false
        } else if snapshot.isPaused {
            itemLabel.stringValue = L10n.text("Paused")
            pauseButton.title = L10n.text("Resume")
        } else if !snapshot.hasStarted {
            itemLabel.stringValue = L10n.text("Queued")
            pauseButton.title = L10n.text("Pause")
        } else if snapshot.currentItem.isEmpty {
            itemLabel.stringValue = L10n.text("Calculating size") + "…"
            pauseButton.title = L10n.text("Pause")
        } else {
            itemLabel.stringValue = task.kind.currentItemPrefix + ": " + snapshot.currentItem
            pauseButton.title = L10n.text("Pause")
        }

        guard snapshot.isPrepared else {
            if !progressIndicator.isIndeterminate {
                progressIndicator.isIndeterminate = true
                progressIndicator.startAnimation(nil)
            }
            byteLabel.stringValue = L10n.text("Preparing") + "…"
            return
        }

        if progressIndicator.isIndeterminate {
            progressIndicator.stopAnimation(nil)
            progressIndicator.isIndeterminate = false
            progressIndicator.minValue = 0
            progressIndicator.maxValue = 1
        }
        progressIndicator.doubleValue = snapshot.fractionCompleted
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let completed = formatter.string(fromByteCount: snapshot.completedBytes)
        let total = formatter.string(fromByteCount: snapshot.totalBytes)
        byteLabel.stringValue = "\(Int(snapshot.fractionCompleted * 100))% · \(completed) / \(total)"
    }

    @objc private func cancelTransfer(_ sender: Any?) {
        task.cancel()
        cancelButton.isEnabled = false
        refreshProgress()
    }

    @objc private func togglePause(_ sender: Any?) {
        if task.snapshot().isPaused { task.resume() }
        else { task.pause() }
        refreshProgress()
    }
}

final class FileOperationManager {
    static let shared = FileOperationManager()

    private var activeControllers: [UUID: FileOperationProgressWindowController] = [:]
    private var pendingMutations = 0
    var hasActiveOperations: Bool { !activeControllers.isEmpty || pendingMutations > 0 }
    private let transferQueue = DispatchQueue(label: "app.macexplorer.file-transfers", qos: .userInitiated)

    private init() {}

    /// Runs non-copy mutations (Trash, Undo, Redo) in the same lane as file
    /// transfers. This prevents a queued undo from racing an active paste over
    /// the same paths while keeping all filesystem work off AppKit's thread.
    func performSerializedMutation<Value>(
        _ operation: @escaping () throws -> Value,
        completion: @escaping (Result<Value, Error>) -> Void
    ) {
        pendingMutations += 1
        transferQueue.async {
            let result = Result { try operation() }
            DispatchQueue.main.async {
                self.pendingMutations -= 1
                completion(result)
            }
        }
    }

    func startTransfer(
        kind: FileTransferKind,
        sources: [URL],
        destination: URL,
        conflictPolicy: FileConflictPolicy = .keepBoth,
        parentWindow: NSWindow?,
        completion: @escaping (Result<FileTransferResult, Error>) -> Void
    ) {
        guard !sources.isEmpty else { return }
        let task = FileTransferTask(
            kind: kind,
            sources: sources,
            destinationDirectory: destination,
            conflictPolicy: conflictPolicy
        )
        let controller = FileOperationProgressWindowController(task: task, parentWindow: parentWindow)
        activeControllers[task.id] = controller

        // Fast file operations should feel instantaneous. Showing a panel for every
        // tiny copy adds window/layout work and previously imposed a fixed delay even
        // after the filesystem operation had completed.
        let progressDelay = 0.25
        let showProgressWorkItem = DispatchWorkItem { [weak self, weak controller] in
            guard let self, let controller,
                  self.activeControllers[task.id] === controller else { return }
            controller.showProgress()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + progressDelay, execute: showProgressWorkItem)

        // Serializing transfers prevents several large copies from seeking the
        // same disk at once. Queued tasks remain cancellable through their
        // progress window and tiny operations still avoid showing that window.
        transferQueue.async { [weak self] in
            let result = Result { try task.run() }
            DispatchQueue.main.async {
                guard let self else { return }
                showProgressWorkItem.cancel()
                controller.finish()
                self.activeControllers.removeValue(forKey: task.id)
                completion(result)
            }
        }
    }
}
