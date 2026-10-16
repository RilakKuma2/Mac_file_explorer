import AppKit
import CoreServices

struct FinderSidebarEntry: Hashable {
    let title: String
    let url: URL
    let symbolName: String
}

final class FinderSidebarProvider {
    private let manager = FileManager.default

    func favorites() -> [FinderSidebarEntry] {
        var urls = sharedFileListURLs(identifier: kLSSharedFileListFavoriteItems.takeUnretainedValue())
        let desktopURL = manager.urls(for: .desktopDirectory, in: .userDomainMask).first

        if urls.isEmpty {
            let standardDirectories: [FileManager.SearchPathDirectory] = [
                .desktopDirectory,
                .documentDirectory,
                .downloadsDirectory,
                .moviesDirectory,
                .musicDirectory,
                .picturesDirectory
            ]
            urls = [URL(fileURLWithPath: "/Applications"), manager.homeDirectoryForCurrentUser]
            urls.append(contentsOf: standardDirectories.compactMap { manager.urls(for: $0, in: .userDomainMask).first })
        }
        if let desktopURL,
           !urls.contains(where: { $0.standardizedFileURL == desktopURL.standardizedFileURL }) {
            urls.append(desktopURL)
        }

        return deduplicated(urls).compactMap { url in
            guard manager.fileExists(atPath: url.path) else { return nil }
            let symbol: String
            switch url.standardizedFileURL.path {
            case manager.homeDirectoryForCurrentUser.standardizedFileURL.path: symbol = "house"
            case manager.urls(for: .applicationDirectory, in: .userDomainMask).first?.path: symbol = "square.grid.2x2"
            case manager.urls(for: .desktopDirectory, in: .userDomainMask).first?.path: symbol = "menubar.dock.rectangle"
            case manager.urls(for: .documentDirectory, in: .userDomainMask).first?.path: symbol = "doc.text"
            case manager.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path: symbol = "arrow.down.circle"
            case manager.urls(for: .moviesDirectory, in: .userDomainMask).first?.path: symbol = "film"
            case manager.urls(for: .musicDirectory, in: .userDomainMask).first?.path: symbol = "music.note"
            case manager.urls(for: .picturesDirectory, in: .userDomainMask).first?.path: symbol = "photo"
            default: symbol = "folder"
            }
            let title = url.standardizedFileURL == desktopURL?.standardizedFileURL
                ? L10n.text("Desktop")
                : manager.displayName(atPath: url.path)
            return FinderSidebarEntry(title: title, url: url, symbolName: symbol)
        }
    }

    func iCloudLocations() -> [FinderSidebarEntry] {
        let iCloudDrive = manager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        var urls: [URL] = []
        if manager.fileExists(atPath: iCloudDrive.path) { urls.append(iCloudDrive) }
        urls.append(contentsOf: cloudStorageProviders().filter { $0.lastPathComponent.localizedCaseInsensitiveContains("icloud") })
        return deduplicated(urls).map {
            FinderSidebarEntry(title: L10n.text("iCloud Drive"), url: $0, symbolName: "icloud")
        }
    }

    func locations() -> [FinderSidebarEntry] {
        var entries = [
            FinderSidebarEntry(title: L10n.text("This Mac"), url: URL(fileURLWithPath: "/"), symbolName: "desktopcomputer")
        ]

        entries.append(contentsOf: cloudStorageProviders()
            .filter { !$0.lastPathComponent.localizedCaseInsensitiveContains("icloud") }
            .map { url in
                FinderSidebarEntry(title: manager.displayName(atPath: url.path), url: url, symbolName: "externaldrive.connected.to.line.below")
            })

        let keys: [URLResourceKey] = [
            .volumeLocalizedNameKey,
            .volumeIsBrowsableKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
            .volumeIsInternalKey
        ]
        let volumes = manager.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        entries.append(contentsOf: volumes.compactMap { volume in
            guard volume.path != "/" else { return nil }
            let values = try? volume.resourceValues(forKeys: Set(keys))
            guard values?.volumeIsBrowsable != false else { return nil }
            let removable = values?.volumeIsRemovable == true || values?.volumeIsEjectable == true
            let symbol = removable ? "externaldrive" : "internaldrive"
            return FinderSidebarEntry(
                title: values?.volumeLocalizedName ?? manager.displayName(atPath: volume.path),
                url: volume,
                symbolName: symbol
            )
        })

        let network = URL(fileURLWithPath: "/Network", isDirectory: true)
        if manager.fileExists(atPath: network.path) {
            entries.append(FinderSidebarEntry(title: L10n.text("Network"), url: network, symbolName: "network"))
        }
        return deduplicatedEntries(entries)
    }

    private func sharedFileListURLs(identifier: CFString) -> [URL] {
        guard let unmanagedList = LSSharedFileListCreate(nil, identifier, nil) else { return [] }
        let list = unmanagedList.takeRetainedValue()
        var seed: UInt32 = 0
        guard let snapshot = LSSharedFileListCopySnapshot(list, &seed)?.takeRetainedValue() as? [LSSharedFileListItem] else {
            return []
        }
        return snapshot.compactMap { item in
            var error: Unmanaged<CFError>?
            return LSSharedFileListItemCopyResolvedURL(item, 0, &error)?.takeRetainedValue() as URL?
        }
    }

    private func cloudStorageProviders() -> [URL] {
        let cloudStorage = manager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let providers = try? manager.contentsOfDirectory(
            at: cloudStorage,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
            options: [.skipsHiddenFiles]
        )
        return providers?.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        } ?? []
    }

    private func deduplicated(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func deduplicatedEntries(_ entries: [FinderSidebarEntry]) -> [FinderSidebarEntry] {
        var seen = Set<String>()
        return entries.filter { seen.insert($0.url.standardizedFileURL.path).inserted }
    }
}
