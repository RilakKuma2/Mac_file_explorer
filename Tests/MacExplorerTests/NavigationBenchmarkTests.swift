import AppKit
import Testing
@testable import MacExplorer
struct NavigationBenchmarkTests {
    @Test @MainActor
    func navigationBenchmark() async throws {
        guard let path = ProcessInfo.processInfo.environment["MAC_EXPLORER_BENCHMARK_DIRECTORY"] else { return }
        let target = URL(fileURLWithPath: path, isDirectory: true)
        let controller = MainViewController(initialLocation: .home)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        controller.view.frame = NSRect(x: 0, y: 0, width: 1120, height: 720)
        controller.view.layoutSubtreeIfNeeded()
        let list = try #require(controller.children.compactMap { $0 as? FileListViewController }.first)
        for pass in 0..<6 {
            let destination = pass % 2 == 0 ? target : target.deletingLastPathComponent()
            let start = Date()
            controller.navigate(to: destination)
            let syncEnd = Date()
            for _ in 0..<10_000 {
                if list.directoryURL.standardizedFileURL.path == destination.standardizedFileURL.path,
                   !list.allItems.isEmpty { break }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            controller.view.layoutSubtreeIfNeeded()
            print("NAV_BENCH pass=\(pass) items=\(list.allItems.count) synchronous=\(syncEnd.timeIntervalSince(start)) total=\(Date().timeIntervalSince(start))")
        }
    }
}
