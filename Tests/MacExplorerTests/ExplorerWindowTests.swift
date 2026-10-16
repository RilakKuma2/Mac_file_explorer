import AppKit
import Testing
@testable import MacExplorer

@Suite("Explorer window size")
struct ExplorerWindowTests {
    @Test("New windows restore the last resized window size")
    @MainActor
    func remembersSize() throws {
        let suite = "ExplorerWindowTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = makeWindow()
        first.restoreAndRememberSize(defaults: defaults)
        first.setFrame(NSRect(x: 100, y: 100, width: 640, height: 480), display: false)
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: first)
        let second = makeWindow()
        second.restoreAndRememberSize(defaults: defaults)
        #expect(second.frame.size == NSSize(width: 640, height: 480))
        second.setFrame(NSRect(x: 100, y: 100, width: 700, height: 500), display: false)
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: second)
        let third = makeWindow()
        third.restoreAndRememberSize(defaults: defaults)
        #expect(third.frame.size == NSSize(width: 700, height: 500))
    }

    @Test("Invalid saved sizes are ignored")
    @MainActor
    func rejectsInvalidSize() throws {
        let suite = "ExplorerWindowTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([-1.0, 0.0], forKey: "ExplorerWindowLastSize")
        let window = makeWindow()
        let original = window.frame
        window.restoreAndRememberSize(defaults: defaults)
        #expect(window.frame == original)
    }

    @MainActor
    private func makeWindow() -> ExplorerWindow {
        let window = ExplorerWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.minSize = NSSize(width: 320, height: 420)
        window.isReleasedWhenClosed = false
        return window
    }
}
