import AppKit

enum ArchiveOperationError: LocalizedError {
    case failed(status: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case let .failed(status, message):
            let fallback = String(format: L10n.text("Archive tool exited with status %d."), status)
            return message.isEmpty ? fallback : message
        }
    }
}

private struct ArchiveInputSnapshot {
    let totalBytes: Int64
    let fileSizes: [String: Int64]

    static func measure(_ sources: [URL]) -> ArchiveInputSnapshot {
        guard let root = sources.first?.deletingLastPathComponent().standardizedFileURL else {
            return ArchiveInputSnapshot(totalBytes: 0, fileSizes: [:])
        }
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]
        var sizes: [String: Int64] = [:]
        var totalBytes: Int64 = 0
        var collectsPaths = true
        let maximumTrackedPaths = 100_000

        func relativePath(_ url: URL) -> String {
            let path = url.standardizedFileURL.path
            let prefix = root.path == "/" ? "/" : root.path + "/"
            return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : url.lastPathComponent
        }

        func addFile(_ url: URL) {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else { return }
            let size = Int64(values.fileSize ?? 0)
            totalBytes += size
            if collectsPaths, sizes.count < maximumTrackedPaths {
                sizes[relativePath(url)] = size
            } else if collectsPaths {
                // Very large trees must not turn progress bookkeeping into a
                // second in-memory directory index. Output-size estimation is
                // used once this conservative cap is reached.
                collectsPaths = false
                sizes.removeAll(keepingCapacity: false)
            }
        }

        for source in sources {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: source.path, isDirectory: &isDirectory) else { continue }
            if !isDirectory.boolValue {
                addFile(source)
                continue
            }
            guard let enumerator = manager.enumerator(
                at: source,
                includingPropertiesForKeys: Array(keys),
                options: [],
                errorHandler: { _, _ in true }
            ) else { continue }
            for case let child as URL in enumerator { addFile(child) }
        }
        return ArchiveInputSnapshot(totalBytes: totalBytes, fileSizes: sizes)
    }
}

private final class ArchiveOperationProgressWindowController: NSWindowController {
    let operationID: UUID
    var onCancel: (() -> Void)?

    private weak var parentWindow: NSWindow?
    private let destination: URL
    private let format: ArchiveCreationFormat
    private let progressIndicator = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let cancelButton = NSButton()
    private var timer: Timer?
    private let startedAt = Date()
    private var totalBytes: Int64 = 0
    private var completedBytes: Int64 = 0
    private var reportedFraction: Double = 0
    private var allowsOutputEstimate = false

    init(operationID: UUID, destination: URL, format: ArchiveCreationFormat, parentWindow: NSWindow?) {
        self.operationID = operationID
        self.destination = destination
        self.format = format
        self.parentWindow = parentWindow
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 184),
            styleMask: [.titled, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = L10n.text("Compressing items")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        super.init(window: panel)
        panel.contentView = makeContentView()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showProgress() {
        guard let window else { return }
        if let parentWindow {
            parentWindow.addChildWindow(window, ordered: .above)
            let parentFrame = parentWindow.frame
            window.setFrameOrigin(NSPoint(
                x: parentFrame.midX - window.frame.width / 2,
                y: parentFrame.midY - window.frame.height / 2
            ))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        progressIndicator.startAnimation(nil)
        statusLabel.stringValue = L10n.text("Calculating source size") + "…"
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func begin(totalBytes: Int64, allowsOutputEstimate: Bool) {
        self.totalBytes = totalBytes
        self.allowsOutputEstimate = allowsOutputEstimate
        progressIndicator.stopAnimation(nil)
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        progressIndicator.doubleValue = 0
        refresh()
    }

    func update(completedBytes: Int64? = nil, fraction: Double? = nil) {
        if let completedBytes { self.completedBytes = max(self.completedBytes, completedBytes) }
        if let fraction { reportedFraction = max(reportedFraction, min(1, fraction)) }
        refresh()
    }

    func markCancelling() {
        statusLabel.stringValue = L10n.text("Cancelling") + "…"
        cancelButton.isEnabled = false
    }

    func finish() {
        timer?.invalidate()
        timer = nil
        progressIndicator.stopAnimation(nil)
        if let window, let parentWindow {
            parentWindow.removeChildWindow(window)
            parentWindow.makeKeyAndOrderFront(nil)
        }
        close()
    }

    private func makeContentView() -> NSView {
        let root = NSView()
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 18, right: 22)
        root.addSubview(stack)

        let title = NSTextField(labelWithString: String(format: L10n.text("Compressing as %@"), format.title) + "…")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle
        stack.addArrangedSubview(title)

        let path = NSTextField(labelWithString: destination.path)
        path.font = .systemFont(ofSize: 11)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        stack.addArrangedSubview(path)

        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = true
        progressIndicator.usesThreadedAnimation = true
        stack.addArrangedSubview(progressIndicator)

        let bottom = NSStackView()
        bottom.orientation = .horizontal
        bottom.alignment = .centerY
        bottom.spacing = 8
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        bottom.addArrangedSubview(statusLabel)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bottom.addArrangedSubview(spacer)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .tertiaryLabelColor
        bottom.addArrangedSubview(detailLabel)
        cancelButton.title = L10n.text("Cancel")
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        bottom.addArrangedSubview(cancelButton)
        stack.addArrangedSubview(bottom)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            title.widthAnchor.constraint(equalToConstant: 476),
            path.widthAnchor.constraint(equalToConstant: 476),
            progressIndicator.widthAnchor.constraint(equalToConstant: 476),
            bottom.widthAnchor.constraint(equalToConstant: 476)
        ])
        return root
    }

