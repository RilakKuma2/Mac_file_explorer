import Foundation

extension Notification.Name {
    static let explorerSidebarPreferencesDidChange = Notification.Name("ExplorerSidebarPreferencesDidChange")
    static let explorerDesktopPreferenceDidChange = Notification.Name("ExplorerDesktopPreferenceDidChange")
    static let explorerFolderViewProfilesDidChange = Notification.Name("ExplorerFolderViewProfilesDidChange")
}

/// A complete, app-owned snapshot of the presentation choices that are useful
/// on a per-folder basis. It intentionally does not include transient state such
/// as selection, scroll position, filtering, or collapsed group headers.
struct FolderViewProfile: Codable, Equatable {
    var viewMode: FileViewMode
    var zoomLevel: Int
    var sortKey: FileSortKey
    var sortAscending: Bool
    var compactSpacing: Bool
    var showsFileExtensions: Bool
    var dateGroupingMode: FileDateGroupingMode
    var showsFolderSizes: Bool
}

enum FolderViewProfileScope: String, Codable, Equatable {
    case thisFolder
    case subfolders
}

struct FolderViewProfileMatch: Equatable {
    let profile: FolderViewProfile
    let sourceURL: URL
    let scope: FolderViewProfileScope
}

/// Pure UserDefaults-backed profile resolution. Exact profiles affect only one
/// directory. Recursive profiles affect their own directory and descendants;
/// the deepest ancestor wins. An exact match always wins at the same path.
struct FolderViewProfileStore {
    let defaults: UserDefaults
    let key: String

    private struct Payload: Codable, Equatable {
        var exact: [String: FolderViewProfile] = [:]
        var recursive: [String: FolderViewProfile] = [:]
    }

    func match(for directory: URL) -> FolderViewProfileMatch? {
        let path = normalizedPath(directory)
        let payload = load()
        if let profile = payload.exact[path] {
            return FolderViewProfileMatch(
                profile: profile,
                sourceURL: URL(fileURLWithPath: path, isDirectory: true),
                scope: .thisFolder
            )
        }

        let sourcePath = payload.recursive.keys
            .filter { contains(path, inRecursiveRoot: $0) }
            .max { lhs, rhs in
                let lhsDepth = pathDepth(lhs)
                let rhsDepth = pathDepth(rhs)
                return lhsDepth == rhsDepth ? lhs.count < rhs.count : lhsDepth < rhsDepth
            }
        guard let sourcePath, let profile = payload.recursive[sourcePath] else { return nil }
        return FolderViewProfileMatch(
            profile: profile,
            sourceURL: URL(fileURLWithPath: sourcePath, isDirectory: true),
            scope: .subfolders
        )
    }

    func hasLocalProfile(for directory: URL) -> Bool {
        let path = normalizedPath(directory)
        let payload = load()
        return payload.exact[path] != nil || payload.recursive[path] != nil
    }

    @discardableResult
    func save(
        _ profile: FolderViewProfile,
        for directory: URL,
        scope: FolderViewProfileScope
    ) -> Bool {
        let path = normalizedPath(directory)
        var payload = load()
        switch scope {
        case .thisFolder:
            guard payload.exact[path] != profile else { return false }
            payload.exact[path] = profile
        case .subfolders:
            // Applying to a subtree includes the root folder. Keep an exact copy
            // too so a stale local profile cannot hide the newly chosen view.
            guard payload.recursive[path] != profile || payload.exact[path] != profile else { return false }
            payload.recursive[path] = profile
            payload.exact[path] = profile
        }
        persist(payload)
        return true
    }

    /// Removes both exact and recursive definitions rooted at this directory.
    /// Descendant definitions are retained because they were explicitly saved.
    @discardableResult
    func reset(_ directory: URL) -> Bool {
        let path = normalizedPath(directory)
        var payload = load()
        let removedExact = payload.exact.removeValue(forKey: path) != nil
        let removedRecursive = payload.recursive.removeValue(forKey: path) != nil
        guard removedExact || removedRecursive else { return false }
        persist(payload)
        return true
    }

    private func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func contains(_ target: String, inRecursiveRoot root: String) -> Bool {
        root == "/" || target == root || target.hasPrefix(root + "/")
    }

    private func pathDepth(_ path: String) -> Int {
        URL(fileURLWithPath: path, isDirectory: true).pathComponents.count
    }

    private func load() -> Payload {
        guard let data = defaults.data(forKey: key),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return Payload() }
        return payload
    }

    private func persist(_ payload: Payload) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: key)
    }
}

struct PinnedFolderStore {
    let defaults: UserDefaults
    let key: String

    private var bookmarkKey: String { key + ".Bookmarks" }

    private var bookmarks: [String: Data] {
        let dictionary = defaults.dictionary(forKey: bookmarkKey) ?? [:]
        return dictionary.reduce(into: [:]) { result, entry in
            if let data = entry.value as? Data { result[entry.key] = data }
        }
    }

