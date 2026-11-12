import AppKit

/// Opt-in trace of click routing and list refreshes, for input problems that
/// only reproduce with a real pointer. Enable with
/// `defaults write app.macexplorer.filemanager ExplorerInputDiagnostics -bool YES`
/// and relaunch. Records timings, counts, row indexes and view class names
/// only; never paths or file names.
enum InputDiagnostics {
    static let defaultsKey = "ExplorerInputDiagnostics"
    static let isEnabled = UserDefaults.standard.bool(forKey: defaultsKey)

    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Mac Explorer/input-diagnostics.log")

    private static let queue = DispatchQueue(label: "app.macexplorer.input-diagnostics", qos: .utility)
    private static var handle: FileHandle?
    private static var observers: [NSObjectProtocol] = []
    private static var watchdog: DispatchSourceTimer?
    private static let maximumLogBytes: UInt64 = 4 * 1_024 * 1_024

    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    static func milliseconds(since start: TimeInterval) -> String {
        String(format: "%.1f", (now - start) * 1_000)
    }

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let line = String(format: "%.3f ", now) + (Thread.isMainThread ? "" : "[bg] ") + message() + "\n"
        queue.async { write(line) }
    }

    /// Short description of a view and its nearest ancestors, by class only.
    static func describe(_ view: NSView?) -> String {
        guard let view else { return "nil" }
        return sequence(first: view, next: { $0.superview })
            .prefix(4)
            .map { String(describing: type(of: $0)) }
            .joined(separator: "<")
    }

    static func start() {
        guard isEnabled, observers.isEmpty else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        log("==== session start version=\(version) pid=\(ProcessInfo.processInfo.processIdentifier)")

        let center = NotificationCenter.default
        let names: [(Notification.Name, String)] = [
            (NSApplication.didBecomeActiveNotification, "app active"),
            (NSApplication.didResignActiveNotification, "app inactive"),
            (NSWindow.didBecomeKeyNotification, "window key"),
            (NSWindow.didResignKeyNotification, "window not key")
        ]
        for (name, label) in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                let kind = (note.object as? NSWindow).map { " " + String(describing: type(of: $0)) } ?? ""
                log(label + kind)
            })
        }
        startWatchdog()
    }

    /// Reports how long the main thread failed to service its queue. A click
    /// that arrives during such a stall looks ignored until the stall ends.
    private static func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        var pingSentAt: TimeInterval?
        var reportedStall = false
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler {
            if let sentAt = pingSentAt {
                if !reportedStall, now - sentAt > 0.3 {
                    reportedStall = true
                    write(String(format: "%.3f [bg] MAIN STALL began (unresponsive for %.0f ms so far)\n",
                                 now, (now - sentAt) * 1_000))
                }
                return
            }
            let sentAt = now
            pingSentAt = sentAt
            // Common modes: a nested menu or mouse tracking loop is not a stall.
            RunLoop.main.perform(inModes: [.common]) {
                let delay = now - sentAt
                queue.async {
                    if reportedStall || delay > 0.3 {
                        write(String(format: "%.3f [bg] MAIN STALL ended after %.0f ms\n", now, delay * 1_000))
                    }
                    pingSentAt = nil
                    reportedStall = false
                }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        timer.resume()
        watchdog = timer
    }

    private static func write(_ line: String) {
        if handle == nil {
            let directory = logURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? UInt64) ?? 0
            if size > maximumLogBytes { try? FileManager.default.removeItem(at: logURL) }
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: logURL)
            _ = try? handle?.seekToEnd()
        }
        guard let data = line.data(using: .utf8) else { return }
        try? handle?.write(contentsOf: data)
    }
}