    private func refresh() {
        guard !progressIndicator.isIndeterminate else {
            detailLabel.stringValue = elapsedText
            return
        }
        let outputBytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        var fraction = reportedFraction
        if totalBytes > 0 { fraction = max(fraction, Double(completedBytes) / Double(totalBytes)) }
        if allowsOutputEstimate, totalBytes > 0 {
            fraction = max(fraction, min(0.9, Double(outputBytes) / Double(totalBytes)))
        }
        fraction = min(1, max(0, fraction))
        progressIndicator.doubleValue = fraction

        let percent = Int((fraction * 100).rounded(.down))
        let processed = totalBytes > 0 ? min(totalBytes, max(completedBytes, Int64(Double(totalBytes) * fraction))) : 0
        var pieces = [String(format: L10n.text("%d%% complete"), percent)]
        if totalBytes > 0 {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            pieces.append("\(formatter.string(fromByteCount: processed)) / \(formatter.string(fromByteCount: totalBytes))")
        }
        if fraction > 0.01, fraction < 1 {
            let elapsed = Date().timeIntervalSince(startedAt)
            let remaining = max(0, elapsed * (1 - fraction) / fraction)
            pieces.append(String(format: L10n.text("%@ remaining"), durationText(remaining)))
        }
        statusLabel.stringValue = pieces.joined(separator: " · ")
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        detailLabel.stringValue = String(format: L10n.text("%@ written"), formatter.string(fromByteCount: outputBytes))
    }

    private var elapsedText: String {
        String(format: L10n.text("Elapsed %@"), durationText(Date().timeIntervalSince(startedAt)))
    }

    private func durationText(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60) }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    @objc private func cancel(_ sender: Any?) {
        markCancelling()
        onCancel?()
    }
}

final class ArchiveOperationManager {
    static let shared = ArchiveOperationManager()

    private final class ActiveOperation {
        let process: Process
        let controller: ArchiveOperationProgressWindowController
        let command: ArchiveCommand
        let destination: URL
        let sources: [URL]
        let completion: (Result<Void, Error>) -> Void
        var wasCancelled = false
        var output = Data()
        var lineBuffer = ""
        var snapshot = ArchiveInputSnapshot(totalBytes: 0, fileSizes: [:])
        var completedPaths = Set<String>()
        var completedBytes: Int64 = 0
        var zipDotCount: Int64 = 0

        init(process: Process, controller: ArchiveOperationProgressWindowController, command: ArchiveCommand,
             destination: URL, sources: [URL], completion: @escaping (Result<Void, Error>) -> Void) {
            self.process = process
            self.controller = controller
            self.command = command
            self.destination = destination
            self.sources = sources
            self.completion = completion
        }
    }

    private var activeOperations: [UUID: ActiveOperation] = [:]
    var hasActiveOperations: Bool { !activeOperations.isEmpty }
    private init() {}