    var urls: [URL] {
        let paths = defaults.stringArray(forKey: key) ?? []
        var seen = Set<String>()
        return paths.compactMap { path -> URL? in
            guard !path.isEmpty else { return nil }
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            return seen.insert(url.path).inserted ? url : nil
        }
    }

    func contains(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return urls.contains { $0.path == path }
    }

    @discardableResult
    func pin(_ url: URL) -> Bool {
        let normalized = url.standardizedFileURL
        var values = urls
        guard !values.contains(where: { $0.path == normalized.path }) else { return false }
        guard values.count < 50 else { return false }
        values.append(normalized)
        defaults.set(values.map(\.path), forKey: key)
        return true
    }

    @discardableResult
    func unpin(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let values = urls
        let filtered = values.filter { $0.path != path }
        guard filtered.count != values.count else { return false }
        defaults.set(filtered.map(\.path), forKey: key)
        var bookmarkValues = bookmarks
        bookmarkValues.removeValue(forKey: path)
        defaults.set(bookmarkValues, forKey: bookmarkKey)
        return true
    }

    @discardableResult
    func move(_ url: URL, to proposedIndex: Int) -> Bool {
        let path = url.standardizedFileURL.path
        var values = urls
        guard let oldIndex = values.firstIndex(where: { $0.path == path }) else { return false }
        let value = values.remove(at: oldIndex)
        let newIndex = min(max(0, proposedIndex), values.count)
        guard oldIndex != newIndex else { return false }
        values.insert(value, at: newIndex)
        defaults.set(values.map(\.path), forKey: key)
        return true
    }

    @discardableResult
    func insert(_ urlsToInsert: [URL], at proposedIndex: Int) -> Int {
        var values = urls
        var knownPaths = Set(values.map(\.path))
        var insertionIndex = min(max(0, proposedIndex), values.count)
        var insertedCount = 0
        for url in urlsToInsert {
            guard values.count < 50 else { break }
            let normalized = url.standardizedFileURL
            guard knownPaths.insert(normalized.path).inserted else { continue }
            values.insert(normalized, at: insertionIndex)
            insertionIndex += 1
            insertedCount += 1
        }
        guard insertedCount > 0 else { return 0 }
        defaults.set(values.map(\.path), forKey: key)
        return insertedCount
    }

    @discardableResult
    func relocate(from oldURL: URL, to newURL: URL) -> Bool {
        let oldPath = oldURL.standardizedFileURL.path
        let newPath = newURL.standardizedFileURL.path
        let descendantPrefix = oldPath == "/" ? "/" : oldPath + "/"
        var values = urls
        var bookmarkValues = bookmarks
        var changed = false

        for index in values.indices {
            let path = values[index].path
            guard path == oldPath || path.hasPrefix(descendantPrefix) else { continue }
            let suffix = String(path.dropFirst(oldPath.count))
            let relocatedPath = newPath + suffix
            values[index] = URL(fileURLWithPath: relocatedPath, isDirectory: true).standardizedFileURL
            if let data = bookmarkValues.removeValue(forKey: path) {
                bookmarkValues[relocatedPath] = data
            }
            changed = true
        }
        guard changed else { return false }
        defaults.set(values.map(\.path), forKey: key)
        defaults.set(bookmarkValues, forKey: bookmarkKey)
        return true
    }

    /// Resolves file-reference bookmarks off the main thread. Missing/offline
    /// locations retain their last path so they can still be removed.
    @discardableResult
    func refreshBookmarks() -> Bool {
        let storedPaths = defaults.stringArray(forKey: key) ?? []
        let bookmarkValues = bookmarks
        var refreshedPaths: [String] = []
        var refreshedBookmarks: [String: Data] = [:]
        var seen = Set<String>()
        var pathChanged = false

        for storedPath in storedPaths where !storedPath.isEmpty {
            var resolvedURL = URL(fileURLWithPath: storedPath, isDirectory: true).standardizedFileURL
            var bookmarkData = bookmarkValues[storedPath]
            var bookmarkWasStale = false

            if let data = bookmarkData,
               let resolved = try? URL(
                    resolvingBookmarkData: data,
                    options: [.withoutUI],
                    relativeTo: nil,
                    bookmarkDataIsStale: &bookmarkWasStale
               ) {
                resolvedURL = resolved.standardizedFileURL
            }

            let resolvedPath = resolvedURL.path
            guard seen.insert(resolvedPath).inserted else {
                pathChanged = true
                continue
            }
            if resolvedPath != storedPath { pathChanged = true }

            if bookmarkData == nil || bookmarkWasStale || resolvedPath != storedPath {
                bookmarkData = try? resolvedURL.bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: [.isDirectoryKey],
                    relativeTo: nil
                )
            }
            refreshedPaths.append(resolvedPath)
            if let bookmarkData { refreshedBookmarks[resolvedPath] = bookmarkData }
        }

