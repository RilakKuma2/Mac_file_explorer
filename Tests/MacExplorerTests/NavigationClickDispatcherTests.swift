import AppKit
import Testing
@testable import MacExplorer

private final class NavigationActionRecorder: NSObject {
    var count = 0
    @objc func clicked(_ sender: Any?) { count += 1 }
}

struct NavigationClickDispatcherTests {
    @Test @MainActor
    func actionsLeaveEventMonitorBeforeRunning() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let recorder = NavigationActionRecorder()
        let button = NSButton()
        button.target = recorder
        button.action = #selector(NavigationActionRecorder.clicked(_:))
        window.contentView?.addSubview(button)
        NavigationClickDispatcher.enqueue(button)
        #expect(recorder.count == 0)
        for _ in 0..<50 where recorder.count == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(recorder.count == 1)
        NavigationClickDispatcher.enqueue(button)
        button.removeFromSuperview()
        try await Task.sleep(nanoseconds: 10_000_000)
        #expect(recorder.count == 1)
    }
}
