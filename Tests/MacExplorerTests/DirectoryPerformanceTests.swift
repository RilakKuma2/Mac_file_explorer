import AppKit
import Testing
@testable import MacExplorer

struct DirectoryPerformanceTests {
    @Test("Superseded directory enumeration can cancel before reading metadata")
    func cancelledListing() {
        #expect(throws: CancellationError.self) {
            try FileSystemService.shared.contents(of: FileManager.default.temporaryDirectory,
                showHidden: true, shouldContinue: { false })
        }
    }

    @Test("Opt-in directory listing and presentation benchmark")
    @MainActor
    func directoryBenchmark() throws {
        guard let path = ProcessInfo.processInfo.environment["MAC_EXPLORER_BENCHMARK_DIRECTORY"] else { return }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isHiddenKey,
            .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey,
            .localizedTypeDescriptionKey, .contentTypeKey]
        let controller = FileListViewController()
        _ = controller.view
        for pass in 0..<3 {
            let start = Date()
            let oldURLs = try FileManager.default.contentsOfDirectory(at: url,
                includingPropertiesForKeys: Array(keys), options: [])
            let oldItems = oldURLs.compactMap { child -> FileItem? in
                guard let values = try? child.resourceValues(forKeys: keys) else { return nil }
                return FileItem(url: child, resourceValues: values)
            }
            let oldEnd = Date()
            let items = try FileSystemService.shared.contents(of: url, showHidden: true)
            let listEnd = Date()
            controller.display(items: items, in: url)
            let renderEnd = Date()
            print("DIRECTORY_BENCH pass=\(pass) count=\(oldItems.count)/\(items.count) initialListing=\(oldEnd.timeIntervalSince(start)) currentListing=\(listEnd.timeIntervalSince(oldEnd)) presentation=\(renderEnd.timeIntervalSince(listEnd))")
        }
    }
}