        // A pin/unpin/reorder may have happened while bookmark resolution was
        // blocked on an offline volume. Never overwrite that newer path list.
        guard (defaults.stringArray(forKey: key) ?? []) == storedPaths else { return false }
        if pathChanged {
            defaults.set(refreshedPaths, forKey: key)
        }
        if refreshedBookmarks != bookmarkValues {
            defaults.set(refreshedBookmarks, forKey: bookmarkKey)
        }
        return pathChanged
    }
}

enum ExplorerPreferences {
    private static let showRecentsKey = "ExplorerSidebarShowRecents"
    private static let showTrashKey = "ExplorerSidebarShowTrash"
    // Keep the existing key so users who enabled the old Desktop integration
    // are migrated directly to Finder Desktop folder routing.
    private static let finderDesktopFolderRoutingKey = "ExplorerUseDesktop"
    private static let pinnedFoldersKey = "ExplorerPinnedFolders"
    private static let folderViewProfilesKey = "ExplorerFolderViewProfiles.v1"
    private static let pinnedBookmarkQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "app.macexplorer.pinned-folder-bookmarks"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    private static var pinnedFolderStore: PinnedFolderStore {
        PinnedFolderStore(defaults: .standard, key: pinnedFoldersKey)
    }

    private static var folderViewProfileStore: FolderViewProfileStore {
        FolderViewProfileStore(defaults: .standard, key: folderViewProfilesKey)
    }

    static func folderViewProfile(for directory: URL) -> FolderViewProfileMatch? {
        folderViewProfileStore.match(for: directory)
    }

    static func hasLocalFolderViewProfile(for directory: URL) -> Bool {
        folderViewProfileStore.hasLocalProfile(for: directory)
    }

    @discardableResult
    static func saveFolderViewProfile(
        _ profile: FolderViewProfile,
        for directory: URL,
        scope: FolderViewProfileScope
    ) -> Bool {
        guard folderViewProfileStore.save(profile, for: directory, scope: scope) else { return false }
        NotificationCenter.default.post(name: .explorerFolderViewProfilesDidChange, object: directory)
        return true
    }

    @discardableResult
    static func resetFolderViewProfile(for directory: URL) -> Bool {
        guard folderViewProfileStore.reset(directory) else { return false }
        NotificationCenter.default.post(name: .explorerFolderViewProfilesDidChange, object: directory)
        return true
    }

    static var pinnedFolderURLs: [URL] { pinnedFolderStore.urls }

    static func isFolderPinned(_ url: URL) -> Bool {
        pinnedFolderStore.contains(url)
    }

    @discardableResult
    static func pinFolder(_ url: URL) -> Bool {
        guard pinnedFolderStore.pin(url) else { return false }
        NotificationCenter.default.post(name: .explorerSidebarPreferencesDidChange, object: nil)
        refreshPinnedFolderBookmarks()
        return true
    }

    @discardableResult
    static func unpinFolder(_ url: URL) -> Bool {
        guard pinnedFolderStore.unpin(url) else { return false }
        NotificationCenter.default.post(name: .explorerSidebarPreferencesDidChange, object: nil)
        return true
    }

    @discardableResult
    static func movePinnedFolder(_ url: URL, to index: Int) -> Bool {
        guard pinnedFolderStore.move(url, to: index) else { return false }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .explorerSidebarPreferencesDidChange, object: nil)
        }
        return true
    }

    @discardableResult
    static func pinFolders(_ urls: [URL], at index: Int) -> Int {
        let count = pinnedFolderStore.insert(urls, at: index)
        guard count > 0 else { return 0 }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .explorerSidebarPreferencesDidChange, object: nil)
        }
        refreshPinnedFolderBookmarks()
        return count
    }

    @discardableResult
    static func relocatePinnedFolder(from oldURL: URL, to newURL: URL) -> Bool {
        guard pinnedFolderStore.relocate(from: oldURL, to: newURL) else { return false }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .explorerSidebarPreferencesDidChange, object: nil)
        }
        refreshPinnedFolderBookmarks()
        return true
    }

    static func refreshPinnedFolderBookmarks() {
        guard pinnedBookmarkQueue.operationCount == 0 else { return }
        let store = pinnedFolderStore
        pinnedBookmarkQueue.addOperation {
            guard store.refreshBookmarks() else { return }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .explorerSidebarPreferencesDidChange, object: nil)
            }
        }
    }

    static var showRecentsInSidebar: Bool {
        get { UserDefaults.standard.object(forKey: showRecentsKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: showRecentsKey)
            NotificationCenter.default.post(name: .explorerSidebarPreferencesDidChange, object: nil)
        }
    }

    static var showTrashInSidebar: Bool {
        get { UserDefaults.standard.object(forKey: showTrashKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: showTrashKey)
            NotificationCenter.default.post(name: .explorerSidebarPreferencesDidChange, object: nil)
        }
    }

    static var openFinderDesktopFoldersInExplorer: Bool {
        get { UserDefaults.standard.bool(forKey: finderDesktopFolderRoutingKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: finderDesktopFolderRoutingKey)
            NotificationCenter.default.post(name: .explorerDesktopPreferenceDidChange, object: nil)
        }
    }
}
