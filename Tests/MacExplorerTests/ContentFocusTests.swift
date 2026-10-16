import AppKit
import Testing
@testable import MacExplorer

@Suite("Explorer content focus")
struct ContentFocusTests {
    @Test("Selecting the current sidebar page cancels a pending folder navigation")
    @MainActor
    func sidebarCancelsPendingNavigation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = MainViewController(initialLocation: .home)
        _ = controller.view
        let sidebar = try #require(controller.children.compactMap { $0 as? SidebarViewController }.first)
        controller.navigate(to: directory)
        controller.sidebar(sidebar, didSelect: .home)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(controller.currentLocation == .home)
    }

    @Test("Pending navigation respects a hidden-file setting changed during loading")
    @MainActor
    func navigationVisibilityChange() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("visible.txt"))
        try Data().write(to: root.appendingPathComponent(".hidden.txt"))
        let savedPreference = UserDefaults.standard.object(forKey: "ExplorerShowHiddenFiles")
        defer {
            if let savedPreference { UserDefaults.standard.set(savedPreference, forKey: "ExplorerShowHiddenFiles") }
            else { UserDefaults.standard.removeObject(forKey: "ExplorerShowHiddenFiles") }
        }
        let controller = MainViewController(initialLocation: .home)
        _ = controller.view
        let list = try #require(controller.children.compactMap { $0 as? FileListViewController }.first)
        controller.navigate(to: root)
        controller.toggleHiddenFiles(nil)
        for _ in 0..<300 {
            if controller.currentURL.standardizedFileURL == root.standardizedFileURL { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(controller.currentURL.standardizedFileURL == root.standardizedFileURL)
        #expect(list.allItems.contains(where: { $0.name == ".hidden.txt" }) == controller.isShowingHiddenFiles)
        #expect(list.allItems.contains(where: { $0.name == "visible.txt" }))
    }

    @Test("Folder navigation retains the old page until ready and supersedes stale requests")
    @MainActor
    func deferredFolderNavigation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("First", isDirectory: true)
        let second = root.appendingPathComponent("Second", isDirectory: true)
        let third = root.appendingPathComponent("Third", isDirectory: true)
        for folder in [first, second, third] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        }
        try Data().write(to: first.appendingPathComponent("original.txt"))
        let controller = MainViewController(initialURL: first)
        _ = controller.view
        let list = try #require(controller.children.compactMap { $0 as? FileListViewController }.first)
        for _ in 0..<300 {
            if list.allItems.count == 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(list.allItems.count == 1)
        controller.navigate(to: second)
        #expect(controller.currentURL.standardizedFileURL == first.standardizedFileURL)
        #expect(list.allItems.first?.name == "original.txt")
        controller.navigate(to: third)
        #expect(controller.currentURL.standardizedFileURL == first.standardizedFileURL)
        for _ in 0..<300 {
            if controller.currentURL.standardizedFileURL == third.standardizedFileURL { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(controller.currentURL.standardizedFileURL == third.standardizedFileURL)
        #expect(list.directoryURL.standardizedFileURL == third.standardizedFileURL)
        #expect(list.allItems.isEmpty)
        controller.goBack(nil)
        #expect(controller.currentURL.standardizedFileURL == third.standardizedFileURL)
        for _ in 0..<300 {
            if controller.currentURL.standardizedFileURL == first.standardizedFileURL { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(controller.currentURL.standardizedFileURL == first.standardizedFileURL)
        #expect(list.allItems.first?.name == "original.txt")
        #expect(!controller.canNavigateBack)
    }

    @Test("Hidden Home does not rebuild its controls when filters change")
    @MainActor
    func hiddenHomeKeepsControls() {
        let home = HomeViewController()
        _ = home.view
        let document = (home.view as? NSScrollView)?.documentView
        let stack = document?.subviews.compactMap { $0 as? NSStackView }.first
        let original = stack?.arrangedSubviews.first
        home.setFilter("a different filter")
        #expect(!home.isContentVisible)
        #expect(stack?.arrangedSubviews.first === original)
    }

    @Test("Creating a folder selects it and enters inline rename after loading")
    @MainActor
    func newFolderRename() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = MainViewController(initialURL: directory)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        controller.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
        controller.view.layoutSubtreeIfNeeded()
        controller.newFolder(nil)
        for _ in 0..<300 {
            if window.firstResponder is NSTextView { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let editor = try #require(window.firstResponder as? NSTextView)
        #expect(editor.isEditable)
        let created = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(created.count == 1)
        #expect(editor.string == created.first?.lastPathComponent)
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
    }

    @Test("Home focus enters an actionable content card")
    @MainActor
    func homeFocus() {
        let controller = HomeViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller

        controller.focus()

        #expect(controller.hasKeyboardFocus)
        #expect(window.firstResponder is NSButton)
    }

    @Test("Network focus enters its first command")
    @MainActor
    func networkFocus() {
        let controller = NetworkViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller

        controller.focus()

        #expect(controller.hasKeyboardFocus)
        #expect(window.firstResponder is NSButton)
    }
}
