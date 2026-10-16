import Foundation
import Testing
@testable import MacExplorer

@Suite("ExplorerPreferences")
struct ExplorerPreferencesTests {
    @Test("Folder view profiles prefer exact settings, then the nearest recursive ancestor")
    func folderViewProfileResolution() throws {
        let suiteName = "MacExplorerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = FolderViewProfileStore(defaults: defaults, key: "FolderViews")
        let root = URL(fileURLWithPath: "/Volumes/Work", isDirectory: true)
        let project = root.appendingPathComponent("Project", isDirectory: true)
        let assets = project.appendingPathComponent("Assets", isDirectory: true)
        let child = assets.appendingPathComponent("Textures", isDirectory: true)
        let rootProfile = profile(zoom: 2, sort: .name)
        let projectProfile = profile(zoom: 4, sort: .modifiedAt)
        let exactProfile = profile(zoom: 1, sort: .size)

        #expect(store.save(rootProfile, for: root, scope: .subfolders))
        #expect(store.save(projectProfile, for: project, scope: .subfolders))
        #expect(store.save(exactProfile, for: assets, scope: .thisFolder))

        let exactMatch = try #require(store.match(for: assets))
        #expect(exactMatch.profile == exactProfile)
        #expect(exactMatch.scope == .thisFolder)
        #expect(exactMatch.sourceURL.path == assets.path)

        let inheritedMatch = try #require(store.match(for: child))
        #expect(inheritedMatch.profile == projectProfile)
        #expect(inheritedMatch.scope == .subfolders)
        #expect(inheritedMatch.sourceURL.path == project.path)

        let rootChild = root.appendingPathComponent("Other", isDirectory: true)
        #expect(store.match(for: rootChild)?.profile == rootProfile)
        #expect(store.match(for: URL(fileURLWithPath: "/Volumes/Workshop")) == nil)
    }

    @Test("Resetting a folder view removes both local scopes and reveals its inherited profile")
    func folderViewProfileReset() throws {
        let suiteName = "MacExplorerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = FolderViewProfileStore(defaults: defaults, key: "FolderViews")
        let root = URL(fileURLWithPath: "/tmp/views", isDirectory: true)
        let child = root.appendingPathComponent("child", isDirectory: true)
        let inherited = profile(zoom: 3, sort: .kind)
        let local = profile(zoom: 5, sort: .size)

        #expect(store.save(inherited, for: root, scope: .subfolders))
        #expect(store.save(local, for: child, scope: .thisFolder))
        #expect(store.save(local, for: child, scope: .subfolders))
        #expect(store.reset(child))
        #expect(store.match(for: child)?.profile == inherited)
        #expect(store.match(for: child)?.sourceURL.path == root.path)
        #expect(!store.reset(child))
    }

    @Test("Applying a profile recursively also replaces a stale root profile")
    func recursiveFolderViewProfileIncludesRoot() throws {
        let suiteName = "MacExplorerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = FolderViewProfileStore(defaults: defaults, key: "FolderViews")
        let root = URL(fileURLWithPath: "/tmp/view-root", isDirectory: true)
        let child = root.appendingPathComponent("child", isDirectory: true)
        let stale = profile(zoom: 1, sort: .name)
        let recursive = profile(zoom: 4, sort: .modifiedAt)

        #expect(store.save(stale, for: root, scope: .thisFolder))
        #expect(store.save(recursive, for: root, scope: .subfolders))
        #expect(store.match(for: root)?.profile == recursive)
        #expect(store.match(for: root)?.scope == .thisFolder)
        #expect(store.match(for: child)?.profile == recursive)
        #expect(store.match(for: child)?.scope == .subfolders)
    }

    private func profile(zoom: Int, sort: FileSortKey) -> FolderViewProfile {
        FolderViewProfile(
            viewMode: zoom <= 1 ? .details : .icons,
            zoomLevel: zoom,
            sortKey: sort,
            sortAscending: false,
            compactSpacing: true,
            showsFileExtensions: true,
            dateGroupingMode: .enabled,
            showsFolderSizes: true
        )
    }

    @Test("Pinned folders preserve order, reject duplicates, and can be removed")
    func pinnedFolderStore() throws {
        let suiteName = "MacExplorerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PinnedFolderStore(defaults: defaults, key: "Pinned")
        let first = URL(fileURLWithPath: "/tmp/first", isDirectory: true)
        let second = URL(fileURLWithPath: "/tmp/second", isDirectory: true)

        #expect(store.pin(first))
        #expect(!store.pin(first.appendingPathComponent("..", isDirectory: true)
            .appendingPathComponent("first", isDirectory: true)))
        #expect(store.pin(second))
        #expect(store.urls.map(\.path) == [first.path, second.path])
        #expect(store.contains(first))

        #expect(store.move(first, to: 1))
        #expect(store.urls.map(\.path) == [second.path, first.path])

        let third = URL(fileURLWithPath: "/tmp/third", isDirectory: true)
        let fourth = URL(fileURLWithPath: "/tmp/fourth", isDirectory: true)
        #expect(store.insert([third, first, fourth], at: 1) == 2)
        #expect(store.urls.map(\.path) == [second.path, third.path, fourth.path, first.path])

        #expect(store.unpin(first))
        #expect(!store.unpin(first))
        #expect(store.urls.map(\.path) == [second.path, third.path, fourth.path])
    }

    @Test("Pinned folder limit reports failure without dropping data")
    func pinnedFolderLimit() throws {
        let suiteName = "MacExplorerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PinnedFolderStore(defaults: defaults, key: "Pinned")

        for index in 0..<50 {
            #expect(store.pin(URL(fileURLWithPath: "/tmp/pin-\(index)", isDirectory: true)))
        }
        #expect(!store.pin(URL(fileURLWithPath: "/tmp/overflow", isDirectory: true)))
        #expect(store.urls.count == 50)
        #expect(store.urls.last?.path == "/tmp/pin-49")
    }

    @Test("Pinned paths follow app-managed parent moves")
    func pinnedFolderRelocation() throws {
        let suiteName = "MacExplorerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PinnedFolderStore(defaults: defaults, key: "Pinned")
        let parent = URL(fileURLWithPath: "/tmp/Parent", isDirectory: true)
        let child = parent.appendingPathComponent("Child", isDirectory: true)
        let moved = URL(fileURLWithPath: "/tmp/Moved", isDirectory: true)

        #expect(store.pin(parent))
        #expect(store.pin(child))
        #expect(store.relocate(from: parent, to: moved))
        #expect(store.urls.map(\.path) == [moved.path, moved.appendingPathComponent("Child").path])
    }

    @Test("File-reference bookmarks follow folders renamed outside the app")
    func pinnedFolderBookmarkRename() throws {
        let suiteName = "MacExplorerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PinnedFolderStore(defaults: defaults, key: "Pinned")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacExplorerPinBookmark-\(UUID().uuidString)", isDirectory: true)
        let original = root.appendingPathComponent("Original", isDirectory: true)
        let renamed = root.appendingPathComponent("Renamed", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(store.pin(original))
        #expect(!store.refreshBookmarks())
        try FileManager.default.moveItem(at: original, to: renamed)
        #expect(store.refreshBookmarks())
        #expect(store.urls.map(\.path) == [renamed.path])
    }
}