    func start(command: ArchiveCommand, sources: [URL], destination: URL, format: ArchiveCreationFormat,
               parentWindow: NSWindow?, completion: @escaping (Result<Void, Error>) -> Void) {
        let id = UUID()
        let process = Process()
        process.executableURL = command.executableURL
        process.arguments = command.arguments
        process.currentDirectoryURL = command.currentDirectoryURL
        if let environment = command.environment { process.environment = environment }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let controller = ArchiveOperationProgressWindowController(
            operationID: id, destination: destination, format: format, parentWindow: parentWindow
        )
        let operation = ActiveOperation(
            process: process, controller: controller, command: command,
            destination: destination, sources: sources, completion: completion
        )
        controller.onCancel = { [weak self] in self?.cancel(id: id) }
        activeOperations[id] = operation
        controller.showProgress()

        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak operation] in
            guard let self, let operation else { return }
            let snapshot = ArchiveInputSnapshot.measure(sources)
            DispatchQueue.main.async {
                guard self.activeOperations[id] === operation, !operation.wasCancelled else { return }
                operation.snapshot = snapshot
                let genericEstimate: Bool
                if case .verbosePaths = command.progressReporting { genericEstimate = true } else { genericEstimate = false }
                controller.begin(totalBytes: snapshot.totalBytes, allowsOutputEstimate: genericEstimate)
                self.launch(operation, id: id, pipe: pipe)
            }
        }
    }

    private func launch(_ operation: ActiveOperation, id: UUID, pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self, weak operation] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self, let operation else { return }
            DispatchQueue.main.async {
                guard self.activeOperations[id] === operation else { return }
                operation.output.append(data)
                if operation.output.count > 65_536 {
                    operation.output.removeFirst(operation.output.count - 65_536)
                }
                self.consume(data, for: operation)
            }
        }

        operation.process.terminationHandler = { [weak self, weak operation] process in
            DispatchQueue.main.async {
                guard let self, let operation,
                      self.activeOperations.removeValue(forKey: id) === operation else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                process.terminationHandler = nil
                operation.controller.update(completedBytes: operation.snapshot.totalBytes, fraction: 1)
                operation.controller.finish()
                if operation.wasCancelled {
                    operation.completion(.failure(FileTransferError.cancelled))
                } else if process.terminationStatus == 0 {
                    operation.completion(.success(()))
                } else {
                    let message = String(data: operation.output.suffix(16_384), encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    operation.completion(.failure(ArchiveOperationError.failed(
                        status: process.terminationStatus,
                        message: message
                    )))
                }
            }
        }

        do {
            try operation.process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            operation.process.terminationHandler = nil
            activeOperations.removeValue(forKey: id)
            operation.controller.finish()
            operation.completion(.failure(error))
        }
    }

    private func consume(_ data: Data, for operation: ActiveOperation) {
        let text = String(decoding: data, as: UTF8.self)
        switch operation.command.progressReporting {
        case .none:
            break
        case let .zipDots(bytesPerDot):
            operation.zipDotCount += Int64(text.reduce(into: 0) { if $1 == "." { $0 += 1 } })
            operation.controller.update(completedBytes: operation.zipDotCount * bytesPerDot)
        case .percentage:
            if let value = lastPercentage(in: text) {
                operation.controller.update(fraction: Double(min(100, value)) / 100)
            }
        case .verbosePaths:
            operation.lineBuffer += text.replacingOccurrences(of: "\r", with: "\n")
            let lines = operation.lineBuffer.split(separator: "\n", omittingEmptySubsequences: false)
            operation.lineBuffer = lines.last.map(String.init) ?? ""
            for rawLine in lines.dropLast() {
                var path = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                while path.hasPrefix("./") { path.removeFirst(2) }
                path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard let bytes = operation.snapshot.fileSizes[path],
                      operation.completedPaths.insert(path).inserted else { continue }
                operation.completedBytes += bytes
            }
            operation.controller.update(completedBytes: operation.completedBytes)
        }
    }

    private func lastPercentage(in text: String) -> Int? {
        guard let expression = try? NSRegularExpression(pattern: "(?:^|[^0-9])(\\d{1,3})%") else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.matches(in: text, range: range).last,
              let valueRange = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[valueRange])
    }

    private func cancel(id: UUID) {
        guard let operation = activeOperations[id], !operation.wasCancelled else { return }
        operation.wasCancelled = true
        operation.controller.markCancelling()
        if operation.process.isRunning {
            operation.process.terminate()
        } else {
            activeOperations.removeValue(forKey: id)
            operation.controller.finish()
            operation.completion(.failure(FileTransferError.cancelled))
        }
    }
}
